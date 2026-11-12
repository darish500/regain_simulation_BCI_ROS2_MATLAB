classdef ReGainEEG < handle
    % ReGainEEG  Stage 4 EEG pipeline for ReGain (PhysioNet EEGMMIDB).
    % A handle class: methods modify the same object, so state (settings,
    % loaded data) stays in one place instead of being passed between files.

    properties
        % --- folders ---
        rootDir  string
        rawDir   string
        outDir   string
        figDir   string
        % --- dataset ---
        baseUrl      = "https://physionet.org/files/eegmmidb/1.0.0"
        autoDownload = true
        subjects     = 1:5
        runsLR       = [4 8 12]    % T1 = left fist,  T2 = right fist
        runsFF       = [6 10 14]   % T1 = both fists, T2 = both feet
        % --- preprocessing ---
        bandpass    = [8 30]   % Hz, covers mu (8-12) and beta (13-30)
        filterOrder = 3        % butter order; band-pass doubles it, filtfilt doubles the effect again
        useCAR      = true     % common average reference

                % --- epoching ---
        epochWindow = [0.5 4.0]   % s after cue onset (skips the reaction delay)
        rejectAbsUV = 100         % reject a trial if any |sample| exceeds this (uV)
        flatStdUV   = 0.1         % reject a trial if any channel is flat (std below this)
        classNames   = ["left_fist","right_fist","both_fists","both_feet","rest"]
        commandNames = ["LEFT","RIGHT","FORWARD","BACKWARD","STOP"]
        includeRest  = true       % add rest (T0) epochs as an extra class
        restClass    = 5          % label number used for rest
        restPerRun   = 4          % rest epochs kept per run (evenly spaced), to balance classes
                % channels used for features and for the amplitude check (10-10 names)
        motorChannels = ["FC3","FC1","FCZ","FC2","FC4", ...
                         "C5","C3","C1","CZ","C2","C4","C6", ...
                         "CP3","CP1","CPZ","CP2","CP4"]
        outFileName = "regain_eeg_processed.mat"   % saved in data/processed/
        ldaGamma = 0.1; % LDA regularisation (0 = plain LDA , up to 1 = diagonal covariance)
    end

    methods
        function obj = ReGainEEG(rootDir)
            % Constructor: runs when you write ReGainEEG(...)
            arguments
                rootDir (1,1) string = string(pwd)
            end
            obj.rootDir = rootDir;
            obj.rawDir  = fullfile(rootDir, "data", "raw");
            obj.outDir  = fullfile(rootDir, "data", "processed");
            obj.figDir  = fullfile(rootDir, "figures");
            for d = [obj.rawDir, obj.outDir, obj.figDir]
                if ~isfolder(d), mkdir(d); end
            end
        end

        function path = getFile(obj, subj, runNo)
            % Return the local path of one EDF file, downloading it if missing.
            name = sprintf("S%03dR%02d.edf", subj, runNo);
            dirS = fullfile(obj.rawDir, sprintf("S%03d", subj));
            path = fullfile(dirS, name);
            if isfile(path), return; end
            if ~obj.autoDownload
                error("Missing %s and autoDownload is off.", path);
            end
            if ~isfolder(dirS), mkdir(dirS); end
            url = sprintf("%s/S%03d/%s", obj.baseUrl, subj, name);
            fprintf("Downloading %s\n", url);
            websave(path, url);
        end

        function rec = loadRun(obj, subj, runNo)
            % Read one EDF file into a plain struct.
            path = obj.getFile(subj, runNo);
            info = edfinfo(path);     % header: labels, sampling info, annotations
            tt   = edfread(path);     % timetable; each cell is one 1 s record

            labels = string(info.SignalLabels);
            nSig   = numel(labels);
            for k = 1:nSig
                col = tt{:, k};                       % cell array of records
                x   = vertcat(col{:});                % join records into one long column
                if k == 1, data = zeros(nSig, numel(x)); end
                data(k, :) = x(:).';
            end

            rec.subject = subj;
            rec.run     = runNo;
            rec.data    = data;                       % channels x samples (uV)
            rec.fs      = info.NumSamples(1) / seconds(info.DataRecordDuration);
            % Labels look like "C3.." or "Fcz." -> clean to "C3", "FCZ"
            rec.chNames = regexprep(upper(labels), "[^A-Z0-9]", "");
            ann         = info.Annotations;           % EDF+ events (timetable)
            rec.onset_s = seconds(ann.Onset);         % event times in seconds
            rec.codes   = strtrim(string(ann.Annotations));  % "T0","T1","T2"
        end
        function plotRaw(~, rec, chans, tRange)
            % Plot raw EEG for a few channels, with the cue periods shaded.
            arguments
                ~
                rec struct
                chans (1,:) string = ["C3","CZ","C4"]
                tRange (1,2) double = [0 30]
            end

            t     = (0:size(rec.data, 2) - 1) / rec.fs;   % time axis in seconds
            win   = t >= tRange(1) & t <= tRange(2);      % samples inside the window
            edges = [rec.onset_s(:); size(rec.data, 2) / rec.fs];  % event i spans edges(i) to edges(i+1)

            shade = struct('T0', [0.5 0.5 0.5], ...       % rest  = grey
                           'T1', [0.00 0.45 0.74], ...    % T1    = blue
                           'T2', [0.85 0.33 0.10]);       % T2    = red

            figure('Name', 'Raw EEG', 'Position', [100 100 1000 650]);
            tl = tiledlayout(numel(chans), 1, 'TileSpacing', 'compact');
            for k = 1:numel(chans)
                idx = find(rec.chNames == chans(k));
                assert(~isempty(idx), "Channel %s not found", chans(k));
                ax = nexttile; hold(ax, 'on');
                for e = 1:numel(rec.codes)
                                       xregion(ax, edges(e), edges(e+1), ...
                        'FaceColor', shade.(char(rec.codes(e))), 'FaceAlpha', 0.30);
                end
                plot(ax, t(win), rec.data(idx, win), 'Color', ax.XColor, 'LineWidth', 0.8);
                xlim(ax, tRange); grid(ax, 'on');
                ylabel(ax, chans(k) + " (\muV)");
            end
            xlabel(tl, 'Time (s)');
            title(tl, sprintf('Raw EEG, S%03d R%02d  (grey = rest, blue = T1, red = T2)', ...
                rec.subject, rec.run));
        end
                 function out = preprocess(obj, rec)
            % Common average reference, then zero-phase 8-30 Hz band-pass.
            % Returns a copy of rec with .data replaced, so metadata is kept.
            X = double(rec.data);                          % channels x samples
            if obj.useCAR
                X = X - mean(X, 1);                        % subtract the all-channel mean at each sample
            end
            Wn = obj.bandpass / (rec.fs / 2);              % cutoffs as fractions of Nyquist (80 Hz)
            [z, p, k] = butter(obj.filterOrder, Wn, "bandpass");
            [sos, g]  = zp2sos(z, p, k);                   % second-order sections: numerically stable
            X = filtfilt(sos, g, X.').';                   % filtfilt filters columns, so transpose in and out
            out = rec;
            out.data = X;
        end

        function plotCompare(~, rec, filt, chan, tRange)
            % Raw vs filtered for one channel, plus their power spectra.
            arguments
                ~
                rec struct
                filt struct
                chan (1,1) string = "C3"
                tRange (1,2) double = [0 30]
            end
            idx = find(rec.chNames == chan);
            assert(~isempty(idx), "Channel %s not found", chan);
            fs  = rec.fs;
            t   = (0:size(rec.data, 2) - 1) / fs;
            win = t >= tRange(1) & t <= tRange(2);

            figure("Name", "Raw vs filtered", "Position", [100 100 1000 700]);
            tl = tiledlayout(3, 1, "TileSpacing", "compact");

            ax1 = nexttile; plot(ax1, t(win), rec.data(idx, win), "Color", ax1.XColor);
            ylabel(ax1, "Raw (\muV)"); grid(ax1, "on"); xlim(ax1, tRange);

            ax2 = nexttile; plot(ax2, t(win), filt.data(idx, win), "Color", ax2.XColor);
            ylabel(ax2, "CAR + 8-30 Hz (\muV)"); xlabel(ax2, "Time (s)");
            grid(ax2, "on"); xlim(ax2, tRange);

            ax3 = nexttile;
            [pr, f] = pwelch(rec.data(idx, :).',  2*fs, fs, [], fs);   % Welch power spectrum
            [pf, ~] = pwelch(filt.data(idx, :).', 2*fs, fs, [], fs);
            semilogy(ax3, f, pr, f, pf, "LineWidth", 1.2);
            %xline(ax3, obj_band(1)); 
            xlim(ax3, [0 60]); grid(ax3, "on");
            legend(ax3, "raw", "filtered"); xlabel(ax3, "Frequency (Hz)");
            ylabel(ax3, "Power (\muV^2/Hz)");

            title(tl, sprintf("%s, S%03d R%02d", chan, rec.subject, rec.run));
        end

                        function ep = extractEpochs(obj, filt)
            % Cut the filtered run into epochs: one per T1/T2 cue, plus a few rest (T0) epochs.
            fs  = filt.fs;
            nS  = round(diff(obj.epochWindow) * fs);              % samples per epoch (560)
            nCh = size(filt.data, 1);

            % Task cues and their class numbers
            taskIdx = find(filt.codes == "T1" | filt.codes == "T2");
            base = 0;
            if ismember(filt.run, obj.runsFF), base = 2; end      % fists/feet runs give classes 3/4
            yTask = base + 1 + double(filt.codes(taskIdx) == "T2");

            % Rest segments: keep restPerRun of them, evenly spaced through the run
            restAll = find(filt.codes == "T0");
            restIdx = [];
            if obj.includeRest && ~isempty(restAll)
                k = min(obj.restPerRun, numel(restAll));
                restIdx = restAll(unique(round(linspace(1, numel(restAll), k))));
            end

            cue = [taskIdx(:); restIdx(:)];
            y   = [yTask(:); repmat(obj.restClass, numel(restIdx), 1)];
            [~, o] = sort(filt.onset_s(cue));                     % keep trials in time order
            cue = cue(o);  y = y(o);

            X  = nan(nCh, nS, numel(cue));
            ok = false(numel(cue), 1);
            for i = 1:numel(cue)
                s0 = round((filt.onset_s(cue(i)) + obj.epochWindow(1)) * fs) + 1;
                s1 = s0 + nS - 1;
                if s0 < 1 || s1 > size(filt.data, 2), continue; end
                X(:, :, i) = filt.data(:, s0:s1);
                ok(i) = true;
            end

            ep.X       = single(X(:, :, ok));
            ep.y       = y(ok);
            ep.cue_s   = filt.onset_s(cue(ok));
            ep.t       = obj.epochWindow(1) + (0:nS-1) / fs;
            ep.fs      = fs;
            ep.chNames = filt.chNames;
            ep.subject = filt.subject;
            ep.run     = filt.run;
        end
                function [keep, reason] = rejectTrials(obj, ep)
            % Flag unusable trials. keep(i) is true if trial i is fine.
            n    = size(ep.X, 3);
            mIdx = find(ismember(ep.chNames, obj.motorChannels));   % rows of the motor channels
            assert(~isempty(mIdx), "No motor channels found in ep.chNames");
            reason = strings(n, 1);
            for i = 1:n
                tr = ep.X(:, :, i);
                if any(~isfinite(tr), "all")
                    reason(i) = "nonfinite";
                elseif any(std(tr, 0, 2) < obj.flatStdUV)            % a dead channel, any of the 64
                    reason(i) = "flat_channel";
                elseif max(abs(tr(mIdx, :)), [], "all") > obj.rejectAbsUV   % artefact on a motor channel
                    reason(i) = "amplitude";
                end
            end
            keep = (reason == "");
        end

        function plotEpochs(obj, ep)
            % One example trial per class present: C3 and C4 after the cue.
            iC3 = find(ep.chNames == "C3");
            iC4 = find(ep.chNames == "C4");
            cls = unique(ep.y).';
            figure("Name", "Example epochs", "Position", [100 100 1000 600]);
            tl = tiledlayout(numel(cls), 1, "TileSpacing", "compact");
            for c = cls
                ax = nexttile; hold(ax, "on");
                i = find(ep.y == c, 1);                          % first trial of this class
                plot(ax, ep.t, squeeze(ep.X(iC3, :, i)), "LineWidth", 1);
                plot(ax, ep.t, squeeze(ep.X(iC4, :, i)), "LineWidth", 1);
                grid(ax, "on"); legend(ax, "C3", "C4", "Location", "northeast");
                ylabel(ax, sprintf("%s -> %s (\\muV)", obj.classNames(c), obj.commandNames(c)), ...
                    "Interpreter", "tex");
            end
            xlabel(tl, "Time after cue (s)");
            title(tl, sprintf("Example epochs, S%03d R%02d", ep.subject, ep.run));
        end

                function [F, featNames] = extractFeatures(obj, ep)
            % Log band power (mu, beta) on the motor channels, one row per trial.
            mIdx = find(ismember(ep.chNames, obj.motorChannels));
            chs  = ep.chNames(mIdx);
            nT   = size(ep.X, 3);
            F    = zeros(nT, 2 * numel(mIdx));
            for i = 1:nT
                x  = double(ep.X(mIdx, :, i)).';             % samples x channels, as bandpower expects
                mu = bandpower(x, ep.fs, [8 12]);            % 1 x nCh power in the mu band
                be = bandpower(x, ep.fs, [13 30]);           % 1 x nCh power in the beta band
                F(i, :) = log([mu, be] + eps);               % log makes the values closer to Gaussian
            end
            featNames = [strcat("mu_", chs(:).'), strcat("beta_", chs(:).')];
                end

                      function R = runPipeline(obj)
            % Run every subject and run through the full pipeline, save the result.
            Xc = {}; Fc = {};
            y = zeros(0,1); subj = zeros(0,1); runId = zeros(0,1); cueT = zeros(0,1);
            rs = zeros(0,1); rr = zeros(0,1); rc = zeros(0,1); rw = strings(0,1);
            chNames = strings(0); fs = []; featNames = strings(0); tEpoch = [];

            for s = obj.subjects
                for r = [obj.runsLR, obj.runsFF]
                    rec  = obj.loadRun(s, r);
                    if isempty(chNames)                      % first file defines the reference
                        chNames = rec.chNames; fs = rec.fs;
                    else                                     % every later file must match it
                        assert(isequal(chNames, rec.chNames) && rec.fs == fs, ...
                            "Channels or fs differ in S%03d R%02d", s, r);
                    end
                    filt = obj.preprocess(rec);
                    ep   = obj.extractEpochs(filt);
                    [keep, why] = obj.rejectTrials(ep);
                    ep.X = ep.X(:, :, keep);                 % drop bad trials before features
                    [F, featNames] = obj.extractFeatures(ep);

                    Xc{end+1} = ep.X;                        %#ok<AGROW>
                    Fc{end+1} = F;                           %#ok<AGROW>
                    y     = [y;     ep.y(keep)];             %#ok<AGROW>
                    subj  = [subj;  repmat(s, nnz(keep), 1)];%#ok<AGROW>
                    runId = [runId; repmat(r, nnz(keep), 1)];%#ok<AGROW>
                    cueT  = [cueT;  ep.cue_s(keep)];         %#ok<AGROW>
                    tEpoch = ep.t;

                    bad = ~keep;
                    rs = [rs; repmat(s, nnz(bad), 1)];       %#ok<AGROW>
                    rr = [rr; repmat(r, nnz(bad), 1)];       %#ok<AGROW>
                    rc = [rc; ep.y(bad)];                    %#ok<AGROW>
                    rw = [rw; why(bad)];                     %#ok<AGROW>
                    fprintf("S%03d R%02d: %2d kept, %d rejected\n", s, r, nnz(keep), nnz(bad));
                end
            end

            R.X_epochs     = cat(3, Xc{:});                  % nCh x nSamples x nTrials
            R.X_feat       = vertcat(Fc{:});                 % nTrials x nFeatures
            R.y            = y;                              % 1 left, 2 right, 3 both fists, 4 both feet
            R.class_names  = obj.classNames;
            R.command_names = obj.commandNames;
            R.subject_id   = subj;
            R.run_id       = runId;
            R.cue_time_s   = cueT;
            R.fs           = fs;
            R.ch_names     = chNames;
            R.feature_names = featNames;
            R.epoch_times_s = tEpoch;
                        n = numel(rw);
            assert(numel(rs) == n && numel(rr) == n && numel(rc) == n, ...
                "Rejection log lengths differ: %d %d %d %d", ...
                numel(rs), numel(rr), numel(rc), numel(rw));
            R.rejected     = table(rs(:), rr(:), rc(:), rw(:), ...
                'VariableNames', {'subject','run','class','reason'});
            R.settings     = struct("bandpass", obj.bandpass, "filterOrder", obj.filterOrder, ...
                "useCAR", obj.useCAR, "epochWindow", obj.epochWindow, ...
                "rejectAbsUV", obj.rejectAbsUV, "flatStdUV", obj.flatStdUV, ...
                "subjects", obj.subjects, "runsLR", obj.runsLR, "runsFF", obj.runsFF, ...
                "motorChannels", obj.motorChannels);

            outFile = fullfile(obj.outDir, obj.outFileName);
            save(outFile, "-struct", "R", "-v7");            % each field becomes a variable
            fprintf("\nKept %d trials, rejected %d\n", numel(y), height(R.rejected));
            fprintf("Saved: %s\n", outFile);
        end

        function plotBandPower(obj, R)
            % Mean log band power per class at C3, CZ, C4 (mu left, beta right).
            sel = ["C3","CZ","C4"];
            f  = figure("Name", "Band power by class", "Position", [100 100 1000 450]);
            tl = tiledlayout(1, 2, "TileSpacing", "compact");
            for pre = ["mu","beta"]
                cols = arrayfun(@(s) find(R.feature_names == pre + "_" + s), sel);
                M = zeros(numel(obj.classNames), numel(sel));
                for c = 1:numel(obj.classNames)
                    M(c, :) = mean(R.X_feat(R.y == c, cols), 1);
                end
                ax = nexttile; bar(ax, M); grid(ax, "on");
                set(ax, "XTickLabel", obj.classNames, "TickLabelInterpreter", "none");
                legend(ax, sel); title(ax, pre + " log power");
            end
            ylabel(tl, "Mean log band power");
            exportgraphics(f, fullfile(obj.figDir, "band_power_by_class.png"), "Resolution", 150);
        end

        function verify(obj)
            % Reload the saved file and check it is ready for Stage 5.
            S  = load(fullfile(obj.outDir, obj.outFileName));
            nT = size(S.X_epochs, 3);
            assert(size(S.X_feat, 1) == nT && numel(S.y) == nT, "Trial counts disagree");
            assert(size(S.X_feat, 2) == numel(S.feature_names), "Feature names mismatch");
            assert(size(S.X_epochs, 1) == numel(S.ch_names), "Channel names mismatch");
            assert(numel(S.subject_id) == nT && numel(S.run_id) == nT, "Metadata length mismatch");
            assert(all(isfinite(S.X_feat(:))) && all(isfinite(S.X_epochs(:))), "NaN/Inf found");
            assert(isequal(unique(S.y).', 1:numel(S.class_names)), "Class labels incomplete");
            fprintf("OK: %d trials, %d channels, %d samples, fs = %g Hz\n", ...
                nT, size(S.X_epochs,1), size(S.X_epochs,2), S.fs);
            fprintf("Features per trial: %d\n", size(S.X_feat, 2));
            disp(table(S.class_names(:), S.command_names(:), accumarray(S.y, 1), ...
                'VariableNames', {'class','command','trials'}));
            disp(groupsummary(table(S.subject_id), "Var1"));
        end

        function inspect(~, rec)
            % Print what we need to know about a run before processing it.
            fprintf("\n--- S%03d R%02d ---\n", rec.subject, rec.run);
            fprintf("Sampling rate : %g Hz\n", rec.fs);
            fprintf("Channels      : %d\n", numel(rec.chNames));
            fprintf("First 10      : %s\n", strjoin(rec.chNames(1:10), " "));
            fprintf("Duration      : %.1f s\n", size(rec.data, 2) / rec.fs);
            fprintf("Event codes   : %s\n", strjoin(unique(rec.codes).', " "));
            fprintf("Counts        : T0=%d T1=%d T2=%d\n", ...
                sum(rec.codes=="T0"), sum(rec.codes=="T1"), sum(rec.codes=="T2"));
            end
    end
end