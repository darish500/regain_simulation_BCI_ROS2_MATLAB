# ReGain: MATLAB EEG pipeline and intention classifier

MATLAB side of ReGain, a BCI-based assistive mobility prototype.
This folder covers **Stage 4** (EEG preprocessing), **Stage 5** (intention classifier) and **Stage 6A** (temporal decision layer).
ROS 2, Gazebo, the state machine and voice feedback belong to later stages and are not in this folder.

```
public EEG dataset -> MATLAB preprocessing -> labelled trials
                   -> CSP + LDA classifier -> predicted EEG class + confidence
                   -> temporal filter (vote over consecutive windows) -> intent or NO_DECISION
```

The classifier only outputs an **EEG class number and a confidence**, and the temporal filter only outputs an **EEG class name or `NO_DECISION`**. Neither knows about destinations or wheelchair commands. That mapping is applied later.

## Requirements

- MATLAB R2025b (developed and tested on this release). `edfread` needs R2020b or newer, `xregion` needs R2023b or newer.
- Signal Processing Toolbox (`butter`, `filtfilt`, `pwelch`, `bandpower`)
- Statistics and Machine Learning Toolbox (`fitcdiscr`, `fitcecoc`, `confusionmat`, `binocdf`)
- Internet access on the first run, to download the EDF files (about 300 MB for 20 subjects)

## Folder layout

```
regain_simulation/
  ReGainEEG.m            Stage 4: loading, preprocessing, epoching, features, saving
  ReGainClassifier.m     Stage 5: CSP, LDA/SVM, evaluation, final model, predictOne
  ReGainTemporalFilter.m Stage 6A: voting over consecutive predictions, evaluation methods
  run_stage4.m           runs the whole Stage 4 pipeline
  run_stage5.m           runs evaluation, trains and verifies the final model
  run_stage6a.m          evaluates the temporal decision layer
  data/
    raw/                 EDF files (downloaded automatically)
    processed/
      regain_eeg_processed.mat         Stage 4 output (20 subjects)
      regain_eeg_processed_5subj.mat   backup of the earlier 5-subject run
  figures/
    band_power_by_class.png
  models/
    regain_classifier.mat   final trained model
    regain_eval.mat         saved evaluation results
  results/
    stream_subject.mat      cross-validated window predictions, leave-one-subject-out
    stream_within.mat       same, within-subject (leave-one-run-out)
    stage6a_results.mat     Stage 6A tables, confusion matrices, per-subject results
```

This folder has the same name as the ROS 2 package `regain_simulation`, but it is a separate folder under `~/workspace/Matlab_workspace/`.

## Dataset

**PhysioNet EEG Motor Movement/Imagery Dataset** (EEGMMIDB, BCI2000), subjects 1 to 20.

- 64 channels, 160 Hz, EDF+ files with event annotations.
- Runs used: 4, 8, 12 (T1 = imagine left fist, T2 = imagine right fist) and 6, 10, 14 (T1 = both fists, T2 = both feet). T0 = rest.
- Files are fetched with `websave` from `https://physionet.org/files/eegmmidb/1.0.0` the first time they are needed. Files already on disk are skipped.
- If a download is interrupted, delete the partial `.edf` file and rerun.
- Subjects above 20 were not checked. Several higher-numbered subjects are commonly reported as irregular and would need to be excluded.

## How to run

In MATLAB, from the `regain_simulation/` folder:

```matlab
run_stage4        % download, preprocess, epoch, extract features, save, verify
run_stage5        % evaluate, train the final model, verify it
run_stage6a       % evaluate the temporal decision layer
```

Stage 4 takes several minutes the first time because of the downloads. Stage 5 takes a few minutes, mostly for the 20-fold cross-subject evaluation. `run_stage6a` takes under a minute if `results/stream_*.mat` exist. If they are missing it regenerates them (about 3 minutes).

After editing a method in a class file, run `clear bci` (or `clear eeg`) and create the object again. Do not use `clear classes`, which prints warnings about Simulink classes.

## Stage 4: preprocessing

Implemented in `ReGainEEG.m`.

