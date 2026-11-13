# ReGain: `regain_simulation`

ReGain is a brain-computer-interface (BCI) assistive mobility project. The goal is a simulated powered wheelchair that receives high-level intentions from a BCI pipeline, validates them through a ROS 2 safety layer, and executes them in Gazebo.

This package holds the ROS 2 and simulation side: a powered wheelchair and a compact indoor house in Gazebo Harmonic, a command node that turns high-level motion commands into limited, time-bounded velocity commands, and an application node that turns the EEG intent stream from MATLAB into destination selection.

```
EEG dataset -> MATLAB (processing + ML) -> /regain/eeg_intent -> application node -> destination state
                                                                  (not yet connected)
                          source -> /regain/bci_command -> command node -> /regain/cmd_vel -> Gazebo wheelchair
```

The two chains are not connected yet. The application node produces a selected and a confirmed destination and never moves the chair. `/regain/bci_command` is still driven only from the ROS 2 command line.

The MATLAB side (EEG processing, classifier, temporal filter and the MATLAB-to-ROS 2 link) is a separate project in `~/workspace/Matlab_workspace/regain_simulation/` with its own README.

## Status

| Stage | Scope | State |
|---|---|---|
| 1 | ROS 2 package, Gazebo Harmonic launch, `/clock` bridge | Done |
| 2 | Wheelchair model, house world, `/regain/cmd_vel` drive interface | Done |
| 3 | High-level motion commands: `/regain/bci_command`, validation, timeout, speed limits | Done |
| 4, 5, 6A | EEG preprocessing, classifier, temporal filter | Done, in the MATLAB project |
| 6B | MATLAB to ROS 2 link on `/regain/eeg_intent` | Done, in the MATLAB project |
| 7 | Application state machine: destination selection and confirmation, `/regain/app_state` | Done, no motion |
| Later | Voice feedback, output watchdog, sensors, navigation, connecting a confirmed destination to motion | Not started |

## Requirements

- Ubuntu 24.04
- ROS 2 Jazzy, with `rmw_cyclonedds_cpp` (the MATLAB link uses it)
- Gazebo Harmonic (installed through the `ros-jazzy-gz-*-vendor` packages)
- `ros_gz_sim` and `ros_gz_bridge` (part of `ros-jazzy-ros-gz`)
- `rclpy`, `std_msgs`, `geometry_msgs` (part of the ROS 2 desktop install)
- `colcon`

## Package structure

```
regain_simulation/
├── config/
│   └── command_node.yaml           # speeds, caps, timeout, publish rate
├── launch/
│   └── regain_sim.launch.py        # Gazebo, wheelchair spawn, bridge, command node
├── models/
│   └── regain_wheelchair/
│       └── model.sdf               # wheelchair geometry + DiffDrive plugin
├── regain_simulation/
│   ├── __init__.py
│   ├── command_node.py             # /regain/bci_command -> /regain/cmd_vel
│   ├── state_machine.py            # Stage 7 logic, pure Python, no ROS, has a self-test
│   └── regain_application_node.py  # Stage 7 node: /regain/eeg_intent -> /regain/app_state
├── worlds/
│   ├── regain_house.sdf            # house, furniture, destination marker (default world)
│   └── empty_world.sdf             # flat ground, kept as a debugging world
├── resource/regain_simulation
├── test/
├── package.xml
├── setup.py
└── setup.cfg
```

`setup.py` has two console entry points: `command_node` (started by the launch file) and `regain_application_node` (started with `ros2 run`).

## Build

This package lives inside an existing workspace with other projects, so always build it alone. Build from a shell with no Python virtual environment active (run `deactivate` first if your prompt shows one), because `colcon` records the active Python in the installed entry-point scripts and a virtual environment without `rclpy` would break `ros2 run`.

```bash
cd ~/workspace/ros2_ws
colcon build --packages-select regain_simulation
source install/setup.bash
```

Launch, world, model and config files are copied into `install/` at build time. Rebuild after editing them, or build once with `--symlink-install` to skip that. A newly added file or entry point always needs one rebuild, because `setup.py` collects files at build time.

## Run

```bash
ros2 launch regain_simulation regain_sim.launch.py
```

This starts Gazebo with the house, spawns the wheelchair in the hallway just inside the front door, starts the bridge, and starts `regain_command_node`. The launch terminal prints `Ready: 0.3 m/s, 0.5 rad/s, timeout 0.7 s`.

