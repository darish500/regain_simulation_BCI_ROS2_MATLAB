classdef ReGainTemporalFilter < handle
    % ReGainTemporalFilter  Turns a stream of per-window EEG class predictions into a
    % stable intent, by voting over the last windowLen valid predictions.
    % It knows nothing about destinations or robot commands: it only outputs the
    % EEG class name, or NO_DECISION.

    properties
        windowLen (1,1) double {mustBeInteger, mustBePositive} = 5
        minVotes  (1,1) double = NaN     % NaN = strict majority: floor(windowLen/2) + 1
        classes   (1,:) double = [1 2 4 5]
        names     (1,:) string = ["LEFT_FIST","RIGHT_FIST","BOTH_FEET","REST"]
    end

    properties (SetAccess = private)
        bufCls   (:,1) double = zeros(0,1)   % last valid predictions, oldest first
        bufConf  (:,1) double = zeros(0,1)   % their confidences (logged, never used to decide)
        nInvalid (1,1) double = 0            % predictions ignored since the last reset
    end

    methods
        function obj = ReGainTemporalFilter(windowLen, minVotes)
            arguments
                windowLen (1,1) double {mustBeInteger, mustBePositive} = 5
                minVotes  (1,1) double = NaN
            end
            obj.windowLen = windowLen;
            obj.minVotes  = minVotes;
            obj.requiredVotes();                 % rejects impossible combinations early
        end

        function v = requiredVotes(obj)
            % Votes the winning class needs inside the window.
            if isnan(obj.minVotes)
                v = floor(obj.windowLen / 2) + 1;      % 1 of 1, 2 of 3, 3 of 5
            else
                v = obj.minVotes;
            end
            assert(v >= 1 && v <= obj.windowLen && v == round(v), ...
                "minVotes must be an integer between 1 and windowLen");
        end

        function reset(obj)
            % Forget everything. Call this at the start of every new trial or sequence.
            obj.bufCls  = zeros(0,1);
            obj.bufConf = zeros(0,1);
            obj.nInvalid = 0;
        end

        function [intent, info] = update(obj, cls, conf)
            % Feed one prediction, get the current intent.
            arguments
                obj
                cls  (1,1) double
                conf (1,1) double = NaN
            end
            L = obj.windowLen;
            v = obj.requiredVotes();

            valid = ismember(cls, obj.classes);          % NaN or an unknown class is invalid
            if valid
                obj.bufCls  = [obj.bufCls;  cls];
                obj.bufConf = [obj.bufConf; conf];
                k = max(1, numel(obj.bufCls) - L + 1);   % keep only the last L
                obj.bufCls  = obj.bufCls(k:end);
                obj.bufConf = obj.bufConf(k:end);
            else
                obj.nInvalid = obj.nInvalid + 1;
            end

            nb     = numel(obj.bufCls);
            counts = arrayfun(@(c) sum(obj.bufCls == c), obj.classes);
            top    = max(counts);
            win    = find(counts == top);                % classes sharing the top count

            info = struct("cls", NaN, "votes", top, "windowLen", L, "required", v, ...
                "agreement", sprintf("%d/%d", top, nb), "confidence", NaN, ...
                "buffered", nb, "valid", valid);
            intent = "NO_DECISION";
            if valid && nb == L && top >= v && numel(win) == 1
                intent          = obj.names(win);
                info.cls        = obj.classes(win);
                info.confidence = mean(obj.bufConf(obj.bufCls == info.cls), "omitnan");
            end
        end

        function out = runSequence(obj, cls, conf)
            % Reset, then feed a whole sequence. Used for testing and for evaluation.
            arguments
                obj
                cls  double
                conf double = []
            end
            cls = cls(:);
            if isempty(conf), conf = nan(size(cls)); end
            conf = conf(:);
            assert(numel(conf) == numel(cls), "cls and conf must have the same length");
            obj.reset();
            n = numel(cls);
            out.intent = strings(n, 1);
            out.cls    = nan(n, 1);
            out.votes  = zeros(n, 1);
            out.conf   = nan(n, 1);
            for i = 1:n
                [out.intent(i), info] = obj.update(cls(i), conf(i));
                out.cls(i)  = info.cls;
                out.votes(i) = info.votes;
                out.conf(i) = info.confidence;
            end
        end
    end

    methods (Static)
        function selfTest()
            % Hand-made sequences with known answers.
            N = "NO_DECISION";

            % 1. Single prediction: every valid prediction passes straight through
            f = ReGainTemporalFilter(1);
            o = f.runSequence([1 2 4 5]);
            assert(isequal(o.intent, ["LEFT_FIST";"RIGHT_FIST";"BOTH_FEET";"REST"]), "single mode");

            % 2. 3-window majority (2 of 3): warm-up, a clear vote, a 3-way split
            f = ReGainTemporalFilter(3);
            o = f.runSequence([2 2 5 1 2 4 4 5]);
            assert(isequal(o.intent, [N;N;"RIGHT_FIST";N;N;N;"BOTH_FEET";"BOTH_FEET"]), "3-window");

            % 3. 5-window majority (3 of 5)
            f = ReGainTemporalFilter(5);
            o = f.runSequence([2 2 5 2 1 1 1 1]);
            assert(isequal(o.intent, [N;N;N;N;"RIGHT_FIST";N;"LEFT_FIST";"LEFT_FIST"]), "5-window");
            assert(o.votes(end) == 4, "vote count");

            % 4. Confidence of the winning votes is reported
            o = f.runSequence([2 2 5 2 1 1 1 1], [.1 .2 .3 .4 .5 .6 .7 .8]);
            assert(abs(o.conf(end) - 0.65) < 1e-9, "winner confidence");

            % 5. Invalid input (NaN, or a class the filter does not know) is ignored
            f = ReGainTemporalFilter(3);
            [i1, ~] = f.update(2);   [i2, ~] = f.update(2);
            [i3, ~] = f.update(NaN); [i4, ~] = f.update(3);
            [i5, ~] = f.update(2);
            assert(all([i1 i2 i3 i4] == N) && i5 == "RIGHT_FIST", "invalid input");
            assert(f.nInvalid == 2, "invalid count");

            % 6. reset() clears the buffer
            f = ReGainTemporalFilter(3);
            f.runSequence([2 2 2]);
            f.reset();
            assert(f.update(2) == N, "reset");

            % 7. Loose rule (2 of 4): a 2-2 tie gives NO_DECISION
            f = ReGainTemporalFilter(4, 2);
            o = f.runSequence([1 1 2 2]);
            assert(o.intent(end) == N, "tie");
            o = f.runSequence([1 1 1 2]);
            assert(o.intent(end) == "LEFT_FIST", "loose majority");

            % 8. Impossible configuration is rejected
            threw = false;
            try, ReGainTemporalFilter(3, 5); catch, threw = true; end
            assert(threw, "minVotes > windowLen should be rejected");

            fprintf("ReGainTemporalFilter self-test: all checks passed\n");
        end
                function D = applyToStream(T, L, minVotes)
            % Run the temporal filter over a saved stream, one trial at a time.
            arguments
                T table
                L (1,1) double
                minVotes (1,1) double = NaN
            end
            f = ReGainTemporalFilter(L, minVotes);
            g = findgroups(T.subject, T.run, T.trial);
            first = [true; diff(g) ~= 0];
            assert(nnz(first) == max(g), "Windows of a trial are not contiguous; sort the stream first");
            starts = find(first);
            stops  = [starts(2:end) - 1; height(T)];

            n = height(T);
            intent = strings(n, 1);  dcls = nan(n, 1);  votes = zeros(n, 1);
            dconf  = nan(n, 1);      widx = zeros(n, 1);
            for k = 1:numel(starts)
                r = starts(k):stops(k);
                o = f.runSequence(T.pred(r), T.conf(r));       % buffer is reset for each trial
                intent(r) = o.intent;   dcls(r) = o.cls;
                votes(r)  = o.votes;    dconf(r) = o.conf;
                widx(r)   = 1:numel(r);                        % window number inside the trial
            end

            D = T(:, {'subject','run','trial','win_start_s','y_true','pred','conf'});
            D.win_idx     = widx;
            D.intent      = intent;
            D.dcls        = dcls;                              % decided class, NaN if NO_DECISION
            D.votes       = votes;
            D.dconf       = dconf;
            D.opportunity = widx >= L;                         % buffer full: a decision is possible
            D.accepted    = D.opportunity & ~isnan(dcls);
        end

        function S = summarize(D, fromWin)
            % Metrics over the opportunities at window positions >= fromWin.
            arguments
                D table
                fromWin (1,1) double = 1
            end
            classes = [1 2 4 5];
            m   = D.opportunity & D.win_idx >= fromWin;        % opportunities scored
            acc = m & D.accepted;
            ok  = D.dcls == D.y_true;

            S.opportunities = nnz(m);
            S.accepted      = nnz(acc);
            S.rejected      = S.opportunities - S.accepted;
            S.coverage      = S.accepted / S.opportunities;
            S.correct       = nnz(acc & ok);
            S.acceptedAcc   = S.correct / S.accepted;
            S.correctPerOpp = S.correct / S.opportunities;
            S.wrongRate     = nnz(acc & ~ok) / S.opportunities;

            K = numel(classes);
            S.classes = classes;
            S.recall = nan(K,1);  S.precision = nan(K,1);  S.classCoverage = nan(K,1);
            for i = 1:K
                c   = classes(i);
                hit = nnz(acc & D.y_true == c & D.dcls == c);
                S.recall(i)        = hit / nnz(m & D.y_true == c);
                S.precision(i)     = hit / nnz(acc & D.dcls == c);
                S.classCoverage(i) = nnz(acc & D.y_true == c) / nnz(m & D.y_true == c);
            end
            S.f1 = 2 * S.precision .* S.recall ./ (S.precision + S.recall);
        end

        function R = compareModes(T, fromWin)
            % Single prediction vs 3-window vs 5-window voting. Prints and returns results.
            arguments
                T table
                fromWin (1,1) double = 1
            end
            Ls = [1 3 5];
            names = ["LEFT_FIST","RIGHT_FIST","BOTH_FEET","REST"];
            R = cell(1, numel(Ls));
            if fromWin == 1
                fprintf("\n=== each mode scored at its own positions ===\n");
            else
                fprintf("\n=== all modes scored on windows %d to 9 only (matched) ===\n", fromWin);
            end
            fprintf("%-10s %6s %9s %8s %9s %12s %10s\n", "mode", "opps", "accepted", ...
                "coverage", "acc(acc.)", "correct/opp", "wrong/opp");
            for i = 1:numel(Ls)
                D = ReGainTemporalFilter.applyToStream(T, Ls(i));
                S = ReGainTemporalFilter.summarize(D, fromWin);
                S.L = Ls(i);  S.fromWin = fromWin;  R{i} = S;
                label = sprintf("%d-window", Ls(i));  if Ls(i) == 1, label = "single"; end
                fprintf("%-10s %6d %9d %8.3f %9.3f %12.3f %10.3f\n", label, S.opportunities, ...
                    S.accepted, S.coverage, S.acceptedAcc, S.correctPerOpp, S.wrongRate);
            end
            fprintf("\n%-10s %-11s %7s %9s %6s %9s\n", "mode", "class", "recall", "precision", "F1", "coverage");
            for i = 1:numel(Ls)
                S = R{i};
                label = sprintf("%d-window", S.L);  if S.L == 1, label = "single"; end
                for k = 1:numel(S.classes)
                    fprintf("%-10s %-11s %7.3f %9.3f %6.3f %9.3f\n", label, names(k), ...
                        S.recall(k), S.precision(k), S.f1(k), S.classCoverage(k));
                end
            end
        end
               function C = confusion(D, fromWin)
            % 4 x 5 counts: rows = true class, columns = decided class + NO_DECISION.
            arguments
                D table
                fromWin (1,1) double = 1
            end
            classes = [1 2 4 5];
            m = D.opportunity & D.win_idx >= fromWin;           % opportunities scored
            C = zeros(4, 5);
            for i = 1:4
                ri = m & D.y_true == classes(i);
                for j = 1:4
                    C(i, j) = nnz(ri & D.dcls == classes(j));
                end
                C(i, 5) = nnz(ri & isnan(D.dcls));              % rejected
            end
            assert(sum(C(:)) == nnz(m), "Confusion counts do not add up to the opportunities");
        end

        function showConfusion(D, fromWin, label)
            % Print counts and row percentages for one mode.
            arguments
                D table
                fromWin (1,1) double
                label (1,1) string
            end
            names = ["LEFT_FIST","RIGHT_FIST","BOTH_FEET","REST"];
            C = ReGainTemporalFilter.confusion(D, fromWin);
            fprintf("\n--- %s: counts (rows = true class), windows %d to 9 ---\n", label, fromWin);
            fprintf("%-11s", ""); fprintf("%11s", [names "NO_DECISION"]); fprintf("%9s\n", "total");
            for i = 1:4
                fprintf("%-11s", names(i)); fprintf("%11d", C(i, :)); fprintf("%9d\n", sum(C(i, :)));
            end
            R = 100 * C ./ sum(C, 2);
            fprintf("row %%:\n");
            for i = 1:4
                fprintf("%-11s", names(i)); fprintf("%11.1f", R(i, :)); fprintf("\n");
            end
        end

        function P = perSubject(T, fromWin)
            % Per-subject results for single / 3-window / 5-window, plus a paired comparison.
            arguments
                T table
                fromWin (1,1) double = 5
            end
            Ls   = [1 3 5];
            subs = unique(T.subject).';
            P = table(subs.', 'VariableNames', {'subject'});
            for i = 1:numel(Ls)
                D = ReGainTemporalFilter.applyToStream(T, Ls(i));
                cpo = zeros(numel(subs), 1);  aa = cpo;  cv = cpo;
                for k = 1:numel(subs)
                    S = ReGainTemporalFilter.summarize(D(D.subject == subs(k), :), fromWin);
                    cpo(k) = S.correctPerOpp;  aa(k) = S.acceptedAcc;  cv(k) = S.coverage;
                end
                P.(sprintf('cpo_%d', Ls(i))) = cpo;     % correct per opportunity
                P.(sprintf('acc_%d', Ls(i))) = aa;      % accuracy of accepted decisions
                P.(sprintf('cov_%d', Ls(i))) = cv;      % coverage
            end

            fprintf("\nPer-subject correct per opportunity (windows %d to 9), %d subjects:\n", ...
                fromWin, numel(subs));
            for i = 1:numel(Ls)
                v = P.(sprintf('cpo_%d', Ls(i)));
                label = sprintf("%d-window", Ls(i));  if Ls(i) == 1, label = "single"; end
                fprintf("  %-9s mean %.3f +/- %.3f (min %.3f, max %.3f)\n", label, ...
                    mean(v), std(v), min(v), max(v));
            end
            for L = [3 5]
                d  = P.(sprintf('cpo_%d', L)) - P.cpo_1;
                nb = nnz(d > 0);  nw = nnz(d < 0);  n = nb + nw;
                pv = NaN;
                if n > 0
                    pv = min(1, 2 * min(binocdf(nb, n, 0.5), 1 - binocdf(nb - 1, n, 0.5)));
                end
                fprintf("  %d-window vs single: better in %d, worse in %d, tied in %d subjects; ", ...
                    L, nb, nw, numel(d) - n);
                fprintf("mean difference %+.3f +/- %.3f; sign-test p = %.2f\n", mean(d), std(d), pv);
            end
        end 
                function F = falseRates(D, fromWin)
            % False-accept rates per emitted class, from the decisions in D.
            %   far    : emitted class c while the true class was not c,
            %            divided by opportunities whose true class is not c
            %   perOpp : the same count divided by ALL opportunities
            %   restMotion : opportunities at true REST that emitted a non-REST decision
            arguments
                D table
                fromWin (1,1) double = 5
            end
            classes = [1 2 4 5];
            m = D.opportunity & D.win_idx >= fromWin;
            F.classes = classes;
            F.far = nan(4, 1);  F.perOpp = nan(4, 1);
            for i = 1:4
                c     = classes(i);
                wrong = m & D.accepted & D.dcls == c & D.y_true ~= c;
                F.far(i)    = nnz(wrong) / nnz(m & D.y_true ~= c);
                F.perOpp(i) = nnz(wrong) / nnz(m);
            end
            r = m & D.y_true == 5;
            F.restMotion = nnz(r & D.accepted & D.dcls ~= 5) / nnz(r);
        end

        function showFalseRates(Fc, labels)
            % Print false-accept rates for several modes side by side.
            fprintf("\nFalse-accept rates (windows 5 to 9). Lower is safer.\n");
            fprintf("%-10s %12s %12s %12s %12s %14s\n", "mode", "false LEFT", ...
                "false RIGHT", "false FEET", "false FEET", "REST->motion");
            fprintf("%-10s %12s %12s %12s %12s %14s\n", "", "(of others)", ...
                "(of others)", "(of others)", "(of all opps)", "(of REST opps)");
            for i = 1:numel(Fc)
                F = Fc{i};
                fprintf("%-10s %12.3f %12.3f %12.3f %12.3f %14.3f\n", labels(i), ...
                    F.far(1), F.far(2), F.far(3), F.perOpp(3), F.restMotion);
            end
        end

        function A = analyse(T, label)
            % Full Stage 6A analysis of one prediction stream.
            arguments
                T table
                label (1,1) string
            end
            Ls = [1 3 5];
            names = ["single","3-window","5-window"];
            fprintf("\n################ %s ################\n", label);

            A.ownPositions = ReGainTemporalFilter.compareModes(T, 1);
            A.matched      = ReGainTemporalFilter.compareModes(T, 5);

            A.confusion = cell(1, 3);  A.falseRates = cell(1, 3);
            for i = 1:3
                D = ReGainTemporalFilter.applyToStream(T, Ls(i));
                ReGainTemporalFilter.showConfusion(D, 5, names(i));
                A.confusion{i}   = ReGainTemporalFilter.confusion(D, 5);
                A.falseRates{i}  = ReGainTemporalFilter.falseRates(D, 5);
            end
            ReGainTemporalFilter.showFalseRates(A.falseRates, names);
            A.perSubject = ReGainTemporalFilter.perSubject(T, 5);

            % EXPLORATORY: unanimous 5-of-5. Rule fixed before any result was seen.
            Du = ReGainTemporalFilter.applyToStream(T, 5, 5);
            S  = ReGainTemporalFilter.summarize(Du, 5);
            F  = ReGainTemporalFilter.falseRates(Du, 5);
            A.unanimous = struct("summary", S, "falseRates", F, ...
                "confusion", ReGainTemporalFilter.confusion(Du, 5));
            fprintf("\n--- EXPLORATORY: unanimous 5-of-5 (not a tuned or unbiased estimate) ---\n");
            fprintf("coverage %.3f | accuracy of accepted %.3f | correct per opportunity %.3f\n", ...
                S.coverage, S.acceptedAcc, S.correctPerOpp);
            fprintf("false FEET (of others) %.3f | REST->motion %.3f\n", F.far(3), F.restMotion);
            ReGainTemporalFilter.showConfusion(Du, 5, "unanimous 5-of-5");
        end
    end
end