| Step | Detail |
|---|---|
| Load | `edfread` / `edfinfo`, channel names cleaned (`C3..` becomes `C3`) |
| Reference | Common average reference |
| Filter | Zero-phase 8 to 30 Hz Butterworth (order 3, second-order sections, `filtfilt`), applied to the continuous run before epoching |
| Epochs | 0.5 to 4.0 s after each cue (560 samples). Rest (T0) epochs are subsampled to 4 per run, evenly spaced |
| Rejection | Any motor channel above 100 uV, any flat channel, or non-finite values. Amplitude is checked on the 17 sensorimotor channels only |
| Features | Log mu (8-12 Hz) and beta (13-30 Hz) band power on 17 sensorimotor channels (34 features) |

Result: 2203 kept trials, 77 rejected (3.4%), mostly in subjects 9, 13 and 17.

### Classes

| Number | Class | Source |
|---|---|---|
| 1 | left_fist | T1 in runs 4, 8, 12 |
| 2 | right_fist | T2 in runs 4, 8, 12 |
| 3 | both_fists | T1 in runs 6, 10, 14 |
| 4 | both_feet | T2 in runs 6, 10, 14 |
| 5 | rest | T0 (subsampled) |

`command_names` in the saved file (LEFT, RIGHT, FORWARD, BACKWARD, STOP) are placeholders and are not used by the classifier.

### Stage 4 output

`data/processed/regain_eeg_processed.mat`

| Variable | Shape | Meaning |
|---|---|---|
| `X_epochs` | 64 x 560 x 2203 (single) | filtered trials, all channels |
| `X_feat` | 2203 x 34 | log band power |
| `y` | 2203 x 1 | class number |
| `subject_id`, `run_id`, `cue_time_s` | 2203 x 1 | per-trial metadata |
| `class_names`, `command_names`, `ch_names`, `feature_names`, `epoch_times_s`, `fs` | | metadata |
| `rejected` | table | rejected trials and reasons |
| `settings` | struct | parameters used |

## Stage 5: classifier

Implemented in `ReGainClassifier.m`.

**Final model: CSP + LDA on four classes** (`menuClasses = [1 2 4 5]`: left_fist, right_fist, both_feet, rest). both_fists is excluded because it is reserved in the planned application mapping and it confused the other classes most.

| Component | Setting |
|---|---|
| Features | One-vs-rest CSP, 3 filters from each end per class (6 per class), log-variance. 24 features for 4 classes |
| CSP fitting | Inside each training fold only. Whitening removes the rank deficiency caused by the common average reference |
| Scaler | Mean and std from training rows only |
| Classifier | LDA, `Gamma = 0.1` |
| Confidence | Top LDA posterior probability |

### Evaluation (no random trial splits)

| Scheme | Folds | Meaning |
|---|---|---|
| **Primary:** leave-one-subject-out | 20 | Train on 19 subjects, test on the unseen one |
| **Secondary:** within-subject, leave-one-run-out | 120 | Train on 5 runs of a subject, test on the 6th. Needs per-user calibration |

### Results (4 classes, chance 0.25)

| | Cross-subject (primary) | Within-subject (secondary) |
|---|---|---|
| Overall accuracy | **0.320** | **0.360** |
| Per-subject mean +/- std | 0.318 +/- 0.077 | 0.358 +/- 0.153 |
| Per-subject range | 0.22 to 0.51 | 0.17 to 0.71 |
| Confidence, correct / wrong | 0.385 / 0.375 | 0.891 / 0.846 |

Per-class, cross-subject:

| Class | Recall | Precision | F1 |
|---|---|---|---|
| left_fist | 0.37 | 0.35 | 0.36 |
| right_fist | 0.25 | 0.35 | 0.29 |
| both_feet | 0.22 | 0.27 | 0.24 |
| rest | 0.43 | 0.31 | 0.36 |

### What was tried

| Variant | Cross-subject | Within-subject |
|---|---|---|
| Band power + LDA, 5 subjects, 5 classes | 0.213 | 0.286 |
| Band power + LDA, 20 subjects, 5 classes | 0.240 | 0.241 |
| CSP + LDA, 5 classes | 0.277 | 0.274 |
| CSP + LDA, 4 classes | 0.320 | 0.360 |
| Per-subject feature normalisation | no gain | |
| LDA regularisation sweep | no gain | |
| 1.5 s sliding windows (CSP + LDA, 4 classes, trial-level) | 0.321 | 0.314 |
| SVM, RBF kernel (4 classes) | 0.274 | 0.314 |
| SVM, linear kernel (4 classes) | 0.321 | 0.308 |