The launch file waits 3 seconds before spawning the chair, so the Gazebo server is ready. If the chair doesn't appear and the terminal shows a service timeout, increase `period` in the `TimerAction`.

If the Gazebo GUI is black or crashes on a Wayland session, force X11 for that one command:

```bash
QT_QPA_PLATFORM=xcb ros2 launch regain_simulation regain_sim.launch.py
```

Stop with Ctrl+C. The launch reports an `[ERROR]` with exit code `-2` for the `gazebo` process. This is cosmetic: ROS 2 launch labels the SIGINT shutdown that way, and no processes are left running.

The application node is not part of the launch file. Start it in its own terminal (after sourcing the workspace):

```bash
ros2 run regain_simulation regain_application_node
```

It does not need Gazebo.

## Drive the wheelchair

In a second terminal:

```bash
source ~/workspace/ros2_ws/install/setup.bash
```

Valid commands are `FORWARD`, `BACKWARD`, `LEFT`, `RIGHT` and `STOP`. Matching is exact, so `forward` is rejected.

**Continuous commands (the realistic case).** A command stays active only for the timeout, so a source must keep re-sending it, as a BCI classifier would. `-r 10` publishes 10 times a second:

```bash
ros2 topic pub -r 10 /regain/bci_command std_msgs/msg/String "{data: 'FORWARD'}"
```

Press Ctrl+C and the chair stops within the timeout. Replace `FORWARD` with `LEFT`, `RIGHT`, `BACKWARD` or `STOP`.

**One-shot command.** The chair moves for about 0.7 s and then stops by itself:

```bash
ros2 topic pub --once /regain/bci_command std_msgs/msg/String "{data: 'FORWARD'}"
```

**All five commands in sequence:**

```bash
for cmd in FORWARD LEFT RIGHT BACKWARD STOP; do
  echo "Sending $cmd"
  timeout 3 ros2 topic pub -r 10 /regain/bci_command std_msgs/msg/String "{data: '$cmd'}" > /dev/null
done
```

**Invalid command.** The chair does not move, and the node logs a warning:

```bash
ros2 topic pub --once /regain/bci_command std_msgs/msg/String "{data: 'JUMP'}"
```

**Watch the output the chair receives, and the odometry:**

```bash
ros2 topic echo /regain/cmd_vel --field linear.x
ros2 topic echo /regain/odom --field pose.pose.position --once
```

**Do not publish to `/regain/cmd_vel` directly, and do not run `teleop_twist_keyboard`, while the command node is running.** The node publishes on that topic at 20 Hz, so a second publisher would fight it. Always drive through `/regain/bci_command`.

## ROS 2 interface

| Topic | Type | Direction | Notes |
|---|---|---|---|
| `/regain/bci_command` | `std_msgs/msg/String` | Source (command line for now) to command node | `FORWARD`, `BACKWARD`, `LEFT`, `RIGHT`, `STOP`. Plain words, not JSON |
| `/regain/cmd_vel` | `geometry_msgs/msg/Twist` | Command node to Gazebo | Published at 20 Hz. The command node should be its only publisher |
| `/regain/odom` | `nav_msgs/msg/Odometry` | Gazebo to ROS 2 | Published by the DiffDrive plugin, frame `odom` |
| `/clock` | `rosgraph_msgs/msg/Clock` | Gazebo to ROS 2 | Simulation time |
| `/regain/eeg_intent` | `std_msgs/msg/String` (JSON) | MATLAB to application node | Reliable, volatile, depth 10. Published at 4 Hz by the MATLAB replay |
| `/regain/app_state` | `std_msgs/msg/String` (JSON) | Application node to anyone | Reliable, transient local, depth 1. Published only when something happens |

`/regain/cmd_vel`, `/regain/odom` and `/clock` go through one `ros_gz_bridge` `parameter_bridge` node. The direction of each is fixed by the bridge argument: `[` is Gazebo to ROS, `]` is ROS to Gazebo.

The two EEG-side topics are separate from `/regain/bci_command` on purpose: the EEG intents (`LEFT_FIST` and so on) only have meaning inside the application state, so they never go to the motion node directly.

## Command node

`regain_command_node` (`regain_simulation/command_node.py`) is the only publisher on `/regain/cmd_vel`.

