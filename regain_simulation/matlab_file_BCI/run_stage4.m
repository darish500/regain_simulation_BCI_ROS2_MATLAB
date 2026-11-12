% Stage 4 entry point: public EEG -> clean labelled trials and features -> .mat
eeg = ReGainEEG();
eeg.subjects = 1:20;          % was 1:5
R   = eeg.runPipeline();
eeg.plotBandPower(R);
eeg.verify();