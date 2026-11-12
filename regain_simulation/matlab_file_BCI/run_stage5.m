% Stage 5 entry point: evaluate (subject-aware), train final model, verify.
bci = ReGainClassifier();
bci.ldaGamma    = 0.1;
bci.useCSP      = true;
bci.clf         = "lda";
bci.useWindows  = false;
bci.classSubset = bci.menuClasses;        % left_fist, right_fist, both_feet, rest
rng(1);

evalCross  = bci.report(bci.evaluate(bci.makeFolds("subject")), ...
    "PRIMARY: leave-one-subject-out (unseen subject)");
evalWithin = bci.report(bci.evaluate(bci.makeFolds("withinSubject")), ...
    "SECONDARY: within-subject, leave-one-run-out (needs per-user calibration)");

bci.trainFinal();
bci.verifyModel();
save(fullfile(bci.modelDir, "regain_eval.mat"), "evalCross", "evalWithin");