- **Validation.** Any message that is not one of the five commands is rejected, the chair stops, and a warning is logged.
- **Timeout.** The node publishes every 50 ms. If no valid command arrived within `command_timeout` seconds, it publishes zero velocity. This covers a source that crashes or disconnects.
- **Speed limits.** Configured speeds are clamped to the hard caps, whatever the config file says. The Gazebo DiffDrive plugin has its own limits (1.0 m/s, 1.5 rad/s) as a further layer.
- **Confidence extension point.** `parse_message()` returns `(intention, confidence)`, with confidence fixed at 1.0 for now, and `is_valid()` is where a confidence threshold would go. The command node is unchanged since Stage 3. The EEG confidence travels on `/regain/eeg_intent`, not here.

Parameters, in `config/command_node.yaml`:

| Parameter | Default | Meaning |
|---|---|---|
| `linear_speed` | 0.3 m/s | Speed for `FORWARD` and `BACKWARD` |
| `angular_speed` | 0.5 rad/s | Speed for `LEFT` and `RIGHT` |
| `max_linear_speed` | 0.5 m/s | Hard cap on linear speed |
| `max_angular_speed` | 0.8 rad/s | Hard cap on angular speed |
| `command_timeout` | 0.7 s | Time without a valid command before the chair stops |
| `publish_rate` | 20 Hz | How often `/regain/cmd_vel` is published |

The top key in the YAML must match the node name (`regain_command_node`), or the parameters are silently ignored. Check a value with `ros2 param get /regain_command_node command_timeout`.

## Application node (Stage 7)

`regain_application_node` consumes the EEG intent stream from MATLAB and runs a deterministic destination-selection state machine. The logic is in `state_machine.py` (no ROS imports), and the node in `regain_application_node.py` wraps it. **The node never publishes `/regain/cmd_vel` or `/regain/bci_command` and never moves the wheelchair.**

### Input

`/regain/eeg_intent` carries JSON in a `std_msgs/String`, for example:

```
{"seq":14,"t":1.79453323454494E+9,"intent":"LEFT_FIST","confidence":0.354,"agreement":"4/5"}
```

The node reads only `intent`. `confidence`, `agreement`, `seq` and `t` are diagnostic and may be any type or missing. During the MATLAB filter's warm-up `agreement` can read `4/4` while `intent` is still `NO_DECISION`, which is why only `intent` is used. Valid intents: `LEFT_FIST`, `RIGHT_FIST`, `BOTH_FEET`, `REST`, `NO_DECISION`. Malformed JSON, a missing `intent` field or an unknown value gives a warning, no action, and the node keeps running.

### States and destinations

States: `IDLE`, `SELECTING`, `CONFIRMING`, `CONFIRMED`, `CANCELLED`. `CANCELLED` is a one-step transient: it is entered and left in the same step, so the node rests in `IDLE` afterwards.

Destinations: `BEDROOM`, `KITCHEN`, `LIVING_ROOM`, `ENTRANCE`, with wrap-around. The node starts in `IDLE` with `BEDROOM` highlighted, so the first `RIGHT_FIST` selects `KITCHEN`.

| Intent | `IDLE` | `SELECTING` | `CONFIRMING` | `CONFIRMED` |
|---|---|---|---|---|
| `RIGHT_FIST` | next destination, go to `SELECTING` | next destination | ignored | ignored |
| `LEFT_FIST` | previous destination, go to `SELECTING` | previous destination | cancel, back to `SELECTING` | cancel: clear the confirmed destination, `CANCELLED`, then `IDLE` |
| `BOTH_FEET` | ignored | ask: `CONFIRMING` | confirm: `CONFIRMED`, destination stored | ignored |
| `REST`, `NO_DECISION` | no action | no action | no action | no action |

Confirmation is two steps on purpose: the first `BOTH_FEET` only asks ("Confirm destination: X"), and a second `BOTH_FEET`, after a `REST` or `NO_DECISION` in between, confirms. A confirmed destination is stored and logged and the chair stays stopped.

### Latch (debounce)

The EEG stream is continuous at 4 Hz, so one sustained intent arrives as many messages. The node acts once on an actionable intent and then ignores further actionable intents until a `REST` or `NO_DECISION` arrives. Four `RIGHT_FIST` in a row move the destination once. A direct switch with no `REST` in between (`RIGHT_FIST` then `LEFT_FIST`) ignores the second one. The latch is message-based, not time-based.