Sliding windows and SVM did not help. Both are still available in the class (`useWindows`, `clf = "svm"`), but the defaults are off.

## Using the trained model

`predictOne` is a static method and does not load the dataset. The input is **one processed epoch**: 64 channels x samples, already common-average-referenced and band-passed at 8 to 30 Hz, exactly like `X_epochs`. It is not the 34 band-power vector.

```matlab
S = load('models/regain_classifier.mat', 'model');
[cls, conf, info] = ReGainClassifier.predictOne(epoch, S.model);

cls                 % EEG class number: 1, 2, 4 or 5
conf                % top posterior probability
info.className      % e.g. "right_fist"
info.posterior      % posterior for each class, in the order of info.classes
```

- `cls` is the original EEG class number, so labels are preserved.
- The second argument can also be a path to the model file.
- About 5 ms per call.
- Wrong channel count or an epoch under 80 samples throws an error.

## Verification

`run_stage5` finishes with `verifyModel`, which reloads the saved model and checks:

- model file contents (64-channel filters, scaler size, class list, finite parameters)
- `predictOne` returns a valid class, a confidence in range, and posteriors summing to 1
- `predictOne` gives the same class and confidence as the batch evaluation path
- a wrong-shaped input is rejected

The expected final line is `READY for Stage 6`. The training-set accuracy it prints (about 0.44) is inflated because the model saw those trials. Use the leave-one-subject-out figures above as the real performance.

## Stage 6A: temporal decision layer

Implemented in `ReGainTemporalFilter.m`. It tests whether voting over consecutive classifier predictions makes the Stage 5 classifier stable enough to drive actions.

### What is a sequence

The sequence is the **nine 1.5 s windows inside one trial** (0.25 s hop). Consecutive trials cannot form a sequence, because cue order in these recordings is irregular and a majority vote over trials with different true classes has no correct answer. The buffer is reset at every trial. Windows from different trials, runs or subjects never mix.

### What was scored

Each window was predicted by the window-trained CSP + LDA model from Stage 5, cross-validated (a model that never saw that subject, or that run). The saved `regain_classifier.mat` was not used, because it was trained on all 20 subjects and scoring it on them would leak. `ReGainClassifier.exportStream` saves those predictions with `subject`, `run`, `trial`, `cue_s`, `win_start_s`, true class, predicted class, confidence and posteriors, sorted in time order.

### Modes (fixed before any result)

| Mode | Votes needed | First decision |
|---|---|---|
| Single | 1 of 1 | window 1 |
| 3-window majority | 2 of 3 | window 3 |
| 5-window majority | 3 of 5 | window 5 |

Otherwise the output is `NO_DECISION`. Window length and required votes are configurable. Confidence is logged and never used to decide. All modes are compared on windows 5 to 9 so they are scored on identical data.

### Results, leave-one-subject-out (20 subjects, 4 classes, chance 0.25)

| Mode | Coverage | Accuracy of accepted | Correct per opportunity | `NO_DECISION` |
|---|---|---|---|---|
| Single | 1.000 | 0.308 | 0.308 | 0 |
| 3-window | 0.991 | 0.315 | 0.312 | 80 |
| 5-window | 0.980 | 0.323 | 0.316 | 178 |
| Unanimous 5-of-5 (exploratory) | 0.603 | 0.331 | 0.200 | 3509 |

(8,840 opportunities per mode.)

| Rate | Single | 3-window | 5-window | Unanimous (exploratory) |
|---|---|---|---|---|
| False BOTH_FEET, share of non-feet opportunities | 0.165 | 0.162 | 0.159 | 0.099 |
| Person at REST gets a non-REST decision | 0.538 | 0.528 | 0.519 | 0.269 |

