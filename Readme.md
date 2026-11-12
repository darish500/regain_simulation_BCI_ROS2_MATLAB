# ReGain: `regain_simulation`

ReGain is a brain-computer-interface (BCI) assistive mobility project. The goal is a simulated powered wheelchair that receives high-level movement intentions from a BCI pipeline, validates them through a ROS 2 safety layer, and executes them in Gazebo.

This package holds the simulation layer: a powered wheelchair and a compact indoor house in Gazebo Harmonic, plus a ROS 2 command node that turns high-level commands into limited, time-bounded velocity commands.

```
EEG dataset -> MATLAB (processing + ML) -> movement intention -> ROS 2 command node -> /regain/cmd_vel -> Gazebo wheelchair
```

## Status

| Stage | Scope | State |
|---|---|---|
| 1 | ROS 2 package, Gazebo Harmonic launch, `/clock` bridge | Done |
| 2 | Wheelchair model, house world, `/regain/cmd_vel` drive interface | Done |
| 3 | High-level command interface: `/regain/bci_command`, validation, timeout, speed limits | Done |
| 4+ | MATLAB BCI connection, output watchdog, sensors, navigation | Not started |

MATLAB and EEG processing are not integrated yet. High-level commands are sent from the ROS 2 command line.

## Requirements

- Ubuntu 24.04
- ROS 2 Jazzy
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
│   └── command_node.py             # /regain/bci_command -> /regain/cmd_vel
├── worlds/
│   ├── regain_house.sdf            # house, furniture, destination marker (default world)
│   └── empty_world.sdf             # flat ground, kept as a debugging world
├── resource/regain_simulation
├── test/
├── package.xml
├── setup.py
└── setup.cfg
```

## Build

This package lives inside an existing workspace with other projects, so always build it alone:

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
| `/regain/bci_command` | `std_msgs/msg/String` | Source (CLI now, MATLAB later) to command node | `FORWARD`, `BACKWARD`, `LEFT`, `RIGHT`, `STOP` |
| `/regain/cmd_vel` | `geometry_msgs/msg/Twist` | Command node to Gazebo | Published at 20 Hz. The command node should be its only publisher |
| `/regain/odom` | `nav_msgs/msg/Odometry` | Gazebo to ROS 2 | Published by the DiffDrive plugin, frame `odom` |
| `/clock` | `rosgraph_msgs/msg/Clock` | Gazebo to ROS 2 | Simulation time |

`/regain/cmd_vel`, `/regain/odom` and `/clock` go through one `ros_gz_bridge` `parameter_bridge` node. The direction of each is fixed by the bridge argument: `[` is Gazebo to ROS, `]` is ROS to Gazebo.

## Command node

`regain_command_node` (`regain_simulation/command_node.py`) is the only publisher on `/regain/cmd_vel`.

- **Validation.** Any message that is not one of the five commands is rejected, the chair stops, and a warning is logged.
- **Timeout.** The node publishes every 50 ms. If no valid command arrived within `command_timeout` seconds, it publishes zero velocity. This covers a source that crashes or disconnects.
- **Speed limits.** Configured speeds are clamped to the hard caps, whatever the config file says. The Gazebo DiffDrive plugin has its own limits (1.0 m/s, 1.5 rad/s) as a further layer.
- **Confidence extension point.** `parse_message()` returns `(intention, confidence)`, with confidence fixed at 1.0 for now, and `is_valid()` is where a confidence threshold will go. Change those two methods, and the message type, when MATLAB starts sending confidence.

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

## Architecture

```
 source (CLI now, MATLAB later)
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

Approximate layout, in metres (the front door is on the west wall, and the chair spawns just inside it):

```
y=8  +--------------+------------------+
     |              |    BEDROOM       |
     |   LIVING     [door 6.0-7.0]     |
     |   ROOM       +------------------+  y=5
     |              [opening 2.7-3.9]  |
     |              |  KITCHEN/DINING  |
y=1.6+---[door]-----+-------[door]-----+
     |           HALLWAY               |
y=0  +--[front door at west, y 0.3-1.3]-+
    x=0           x=5               x=10
```

- Doors are 1.0 m wide and the kitchen opening is 1.2 m. The wheelchair is about 0.64 m wide.
- The floor of each room is a visual-only slab on the grass plane, so there are no steps at doorways.
- Furniture: sofa, coffee table, bookshelf and plant in the living room. Counter, sink, fridge, dining table and four chairs in the kitchen. Bed, bedside table and wardrobe in the bedroom.
- A green disc at (8.0, 5.6), beside the bed, marks a destination for later navigation work.
- There is no ceiling, so the interior is visible from above.

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
- **The timeout protects against the command source dying, not the command node dying.** If `regain_command_node` crashes while the chair is moving, the DiffDrive plugin keeps the last velocity. An output-side watchdog is needed in a later stage.
- **The timeout uses wall time**, so it keeps counting if the simulation is paused.
- **Confidence is a placeholder.** Only the extension point exists, and the real message format will be decided with the MATLAB interface.
- Odometry is published as a message only. There is no `odom -> base_link` TF transform yet, which Nav2 and RViz will need.
- The chair has no sensors yet. Obstacle detection will need a lidar or depth camera.

## Roadmap

- MATLAB BCI connection, including a confidence value
- Output-side watchdog and a stronger safety supervisor
- Obstacle sensing
- Navigation
- Rehabilitation visualization

## License

Apache-2.0