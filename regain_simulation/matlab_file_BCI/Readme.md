# ReGain: MATLAB EEG pipeline and intention classifier

MATLAB side of ReGain, a BCI-based assistive mobility prototype.
This folder covers **Stage 4** (EEG preprocessing), **Stage 5** (intention classifier), **Stage 6A** (temporal decision layer) and **Stage 6B** (MATLAB to ROS 2 link).
The ROS 2 package, Gazebo, the state machine and voice feedback are not in this folder.

```
public EEG dataset -> MATLAB preprocessing -> labelled trials
                   -> CSP + LDA classifier -> predicted EEG class + confidence
                   -> temporal filter (vote over consecutive windows) -> intent or NO_DECISION
                   -> ReGainROS2Link -> /regain/eeg_intent (JSON in std_msgs/String)
```

The classifier only outputs an **EEG class number and a confidence**, and the temporal filter only outputs an **EEG class name or `NO_DECISION`**. Neither knows about destinations or wheelchair commands. That mapping is applied later.

## Requirements

- MATLAB R2025b (developed and tested on this release). `edfread` needs R2020b or newer, `xregion` needs R2023b or newer.
- Signal Processing Toolbox (`butter`, `filtfilt`, `pwelch`, `bandpower`)
- Statistics and Machine Learning Toolbox (`fitcdiscr`, `fitcecoc`, `confusionmat`, `binocdf`)
- Internet access on the first run, to download the EDF files (about 300 MB for 20 subjects)
- ROS Toolbox (Stage 6B only), with ROS 2 Jazzy on the same machine and `rmw_cyclonedds_cpp` installed

## Folder layout