### Output

- **Terminal log.** Only real events are logged (state changes, destination changes, ignored actionable intents, warnings). `REST`, `NO_DECISION` and latched repeats are silent, so 4 Hz does not flood the terminal. On Ctrl+C the node prints a `Summary:` line with its counters.
- **`/regain/app_state`.** One JSON message per state-changing action, plus one at start-up. Late subscribers get the last one (transient local). Example:

```
{"state": "CONFIRMED", "destination": "KITCHEN", "confirmed_destination": "KITCHEN", "last_intent": "BOTH_FEET", "events": ["Destination confirmed: KITCHEN", "State: CONFIRMED"]}
```

Summary counters: `received`, `malformed`, `no_action` (`REST` and `NO_DECISION`), `suppressed` (actionable but latched), `acted`, `destination_changes`, `confirmations`. `acted` counts every actionable message that produced an event, including "Ignored X in state Y" events, so it is larger than the number of real state changes.

### Test without MATLAB

Offline logic test, no ROS needed (20 checks, ends with `ALL PASS`):

```bash
cd ~/workspace/ros2_ws/src/regain_simulation/regain_simulation
python3 state_machine.py
```

With the node running (`ros2 run regain_simulation regain_application_node`), watch the state in a second terminal:

```bash
ros2 topic echo --full-length /regain/app_state
```

and in a third, define a small helper (it exists only in that terminal) and send intents:

```bash
send() { for i in "$@"; do ros2 topic pub --once /regain/eeg_intent std_msgs/msg/String "{data: '{\"intent\":\"$i\"}'}" >/dev/null; done; }

send RIGHT_FIST RIGHT_FIST RIGHT_FIST RIGHT_FIST REST        # one change to KITCHEN
send BOTH_FEET REST BOTH_FEET REST                           # ask, then confirm KITCHEN
send LEFT_FIST REST                                          # cancel the confirmed destination
ros2 topic pub --once /regain/eeg_intent std_msgs/msg/String "{data: '{not json'}"   # warning only
```

### Test with MATLAB

Start a fresh node first (the topic is volatile, so messages sent before the node is up are lost), then run a replay from the MATLAB project (see its README, Stage 6B). Wait a second after MATLAB finishes, then press Ctrl+C on the node to read the summary. If you copy the node output with `tee`, use `tee -i`, otherwise Ctrl+C also stops `tee` before the summary is written:

```bash
ros2 run regain_simulation regain_application_node 2>&1 | tee -i /tmp/stage7.log
```

### Results

| Test | Result |
|---|---|
| Offline self-test | 20 of 20 checks pass |
| Fake stream: next, previous, confirm, repeated intent, no decision | as expected; 4 x `RIGHT_FIST` and `REST` gave one change |
| Fake stream: malformed JSON, unknown intent, missing `intent` | 3 warnings, no state change, node kept running |
| Fake stream: confirm then cancel | `CONFIRMING`, `CONFIRMED`, then `CANCELLED` and `IDLE`, destination cleared |
| Replay, subject 1 (837 messages, 20 Hz) | `received=837, malformed=0, no_action=637, suppressed=149, acted=51, destination_changes=51, confirmations=0`. Run twice, identical. The stream contained no `BOTH_FEET`, so the confirm path was not reached |
| Replay, subject 6 (828 messages, 20 Hz) | `received=828, malformed=0, no_action=449, suppressed=289, acted=90, destination_changes=3, confirmations=3`. 3 confirm prompts, 3 confirmations, 2 cancels |

The MATLAB counts reconcile with the node counters in both replays (messages, `REST` plus `NO_DECISION`, and actionable intents). The replay rate was 20 Hz instead of 4 Hz to save time, which does not change the counts because the latch is message-based.

Subject 6 was chosen because its stream has many `BOTH_FEET` decisions (363 of 828 messages), so it reaches the confirm path. That is the classifier over-predicting `BOTH_FEET` for this subject, and the confirmations are not evidence of intent.

## Architecture

