classdef ReGainROS2Link < handle
    % ReGainROS2Link  MATLAB -> ROS 2 link for the ReGain EEG intent stream.
    % Publishes JSON inside a std_msgs/String on /regain/eeg_intent.
    % Message: {"seq":N,"t":unix_utc_seconds,"intent":"...","confidence":x,"agreement":"k/n"}

    properties (Constant)
        ValidIntents = ["NO_DECISION","LEFT_FIST","RIGHT_FIST","BOTH_FEET","REST"];
    end

    properties
        TopicName = "/regain/eeg_intent";
        NodeName  = "/regain_matlab_link";
        Node                                % ros2node object
        Pub                                 % ros2publisher object
        Seq = 0;                            % message counter, increases by 1 per message
    end

    methods
        function obj = ReGainROS2Link()
            % Must be set BEFORE the first ros2node is created in this MATLAB session.
            setenv('RMW_IMPLEMENTATION', 'rmw_cyclonedds_cpp');
            setenv('ROS_DOMAIN_ID', '0');
            obj.Node = ros2node(obj.NodeName);
            obj.Pub  = ros2publisher(obj.Node, obj.TopicName, "std_msgs/String", ...
                "Reliability", "reliable", "Durability", "volatile", ...
                "History", "keeplast", "Depth", 10);
        end

        function publishIntent(obj, intent, confidence, agreement)
            % Validate first: an unknown word must never reach ROS 2.
            intent = string(intent);
            if ~any(intent == obj.ValidIntents)
                error('ReGainROS2Link:badIntent', 'Unknown intent "%s".', intent);
            end
            if isempty(confidence), confidence = NaN; end
            obj.Seq = obj.Seq + 1;
            % UTC is explicit, because posixtime assumes UTC for unzoned datetimes.
            t = posixtime(datetime('now', 'TimeZone', 'UTC'));
            s = struct('seq', obj.Seq, 't', t, 'intent', char(intent), ...
                       'confidence', confidence, 'agreement', char(agreement));
            msg = ros2message(obj.Pub);
            msg.data = char(jsonencode(s));   % NaN confidence becomes null in JSON
            send(obj.Pub, msg);
        end

        function runFakeStream(obj, nMsgs, rateHz)
            % Fixed repeating pattern at a steady rate. No EEG, link test only.
            names = ["NO_DECISION","RIGHT_FIST","RIGHT_FIST","BOTH_FEET", ...
                     "REST","LEFT_FIST","REST","NO_DECISION"];
            confs = [NaN 0.41 0.44 0.39 0.47 0.36 0.45 NaN];
            agrs  = ["0/5","3/5","4/5","3/5","5/5","3/5","4/5","0/5"];
            period = 1 / rateHz;
            t0 = tic;
            for k = 1:nMsgs
                j = mod(k - 1, numel(names)) + 1;
                obj.publishIntent(names(j), confs(j), agrs(j));
                % Schedule against the start time so delays do not accumulate.
                pause(max(0, k * period - toc(t0)));
            end
        end

                        function log = replayStream(obj, T, filt, rateHz)
            % Replay cross-validated window predictions (table T, time order)
            % through a ReGainTemporalFilter and publish each filter output.
            % The filter is reset whenever a new trial starts.
            n = height(T);
            seqs = zeros(n,1); intents = strings(n,1); agrs = strings(n,1);
            period = 1 / rateHz;
            t0 = tic;
            for i = 1:n
                newTrial = (i == 1) || T.subject(i) ~= T.subject(i-1) || ...
                           T.run(i) ~= T.run(i-1) || T.trial(i) ~= T.trial(i-1);
                if newTrial, filt.reset(); end
                [intent, info] = filt.update(T.pred(i), T.conf(i));
                agr = string(info.agreement);
                if ismissing(agr) || strlength(agr) == 0, agr = "n/a"; end
                obj.publishIntent(intent, info.confidence, agr);
                seqs(i) = obj.Seq; intents(i) = string(intent); agrs(i) = agr;
                pause(max(0, i * period - toc(t0)));
            end
            log = table(seqs, T.y_true, T.pred, intents, agrs, ...
                'VariableNames', {'seq','y_true','pred','intent','agreement'});
        end

        function delete(obj)
            obj.Pub  = [];
            obj.Node = [];
        end
    end
end