```
regain_simulation/
  ReGainEEG.m            Stage 4: loading, preprocessing, epoching, features, saving
  ReGainClassifier.m     Stage 5: CSP, LDA/SVM, evaluation, final model, predictOne
  ReGainTemporalFilter.m Stage 6A: voting over consecutive predictions, evaluation methods
  ReGainROS2Link.m       Stage 6B: publishes intents to ROS 2 (fake stream, replay)
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

Stage 4 takes several minutes the first time because of the downloads. Stage 5 takes a few minutes, mostly for the 20-fold cross-subject evaluation. `run_stage6a` takes under a minute if `results/stream_*.mat` exist. If they are missing it regenerates them (about 3 minutes). Stage 6B has no run script; see its own section for the test commands.

After editing a method in a class file, run `clear bci` (or `clear eeg`, `clear link`) and create the object again. Do not use `clear classes`, which prints warnings about Simulink classes.

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

## Stage 6B: MATLAB to ROS 2 link

Implemented in `ReGainROS2Link.m`. It publishes the EEG intent stream into ROS 2. It does not change the classifier or the temporal filter, and it does not publish on `/regain/bci_command`, which stays the motion input of the ROS 2 command node.

### Interface

| Item | Value |
|---|---|
| Topic | `/regain/eeg_intent` |
| Type | `std_msgs/msg/String`, payload is JSON |
| QoS | reliable, volatile, keep last 10 |
| Rate | set by the caller; the replay uses 4 Hz (the 0.25 s window hop) |
| Node | `/regain_matlab_link`, domain 0, `rmw_cyclonedds_cpp` |

Message example:

```
{"seq":14,"t":1.79453323454494E+9,"intent":"LEFT_FIST","confidence":0.354,"agreement":"4/5"}
```

| Field | Meaning |
|---|---|
| `seq` | message counter, +1 per message, starts at 1 for each new `ReGainROS2Link` object |
| `t` | Unix time in UTC, seconds (may be written in scientific notation) |
| `intent` | `NO_DECISION`, `LEFT_FIST`, `RIGHT_FIST`, `BOTH_FEET` or `REST` |
| `confidence` | mean confidence of the winning votes, or `null` for `NO_DECISION` |
| `agreement` | filter votes, for example `"4/5"` |

**Consumers must act on `intent` only.** During warm-up `agreement` can read `4/4` while `intent` is still `NO_DECISION`, because the filter does not decide before its buffer is full. An unknown intent word raises an error in MATLAB and is never sent.

### Why the RMW and domain are set in the class

The ROS 2 side uses `rmw_cyclonedds_cpp` on domain 0. MATLAB inherited neither variable (it was not started from a terminal), and the `ros2node` default RMW is `rmw_fastrtps_cpp`, so the constructor sets both with `setenv` before the first node is created. In a MATLAB session that has already created a ROS 2 node, the RMW cannot be changed; restart MATLAB.

### Methods

| Method | Use |
|---|---|
| `ReGainROS2Link()` | creates the node and publisher |
| `publishIntent(intent, confidence, agreement)` | validates and sends one message |
| `runFakeStream(nMsgs, rateHz)` | fixed repeating pattern, for link tests with no EEG |
| `replayStream(T, filt, rateHz)` | replays cross-validated window predictions (`results/stream_subject.mat`, table `T`) through a `ReGainTemporalFilter` and publishes each output. Resets the filter at every new trial. Returns a log table (`seq`, `y_true`, `pred`, `intent`, `agreement`) |

### How to test (no Gazebo needed)

Terminal, with the ROS 2 environment sourced:

```bash
ros2 topic echo /regain/eeg_intent
ros2 topic hz /regain/eeg_intent
```

MATLAB, fake stream (80 messages, about 20 s):

```matlab
link = ReGainROS2Link();
link.runFakeStream(80, 4);
```

MATLAB, replay (first subject, first three trials, 27 messages):

```matlab
S = load('results/stream_subject.mat');
T = S.T;
T = T(T.subject == T.subject(1), :);
[~,~,g] = unique(T(:, {'run','trial'}), 'rows', 'stable');
T = T(g <= 3, :);
link = ReGainROS2Link();
f    = ReGainTemporalFilter(5);
L    = link.replayStream(T, f, 4);   % not named "log", which would hide MATLAB's log function
disp(L)
```

After editing the class, run `clear link` and create the object again (it is a handle class).

### Results

| Test | Result |
|---|---|
| MATLAB node visible to `ros2 node list` | yes, with no ROS 2 launch running |
| Fake stream | 80 of 80 received, `seq` 1 to 80 with no gaps, content as sent |
| Rate | 4.000 Hz average, intervals 0.246 to 0.254 s |
| Replay | 27 messages sent. `seq` 1 to 22 compared with the echo and identical in `intent` and `agreement`. `seq` 23 to 27 are in the MATLAB log but were not in the echo that was captured |
| Trial boundaries | the filter resets (`1/1` at `seq` 10 and 19) |
| JSON | `confidence` is `null` during warm-up and a float once a decision is made |

### Stage 6B limitations

- No ROS 2 receiver existed when Stage 6B was tested, so only `ros2 topic echo` and `ros2 topic hz` were used on the stream. The Stage 7 application node now consumes it (see the ROS package README). `ros2 topic info` was never run.
- The publisher is volatile, so a subscriber that starts mid-stream does not receive earlier messages. Not tested.
- Only the first subject's first three trials were replayed. Longer replays are untested.
- The stream carries `seq` and `t`, but nothing drops stale or repeated messages yet.
- The replay shows the weakness of the classifier (in the second replayed trial, true right fist was never predicted). That is a classifier property, not a link fault.
- The replay uses cross-validated window predictions. Live `predictOne` has not been connected, and no final window-trained model exists.
- The RMW and domain are fixed in the constructor.

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
- **The link is one-way.** Stage 6B only publishes. The ROS 2 application node (Stage 7, in the ROS package) consumes `/regain/eeg_intent`, but nothing flows back to MATLAB yet.

## Application mapping (implemented in the ROS 2 package, not in this folder)

Not hard-coded in the classifier or the filter. The Stage 7 node `regain_application_node` applies it (see the ROS package README).

| EEG intent | Role |
|---|---|
| right_fist | next destination |
| left_fist | previous destination; also backs out of a confirmation and cancels a confirmed destination |
| both_feet | confirm: the first one asks, the second one confirms |
| rest, no_decision | no action (they also re-arm the application latch) |
| both_fists | reserved (excluded from the model) |

## Next

Stages 6B (the MATLAB to ROS 2 link) and 7 (the ROS 2 application state machine) are done. Next on the MATLAB side is an app that shows the 4 Hz intent stream, sends simulated intents and shows the application state. Voice feedback and navigation are ROS 2 work. If the voting layer is kept, train a final window-trained model before connecting live `predictOne`.