- **Per-subject:** single 0.307 +/- 0.069, 3-window 0.311 +/- 0.073, 5-window 0.315 +/- 0.076. The 5-window mode beats single in 15 of 20 subjects (worse in 4, tied in 1), mean gain +0.007, sign-test p = 0.02 (uncorrected). The 3-window mode is not reliably different (12 / 5 / 3, p = 0.14).
- **Why voting does so little:** neighbouring windows in a trial give the same prediction 86% of the time (28% if independent), so they repeat each other's errors.
- **Both_feet recall is about 0.20** in every mode, and about 44% of both_feet opportunities are decided as rest. About 72% of BOTH_FEET decisions are false.
- **Within-subject stream (secondary):** voting does nothing (0.296, 0.298, 0.301 correct per opportunity). The window model also over-predicts BOTH_FEET there (false BOTH_FEET rate 0.42 in every mode).
- **Unanimous 5-of-5** was fixed in advance, run once on all 20 subjects, and is labelled exploratory. It keeps 65% of correct decisions but 58% of wrong ones, so its rejections are only slightly selective.

### Using the filter

```matlab
f = ReGainTemporalFilter(5);              % 3 of 5 majority; ReGainTemporalFilter(5, 5) is unanimous
[intent, info] = f.update(predictedClass, confidence);

intent            % "NO_DECISION", "LEFT_FIST", "RIGHT_FIST", "BOTH_FEET" or "REST"
info.agreement    % e.g. "4/5"
info.confidence   % mean confidence of the winning votes (logged, not used)
info.cls          % winning class number, NaN if no decision
f.reset()         % call at the start of every new sequence
```

Invalid predictions (NaN or an unknown class) are ignored and do not enter the buffer. `ReGainTemporalFilter.selfTest()` checks the logic on hand-made sequences.

### Recommendation

No temporal window makes this classifier safe on its own. If a temporal layer is kept, use 5-window majority as a mild smoother only (about 0.7 percentage points of gain, and only for unseen subjects). Do not use unanimous 5-of-5 as a safety gate. Safety must come from the application layer: speak the selected destination, require an explicit confirmation before moving, treat `NO_DECISION` and `REST` as no command, and never act on a single `BOTH_FEET`.

Rates above are per window position inside cued trials, not per second of real operation.

## Limitations

- **Accuracy is not usable for direct control.** About one trial in three is correct for an unseen subject. Right_fist and both_feet, the planned "next" and "confirm" commands, are at or just above chance recall.
- **Confidence does not separate right from wrong.** The gap between correct and wrong predictions is about 0.01 to 0.05. It cannot gate a command by itself.
- **Temporal voting does not fix this.** Stage 6A tested 3-window and 5-window majority voting. Errors are systematic (for example both_feet read as rest) and repeat across overlapping windows, so voting gains only about 0.7 percentage points.
- **False confirms.** About 7 in 10 BOTH_FEET decisions are wrong, in every voting mode.
- **A voting layer needs its own final model.** The evaluation used window-trained, cross-validated predictions. `trainFinal` does not support windows yet, so no final window-trained model exists.
- **Cued trials only.** Idle periods, transitions between commands and real-time delay are untested. The 5-window mode adds about 1 s of decision delay.
- **Per-user calibration helps but is not enough.** Within-subject accuracy is higher on average but varies widely between people.
- **Small data.** 20 subjects and about 22 trials per class per subject.
- **Parameter choices were made on the same folds used for reporting.** The numbers are slightly optimistic.
- **Public dataset only.** No EEG hardware and no real-time test.
- **Input differs from the original prompt.** `predictOne` takes an epoch, not a feature vector, because CSP features need the epoch.

## Planned application mapping (not in this code)

Not hard-coded in the classifier. It belongs to the state-machine stage.

| EEG class | Planned role |
|---|---|
| left_fist | cancel / back |
| right_fist | next destination |
| both_feet | confirm destination |
| rest | stop / no command |
| both_fists | reserved (excluded from the model) |

## Next

Stage 6B: connect MATLAB to ROS 2 Jazzy (publishing on `/regain/bci_command`), starting with a read-only check of the MATLAB release, ROS Toolbox and the DDS settings (`ROS_DOMAIN_ID`, RMW implementation). If the voting layer is kept, train a final window-trained model first. The application layer then applies the mapping and the safety logic (spoken confirmation, REST as stop).