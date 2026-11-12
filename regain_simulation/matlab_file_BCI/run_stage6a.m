% Stage 6A entry point: temporal decision layer evaluation.
% Needs results/stream_subject.mat and results/stream_within.mat. If they are missing,
% they are regenerated from the Stage 5 window classifier (about 3 minutes).
rd = fullfile(pwd, "results");
fS = fullfile(rd, "stream_subject.mat");
fW = fullfile(rd, "stream_within.mat");
if ~isfile(fS) || ~isfile(fW)
    bci = ReGainClassifier();
    bci.ldaGamma = 0.1;  bci.useCSP = true;  bci.clf = "lda";
    bci.buildWindows();  bci.useWindows = true;
    bci.classSubset = bci.menuClasses;
    rng(1);
    bci.exportStream(bci.evaluate(bci.makeFolds("subject")), "subject");
    bci.exportStream(bci.evaluate(bci.makeFolds("withinSubject")), "within");
    clear bci
end

ReGainTemporalFilter.selfTest();

S = load(fS);  W = load(fW);
A_subject = ReGainTemporalFilter.analyse(S.T, "PRIMARY: leave-one-subject-out stream");
A_within  = ReGainTemporalFilter.analyse(W.T, "SECONDARY: within-subject stream");

rules = struct( ...
    "unit",        "1.5 s windows, 0.25 s hop, 9 per trial; buffer reset at every trial", ...
    "modes",       "single (1/1), 3-window majority (2/3), 5-window majority (3/5)", ...
    "noDecision",  "buffer not full, or no class reaches the required votes", ...
    "scoredOn",    "windows 5 to 9 of each trial, identical for all modes", ...
    "exploratory", "unanimous 5-of-5, fixed in advance, reported on all 20 subjects", ...
    "confidence",  "logged only, never used in a decision", ...
    "created",     string(datetime("now")));
outFile = fullfile(rd, "stage6a_results.mat");
save(outFile, "A_subject", "A_within", "rules", "-v7");
fprintf("\nSaved: %s\n", outFile);