```
 MATLAB (ReGainTemporalFilter -> ReGainROS2Link)
        │  JSON in std_msgs/String, 4 Hz
        ▼
 /regain/eeg_intent ──▶ regain_application_node
                           · latch (one action per held intent)
                           · state machine: IDLE / SELECTING / CONFIRMING / CONFIRMED
        │  JSON state, on change
        ▼
 /regain/app_state          (read-only; nothing consumes it yet, and no motion)

 - - - - - - - - - - - - - not connected yet - - - - - - - - - - - - -

 source (command line now)
        │  std_msgs/String, e.g. "FORWARD"
        ▼
 /regain/bci_command ──▶ regain_command_node
                           · validate (unknown command -> STOP)
                           · timeout  (stale -> zero velocity)
                           · speed caps
        │  geometry_msgs/Twist, 20 Hz
        ▼
 /regain/cmd_vel ──▶ ros_gz_bridge ──▶ DiffDrive plugin ──▶ Gazebo wheelchair
                                                                  │
 /regain/odom, /clock  ◀──────────── ros_gz_bridge ◀──────────────┘
```

- **World:** `regain_house.sdf` defines the world `regain_world`. The spawn command and the plugins refer to that name, so keep it if you add other worlds.
- **Wheelchair:** one rigid body link with two drive wheels (radius 0.17 m, 0.58 m apart) and two frictionless sphere casters at the front. The model origin is on the floor at the drive axle, with +x forward, +y left and +z up.
- **Spawning:** the launch file spawns the chair with `ros_gz_sim create`, so the start pose changes in the launch file without touching the world.

## The house

Approximate layout, in metres. The front door is on the west wall (`D`, y 0.3 to 1.3), and the chair spawns just inside it:

```
y=8  +--------------+------------------+
     |              |    BEDROOM       |
     |   LIVING     [door 6.0-7.0]     |
     |   ROOM       +------------------+  y=5
     |              [opening 2.7-3.9]  |
     |              |  KITCHEN/DINING  |
y=1.6+---[door]-----+-------[door]-----+
     D           HALLWAY               |
y=0  +--------------------------------+
    x=0           x=5               x=10
```

- Doors are 1.0 m wide and the kitchen opening is 1.2 m. The wheelchair is about 0.64 m wide.
- The floor of each room is a visual-only slab on the grass plane, so there are no steps at doorways.
- Furniture: sofa, coffee table, bookshelf and plant in the living room. Counter, sink, fridge, dining table and four chairs in the kitchen. Bed, bedside table and wardrobe in the bedroom.
- A green disc at (8.0, 5.6), beside the bed, marks a destination for later navigation work.
- There is no ceiling, so the interior is visible from above.
- There is no "outside" yet. The `ENTRANCE` destination exists only as a name in the application node, with no pose behind it.

## Key equations

Symbols: `v` linear velocity (m/s), `w` angular velocity (rad/s), `r` wheel radius = 0.17 m, `L` wheel separation = 0.58 m, `T` command timeout = 0.7 s.

**1. Differential-drive kinematics.** The Gazebo DiffDrive plugin turns each `Twist` into wheel speeds. We don't implement this ourselves, but its two parameters (`r` and `L`) come from our model:

```
wheel_left  = (v - w * L/2) / r      [rad/s]
wheel_right = (v + w * L/2) / r      [rad/s]
```

Worked values with `L/2 = 0.29` and `r = 0.17`:

| Command | v | w | Left wheel | Right wheel |
|---|---|---|---|---|
| FORWARD | 0.3 | 0 | +1.76 rad/s | +1.76 rad/s |
| BACKWARD | -0.3 | 0 | -1.76 rad/s | -1.76 rad/s |
| LEFT (spin in place) | 0 | 0.5 | -0.85 rad/s | +0.85 rad/s |
| RIGHT (spin in place) | 0 | -0.5 | +0.85 rad/s | -0.85 rad/s |

Plugin limits as wheel speed: 1.0 m/s is 5.88 rad/s, and 1.5 rad/s of spin is 2.56 rad/s per wheel.

**2. Odometry (unicycle model).** The plugin integrates the pose from the same velocities:

```
x     += v * cos(theta) * dt
y     += v * sin(theta) * dt
theta += w * dt
```

**3. Speed clamp (command node).** Configured speeds can never exceed the hard caps:

```
v_cmd = min(|linear_speed|,  max_linear_speed)     = min(0.3, 0.5) = 0.3 m/s
w_cmd = min(|angular_speed|, max_angular_speed)    = min(0.5, 0.8) = 0.5 rad/s
```

