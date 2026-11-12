classdef ReGainClassifier < handle
    % ReGainClassifier  Stage 5: EEG features -> predicted class + confidence.
    % Handle class: the loaded data, splits and (later) the trained model
    % all live in one object.

    properties
        rootDir   string
        dataFile  string
        modelDir  string
        % --- data from Stage 4 ---
        X          double     % nTrials x nFeatures (log band power)
        y          (:,1) double   % class number per trial
        subj       (:,1) double   % subject id per trial
        runId      (:,1) double   % run id per trial
        classNames string
        featNames  string
        fs         double
        ldaGamma = 0.1 %LDA regularisation 
        subjectNorm = false %z-score features within each subject (uses no labels)
        Xep        single     % nCh x nSamples x nTrials, filtered epochs from Stage 4
        cspPairs   = 3        % filters kept from EACH end per class (3 -> 6 per class)
        cspReg     = 0.01     % covariance regularisation (relative to mean channel power)
        useCSP = false   % true: CSP log-variance features; false: log band power
        classSubset = []   % [] = all classes; e.g. [2 4 5] trains and scores only those classes
        useWindows = false   % true: train/predict on sliding windows of each trial
        winLen     = 1.5     % window length (s)
        winHop     = 0.25    % hop between windows (s)
        winTrial   (:,1) double   % trial index of every window
        winStart   (:,1) double   % first sample of every window inside its trial
        clf       = "lda"   % "lda" or "svm"
        svmKernel = "rbf"   % "rbf" or "linear"
        svmC      = 1       % SVM box constraint (higher = fits training data harder)
        menuClasses   = [1 2 4 5]            % left_fist, right_fist, both_feet, rest (both_fists excluded)
        modelFileName = "regain_classifier.mat"
        resultsDir string
        cueT       (:,1) double   % cue time (s) of every trial, from Stage 4
        epochT0    double         % epoch start relative to the cue (s)
    end

    methods
      function obj = ReGainClassifier(rootDir)
            arguments
                rootDir (1,1) string = string(pwd)
            end
            obj.rootDir    = rootDir;
            obj.dataFile   = fullfile(rootDir, "data", "processed", "regain_eeg_processed.mat");
            obj.modelDir   = fullfile(rootDir, "models");
            obj.resultsDir = fullfile(rootDir, "results");
            for d = [obj.modelDir, obj.resultsDir]
                if ~isfolder(d), mkdir(d); end
            end
            obj.loadData();
        end

     function loadData(obj)
            % Load features, labels, metadata and the epochs (needed for CSP).
            assert(isfile(obj.dataFile), "Missing %s. Run run_stage4 first.", obj.dataFile);
            S = load(obj.dataFile, "X_feat", "X_epochs", "y", "subject_id", "run_id", ...
                     "cue_time_s", "epoch_times_s", "class_names", "feature_names", "fs");
            obj.X          = double(S.X_feat);
            obj.Xep        = S.X_epochs;
            obj.y          = S.y(:);
            obj.subj       = S.subject_id(:);
            obj.runId      = S.run_id(:);
            obj.cueT       = S.cue_time_s(:);
            obj.epochT0    = S.epoch_times_s(1);
            obj.classNames = string(S.class_names(:)).';
            obj.featNames  = string(S.feature_names(:)).';
            obj.fs         = S.fs;
            assert(size(obj.X,1) == numel(obj.y) && numel(obj.subj) == numel(obj.y), ...
                "Row counts disagree in the saved file");
            assert(size(obj.Xep,3) == numel(obj.y), "X_epochs and y have different trial counts");
            assert(numel(obj.cueT) == numel(obj.y), "cue_time_s and y have different lengths");
                end


        function summary(obj)
            % Trials per subject and class.
            subs = unique(obj.subj).';
            nC   = numel(obj.classNames);
            fprintf("\n%d trials, %d features, %d classes, fs = %g Hz\n", ...
                size(obj.X,1), size(obj.X,2), nC, obj.fs);
            fprintf("%-9s", "subject");
            fprintf("%12s", obj.classNames); fprintf("%8s\n", "total");
            for s = subs
                m = obj.subj == s;
                n = accumarray(obj.y(m), 1, [nC 1]).';
                fprintf("%-9d", s); fprintf("%12d", n); fprintf("%8d\n", sum(n));
            end
        end

        function folds = makeFolds(obj, scheme)
            % Build train/test masks. Each fold is a struct with logical vectors.
            %   "subject"       : leave one subject out        (primary)
            %   "withinSubject" : per subject, leave one run out (secondary)
            arguments
                obj
                scheme (1,1) string {mustBeMember(scheme, ["subject","withinSubject"])}
            end
            folds = struct("name", {}, "subject", {}, "train", {}, "test", {});
            subs = unique(obj.subj).';
            switch scheme
                case "subject"
                    for s = subs
                        test = obj.subj == s;
                        folds(end+1) = struct("name", sprintf("S%03d", s), ...
                            "subject", s, "train", ~test, "test", test); %#ok<AGROW>
                    end
                case "withinSubject"
                    for s = subs
                        for r = unique(obj.runId(obj.subj == s)).'
                            test  = obj.subj == s & obj.runId == r;
                            train = obj.subj == s & obj.runId ~= r;
                            folds(end+1) = struct("name", sprintf("S%03d_R%02d", s, r), ...
                                "subject", s, "train", train, "test", test); %#ok<AGROW>
                        end
                    end
            end
        end

        function [mu, sd] = fitScaler(~, Xtr)
            % Per-feature mean and std from TRAINING rows only.
            mu = mean(Xtr, 1);
            sd = std(Xtr, 0, 1);
            sd(sd < eps) = 1;                        % guard against a constant feature
        end
        
                function Xn = getX(obj)
            % Feature matrix, optionally normalised per subject.
            Xn = obj.X;
            if ~obj.subjectNorm, return; end
            for s = unique(obj.subj).'
                m  = obj.subj == s;
                sd = std(obj.X(m, :), 0, 1);  sd(sd < eps) = 1;
                Xn(m, :) = (obj.X(m, :) - mean(obj.X(m, :), 1)) ./ sd;
            end
                end

                        function cls = activeClasses(obj)
            % Class numbers currently in play.
            if isempty(obj.classSubset)
                cls = 1:numel(obj.classNames);
            else
                cls = obj.classSubset(:).';
            end
                        end

        function buildWindows(obj)
            % Index table only: which trial and start sample each window uses.
            L = round(obj.winLen * obj.fs);
            H = round(obj.winHop * obj.fs);
            starts = 1:H:(size(obj.Xep, 2) - L + 1);        % 1, 41, ... 321 -> 9 windows
            nT = size(obj.Xep, 3);
            obj.winStart = repmat(starts(:), nT, 1);
            obj.winTrial = repelem((1:nT).', numel(starts));
        end

        function yv = labels(obj)
            % Label of every unit being classified (trial or window).
            if obj.useWindows, yv = obj.y(obj.winTrial); else, yv = obj.y; end
        end

        function x = segment(obj, i)
            % Data of unit i (nCh x samples), as double.
            if obj.useWindows
                L = round(obj.winLen * obj.fs);
                s = obj.winStart(i);
                x = double(obj.Xep(:, s:s+L-1, obj.winTrial(i)));
            else
                x = double(obj.Xep(:, :, i));
            end
        end

        function m = expandMask(obj, trialMask)
            % Turn a per-trial fold mask into a per-unit mask.
            if obj.useWindows
                assert(~isempty(obj.winTrial), "Call buildWindows() first");
                m = trialMask(obj.winTrial);
            else
                m = trialMask;
            end
        end

                function [p, P, cn] = fitPredict(obj, Ztr, ytr, Zte)
            % Train the chosen classifier on (Ztr, ytr), return labels and posteriors for Zte.
            % cn = class numbers, in the column order of P.
            switch obj.clf
                case "lda"
                    mdl = fitcdiscr(Ztr, ytr, "DiscrimType", "linear", "Gamma", obj.ldaGamma);
                    [p, P] = predict(mdl, Zte);
                case "svm"
                    t = templateSVM("KernelFunction", obj.svmKernel, "BoxConstraint", obj.svmC, ...
                                    "KernelScale", "auto", "Standardize", false);
                    mdl = fitcecoc(Ztr, ytr, "Learners", t, "Coding", "onevsone", ...
                                   "FitPosterior", true);
                    [p, ~, ~, P] = predict(mdl, Zte);
                otherwise
                    error("obj.clf must be ""lda"" or ""svm""");
            end
            cn = mdl.ClassNames;
        end
                        function model = trainFinal(obj)
            % Fit CSP + scaler + LDA on ALL trials of the active classes and save them.
            assert(obj.useCSP && ~obj.useWindows && obj.clf == "lda", ...
                "Final model is CSP + LDA on whole trials");
            cls = obj.activeClasses();
            assert(numel(cls) >= 2, "Set classSubset first");
            tr  = ismember(obj.y, cls);

            csp = obj.fitCSP(tr);                                  % spatial filters
            F   = obj.cspFeatures(csp, find(tr));                  % log-variance features
            [mu, sd] = obj.fitScaler(F);                           % feature scaler
            lda = fitcdiscr((F - mu) ./ sd, obj.y(tr), "DiscrimType", "linear", ...
                            "Gamma", obj.ldaGamma);

            S = load(obj.dataFile, "ch_names");
            model.csp        = csp;
            model.mu         = mu;
            model.sd         = sd;
            model.lda        = compact(lda);                       % small, prediction-only copy
            model.nCh        = size(obj.Xep, 1);
            model.classes    = cls;
            model.classNames = obj.classNames;                     % indexed by class number
            model.chNames    = string(S.ch_names(:)).';
            model.fs         = obj.fs;
            model.nTrain     = nnz(tr);
            model.nSubjects  = numel(unique(obj.subj(tr)));
            model.settings   = struct("cspPairs", obj.cspPairs, "ldaGamma", obj.ldaGamma, ...
                                      "bandpass", "8-30 Hz + CAR (Stage 4)");
            model.created    = string(datetime("now"));

            file = fullfile(obj.modelDir, obj.modelFileName);
            save(file, "model", "-v7");
            fprintf("Saved model: %s\n", file);
            fprintf("Trained on %d trials, %d subjects, classes %s\n", ...
                model.nTrain, model.nSubjects, mat2str(cls));
        end

        function out = report(obj, res, label)
            % Print accuracy, confusion matrix, per-class metrics, per-subject stats, examples.
            cls = obj.activeClasses();
            m   = res.inSubset;
            C   = confusionmat(obj.y(m), res.pred(m), "Order", cls);
            rec  = diag(C) ./ sum(C, 2);                           % recall per class
            prec = diag(C) ./ sum(C, 1).';                         % precision per class
            f1   = 2 * prec .* rec ./ (prec + rec);
            nm   = obj.classNames(cls);

            fprintf("\n=== %s ===\n", label);
            fprintf("Overall accuracy %.3f   (chance %.2f, %d trials)\n", ...
                res.accuracy, 1/numel(cls), nnz(m));
            disp(array2table(C, 'VariableNames', cellstr("pred_" + nm), ...
                                'RowNames', cellstr("true_" + nm)));
            disp(table(nm(:), rec, prec, f1, ...
                'VariableNames', {'class','recall','precision','F1'}));

            sa = res.subjAcc;
            fprintf("Per-subject accuracy: mean %.3f +/- %.3f (min %.3f, max %.3f), %d subjects\n", ...
                mean(sa), std(sa), min(sa), max(sa), numel(sa));
            fprintf("  by subject: %s\n", sprintf("%.2f ", sa));
            ok = res.pred == obj.y;
            fprintf("Confidence: correct %.3f, wrong %.3f\n", ...
                mean(res.conf(m & ok)), mean(res.conf(m & ~ok)));

            idx  = find(m);
            pick = idx(round(linspace(1, numel(idx), 8)));
            fprintf("\n%-7s %-12s %-12s %-5s\n", "trial", "true", "predicted", "conf");
            for i = pick.'
                fprintf("%-7d %-12s %-12s %.2f\n", i, obj.classNames(obj.y(i)), ...
                    obj.classNames(res.pred(i)), res.conf(i));
            end

            out = struct("accuracy", res.accuracy, "confusion", C, "recall", rec, ...
                "precision", prec, "f1", f1, "subjAcc", sa, "classes", cls);
        end

          function T = exportStream(obj, res, scheme)
            % Cross-validated window predictions plus the metadata that fixes their order.
            arguments
                obj
                res struct
                scheme (1,1) string
            end
            assert(obj.useWindows, "Set useWindows = true (and call buildWindows) first");
            k  = res.inSubset;                          % windows of the active classes only
            tr = obj.winTrial(k);                       % trial index of each window
            ws = (obj.winStart(k) - 1) / obj.fs;        % window start inside the epoch (s)
            T = table(obj.subj(tr), obj.runId(tr), tr, obj.cueT(tr), ws, ...
                      obj.cueT(tr) + obj.epochT0 + ws, ...
                      res.yv(k), res.pred(k), res.conf(k), res.post(k, :), ...
                      'VariableNames', {'subject','run','trial','cue_s','win_start_s', ...
                                        't_start_s','y_true','pred','conf','post'});
            T = sortrows(T, {'subject','run','cue_s','win_start_s'});

            meta = struct("scheme", scheme, "ldaGamma", obj.ldaGamma, "winLen", obj.winLen, ...
                "winHop", obj.winHop, "classes", obj.activeClasses(), "fs", obj.fs, ...
                "created", string(datetime("now")));
            file = fullfile(obj.resultsDir, "stream_" + scheme + ".mat");
            save(file, "T", "meta", "-v7");
            fprintf("Saved %d windows from %d trials: %s\n", height(T), numel(unique(T.trial)), file);
                end


        function verifyModel(obj)
            % Check the SAVED model is ready for Stage 6.
            assert(~obj.useWindows, "Set useWindows = false");
            file = fullfile(obj.modelDir, obj.modelFileName);
            assert(isfile(file), "Missing %s. Run trainFinal first.", file);
            S = load(file, "model");  model = S.model;
            cls = model.classes;
            nF  = size(model.csp.W, 2) * size(model.csp.W, 3);

            assert(size(model.csp.W, 1) == 64, "Filters should span 64 channels");
            assert(numel(model.mu) == nF && numel(model.sd) == nF, "Scaler size mismatch");
            assert(isequal(model.lda.ClassNames(:).', cls(:).'), "LDA classes mismatch");
            assert(all(isfinite(model.csp.W(:))) && all(isfinite(model.mu)) ...
                && all(model.sd > 0), "Non-finite model parameters");
            fprintf("Model file OK: %d features, classes %s\n", nF, mat2str(cls));

            idx  = find(ismember(obj.y, cls));
            pick = idx(round(linspace(1, numel(idx), 25)));
            c1 = zeros(numel(pick), 1);  cf1 = c1;
            tic;
            for j = 1:numel(pick)
                [c, cf, info] = ReGainClassifier.predictOne(obj.Xep(:, :, pick(j)), model);
                assert(ismember(c, cls), "predictOne returned an unknown class");
                assert(cf >= 1/numel(cls) - 1e-9 && cf <= 1 + 1e-9, "Confidence out of range");
                assert(abs(sum(info.posterior) - 1) < 1e-6, "Posterior does not sum to 1");
                c1(j) = c;  cf1(j) = cf;
            end
            ms = 1000 * toc / numel(pick);
            fprintf("predictOne OK on %d epochs, %.1f ms per call\n", numel(pick), ms);

            % predictOne must agree with the batch path used during evaluation
            F = obj.cspFeatures(model.csp, pick);
            [pb, Pb] = predict(model.lda, (F - model.mu) ./ model.sd);
            assert(isequal(pb(:), c1), "predictOne disagrees with batch path (class)");
            assert(max(abs(max(Pb, [], 2) - cf1)) < 1e-9, "predictOne disagrees (confidence)");
            fprintf("predictOne matches the batch pipeline exactly\n");

            % bad input must be rejected, not silently mis-scored
            threw = false;
            try, ReGainClassifier.predictOne(zeros(10, 560), model); catch, threw = true; end
            assert(threw, "Wrong channel count was not rejected");
            fprintf("Bad input rejected\n");

            % in-sample score: only a sanity check, NOT a performance estimate
            F  = obj.cspFeatures(model.csp, idx);
            pa = predict(model.lda, (F - model.mu) ./ model.sd);
            fprintf("Training-set accuracy %.3f (inflated, the model saw these trials)\n", ...
                mean(pa == obj.y(idx)));
            fprintf("Use the leave-one-subject-out figures as the real performance.\n");
            fprintf("\nREADY for Stage 6: %s\n", file);
        end
                     function C = meanCov(obj, idx)
            % Average spatial covariance (nCh x nCh) over the trials in idx.
            nCh = size(obj.Xep, 1);
            C = zeros(nCh);
            for i = idx(:).'
                x = obj.segment(i);
                x = x - mean(x, 2);                  % remove each channel's offset
                c = x * x.';                         % channel-by-channel covariance
                C = C + c / trace(c);                % trace-normalise so loud trials don't dominate
            end
            C = C / numel(idx);
        end

                        function model = fitCSP(obj, trainMask)
            % One-vs-rest CSP filters over the active classes, from training trials ONLY.
            cls = obj.activeClasses();
            nC  = numel(cls);
            nCh = size(obj.Xep, 1);
            p   = obj.cspPairs;
            yv  = obj.labels();
            idx = find(trainMask & ismember(yv, cls));

            Ck = zeros(nCh, nCh, nC);  nk = zeros(nC, 1);
            for c = 1:nC
                ii = idx(yv(idx) == cls(c));
                nk(c) = numel(ii);
                Ck(:, :, c) = obj.meanCov(ii);
            end
            N    = sum(nk);
            Ctot = sum(Ck .* reshape(nk, 1, 1, []), 3) / N;

            W  = zeros(nCh, 2*p, nC);
            ev = zeros(2*p, nC);
            rk = zeros(1, nC);
            for c = 1:nC
                C1 = Ck(:, :, c);
                C2 = (Ctot * N - C1 * nk(c)) / (N - nk(c));
                Cs = (C1 + C2 + (C1 + C2).') / 2;

                [V0, D0] = eig(Cs);
                [d0, o]  = sort(real(diag(D0)), "descend");
                V0 = real(V0(:, o));
                r  = nnz(d0 > 1e-9 * d0(1));
                P  = V0(:, 1:r) ./ sqrt(d0(1:r)).';

                C1r = P.' * C1 * P;  C1r = (C1r + C1r.') / 2;
                [U, D] = eig(C1r);
                [d, o] = sort(real(diag(D)), "descend");
                U = real(U(:, o));
                sel = [1:p, r-p+1:r];
                W(:, :, c) = P * U(:, sel);
                ev(:, c)   = d(sel);
                rk(c)      = r;
            end
            model.W = W;  model.ev = ev;  model.rank = rk;  model.classes = cls;
        end

        function [F, names] = cspFeatures(obj, model, idx)
            % Log-variance of the CSP-filtered trials idx: one row per trial.
            [nCh, nF, nC] = size(model.W);
            Wall = reshape(model.W, nCh, nF * nC);        % all filters side by side
            F = zeros(numel(idx), nF * nC);
            for j = 1:numel(idx)
                x = obj.segment(idx(j));
                x = x - mean(x, 2);
                z = Wall.' * x;                           % filtered signals (filters x samples)
                F(j, :) = log(var(z, 0, 2)).';
            end
            names = strings(1, nF * nC);
            for c = 1:nC
                for k = 1:nF
                        names((c-1)*nF + k) = sprintf("csp_%s_%d", obj.classNames(model.classes(c)), k);
                end
            end
        end
                               function res = evaluate(obj, folds)
            % LDA per fold. Units are trials, or windows when useWindows = true.
            assert(~obj.useWindows || obj.useCSP, "Windows need useCSP = true");
            Xall = obj.getX();
            yv   = obj.labels();
            n    = numel(yv);
            nC   = numel(obj.classNames);
            inS  = ismember(yv, obj.activeClasses());
            pred = zeros(n, 1);  conf = zeros(n, 1);  post = zeros(n, nC);
            for k = 1:numel(folds)
                tr = obj.expandMask(folds(k).train) & inS;
                te = obj.expandMask(folds(k).test)  & inS;
                if obj.useCSP
                    m   = obj.fitCSP(tr);                    % filters from training units only
                    Ftr = obj.cspFeatures(m, find(tr));
                    Fte = obj.cspFeatures(m, find(te));
                else
                    Ftr = Xall(tr, :);
                    Fte = Xall(te, :);
                end
                [mu, sd] = obj.fitScaler(Ftr);
                Ztr = (Ftr - mu) ./ sd;
                Zte = (Fte - mu) ./ sd;
                [p, P, cn] = obj.fitPredict(Ztr, yv(tr), Zte);
                pred(te) = p;
                conf(te) = max(P, [], 2);
                post(te, cn) = P;
            end

            % Trial level: average the window posteriors of each trial
            if obj.useWindows
                nT = numel(obj.y);
                tp = zeros(nT, nC);
                for c = 1:nC
                    tp(:, c) = accumarray(obj.winTrial, post(:, c), [nT 1], @mean);
                end
                sv = obj.subj(obj.winTrial);
            else
                tp = post;  sv = obj.subj;
            end
            [tconf, tpred] = max(tp, [], 2);
            inT = ismember(obj.y, obj.activeClasses());

            res.yv = yv;  res.inSubset = inS;
            res.pred = pred;  res.conf = conf;  res.post = post;
            res.accuracy  = mean(pred(inS) == yv(inS));          % per unit (window or trial)
            res.subjAcc   = arrayfun(@(s) mean(pred(sv==s & inS) == yv(sv==s & inS)), ...
                                     unique(obj.subj).');
            res.trialPred = tpred;  res.trialConf = tconf;
            res.trialAcc  = mean(tpred(inT) == obj.y(inT));      % per trial
        end

        function showExamples(obj, res, n)
            % Print a few predictions with their confidence.
            arguments
                obj
                res struct
                n (1,1) double = 10
            end
            idx = round(linspace(1, numel(obj.y), n));
            fprintf("\n%-8s %-12s %-12s %-6s\n", "trial", "true", "predicted", "conf");
            for i = idx
                fprintf("%-8d %-12s %-12s %.2f\n", i, obj.classNames(obj.y(i)), ...
                    obj.classNames(res.pred(i)), res.conf(i));
            end
        end
    end
        methods (Static)
        function [cls, conf, info] = predictOne(epoch, model)
            % One processed epoch (64 x samples, CAR + 8-30 Hz filtered) -> class, confidence.
            % model: the struct saved by trainFinal, or a path to the .mat file.
            arguments
                epoch (:,:) {mustBeNumeric}
                model = fullfile(pwd, "models", "regain_classifier.mat")
            end
            if ~isstruct(model)
                S = load(model, "model");  model = S.model;
            end
            assert(size(epoch, 1) == model.nCh, ...
                "Expected %d channels, got %d", model.nCh, size(epoch, 1));
            assert(size(epoch, 2) >= 80, "Epoch too short (%d samples)", size(epoch, 2));

            x    = double(epoch);
            x    = x - mean(x, 2);                                 % same step as in training
            Wall = reshape(model.csp.W, model.nCh, []);            % all CSP filters side by side
            f    = log(var(Wall.' * x, 0, 2)).';                   % log-variance features
            z    = (f - model.mu) ./ model.sd;                     % training-set scaler
            [~, P] = predict(model.lda, z);                        % posterior per class

            [conf, k]      = max(P);                               % confidence = top posterior
            cls            = model.lda.ClassNames(k);              % class number, not a name
            info.className = model.classNames(cls);
            info.classes   = model.lda.ClassNames.';
            info.posterior = P;
        end
    end
end