**4. Command freshness (timeout).** A command moves the chair only while it is fresh:

```
fresh  <=>  (t_now - t_last_command) <= T          T = 0.7 s
```

A single one-shot `FORWARD` therefore moves the chair at most about `0.3 * 0.7 = 0.21 m`, or a one-shot `LEFT` about `0.5 * 0.7 = 0.35 rad` (20 degrees). The real figure is a little different because of the plugin's acceleration limits and the 20 Hz publish interval.

**5. Wheel inertia (solid cylinder).** The wheel inertias in `model.sdf` come from the solid-cylinder formulas, with `m = 3 kg`, `r = 0.17 m` and length `h = 0.06 m`:

```
Ixx = Iyy = m * (3*r^2 + h^2) / 12 = 3 * (0.0867 + 0.0036) / 12 = 0.0226 kg m^2
Izz       = m * r^2 / 2            = 0.0434 kg m^2
```

The body inertia (`40 kg`, `ixx 3.0`, `iyy 4.3`, `izz 3.0`) is a rough estimate for a body of about 0.7 x 0.5 x 0.7 m, not derived from the geometry. Refine it if stability becomes an issue.

**6. Geometry checks.** These back the navigation space:

```
Width across the wheels   = L + wheel length         = 0.58 + 0.06 = 0.64 m
Clearance in a 1.0 m door = (1.0 - 0.64) / 2          = 0.18 m per side
Front-corner turn radius  = sqrt(0.60^2 + 0.17^2)     = 0.62 m   (footplate front edge at x = 0.60)
Turning circle diameter   = 2 * 0.62                  = 1.25 m
Hallway clear width       = 1.6 - 0.15 (wall)         = 1.45 m
Margin when spinning      = (1.45 - 1.25) / 2         = 0.10 m per side
```

The 10 cm margin is why the chair can spin in the hallway, but only when it is centred.

## Known limitations

- **This is not a complete safety system.** The ROS 2 layer validates commands, applies a timeout and limits speed. It has no obstacle awareness and cannot judge whether a valid command is sensible.
- **The EEG side is weak and the application node does not fix that.** The MATLAB classifier is about 0.32 accurate on unseen subjects (chance 0.25), and about 7 in 10 `BOTH_FEET` decisions are false. The two-step confirmation and the latch reduce accidental actions but do not make confirmation trustworthy. Nothing in this package shows that EEG can safely control a wheelchair.
- **A confirmed destination does nothing yet.** The application node stores and logs it. No navigation exists, and nothing connects the application node to `/regain/bci_command`.
- **No voice feedback yet.** The terminal log and `/regain/app_state` are the only outputs. Voice would be a separate ROS 2 node reading `/regain/app_state`, not part of Gazebo.
- **The application node is not in the launch file** and must be started separately.
- **Held intents need a `REST` or `NO_DECISION` between actions.** A real user who switches direction directly loses one command. In a replay, the MATLAB filter's per-trial reset adds extra `NO_DECISION` messages that re-arm the latch, so a continuous live stream would behave differently. This is inferred from the timing, not measured.
- **Cancelling clears the confirmed destination but leaves the highlighted one where it was.**
- **The `acted` counter includes ignored events** (see the Application node section).
- **Only two subjects were replayed** (1 and 6). The `ENTRANCE` destination has no pose.
- **Cosmetic:** pressing Ctrl+C on the application node prints "Failed to publish log message to rosout", because the ROS context is already closed when the summary is logged. The summary itself is written.
- **The command-node timeout protects against the command source dying, not the command node dying.** If `regain_command_node` crashes while the chair is moving, the DiffDrive plugin keeps the last velocity. An output-side watchdog is needed in a later stage.
- **The timeout uses wall time**, so it keeps counting if the simulation is paused.
- Odometry is published as a message only. There is no `odom -> base_link` TF transform yet, which Nav2 and RViz will need.
- The chair has no sensors yet. Obstacle detection will need a lidar or depth camera.

## Roadmap

- MATLAB app to visualise the 4 Hz intent stream, send simulated intents and show `/regain/app_state`
- Voice feedback node reading `/regain/app_state`
- Output-side watchdog and a stronger safety supervisor
- Obstacle sensing
- Navigation to the confirmed destination, including an outside area and a pose for each destination
- Rehabilitation visualization

## License

Apache-2.0