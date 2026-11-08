import rclpy
from geometry_msgs.msg import Twist
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from std_msgs.msg import String

# command -> (linear direction, angular direction); each is -1, 0 or +1
COMMANDS = {
    'FORWARD': (1.0, 0.0),
    'BACKWARD': (-1.0, 0.0),
    'LEFT': (0.0, 1.0),
    'RIGHT': (0.0, -1.0),
    'STOP': (0.0, 0.0),
}


class CommandNode(Node):
    """Turn high-level BCI commands into limited, time-bounded Twist output."""

    def __init__(self):
        super().__init__('regain_command_node')

        self.declare_parameter('linear_speed', 0.3)
        self.declare_parameter('angular_speed', 0.5)
        self.declare_parameter('max_linear_speed', 0.5)
        self.declare_parameter('max_angular_speed', 0.8)
        self.declare_parameter('command_timeout', 0.7)
        self.declare_parameter('publish_rate', 20.0)

        linear = self.get_parameter('linear_speed').value
        angular = self.get_parameter('angular_speed').value
        max_linear = self.get_parameter('max_linear_speed').value
        max_angular = self.get_parameter('max_angular_speed').value
        self.command_timeout = self.get_parameter('command_timeout').value
        publish_rate = self.get_parameter('publish_rate').value

        if self.command_timeout <= 0.0 or publish_rate <= 0.0:
            raise ValueError('command_timeout and publish_rate must be > 0')

        # Velocity limiting: whatever is configured, never exceed the caps.
        self.linear_speed = min(abs(linear), max_linear)
        self.angular_speed = min(abs(angular), max_angular)
        if self.linear_speed != abs(linear) or self.angular_speed != abs(angular):
            self.get_logger().warning('Configured speed above the cap, clamped.')

        self.active_command = 'STOP'
        self.last_command_time = None  # nothing received yet -> zero velocity

        self.cmd_pub = self.create_publisher(Twist, '/regain/cmd_vel', 10)
        self.create_subscription(
            String, '/regain/bci_command', self.command_callback, 10)
        self.create_timer(1.0 / publish_rate, self.publish_velocity)

        self.get_logger().info(
            f'Ready: {self.linear_speed} m/s, {self.angular_speed} rad/s, '
            f'timeout {self.command_timeout} s')

    # ---- extension point for the future MATLAB message ----------------
    def parse_message(self, msg):
        """Return (intention, confidence) from an incoming message.

        Today the message is a plain String, so confidence is fixed at 1.0.
        When MATLAB starts sending a confidence value, change only this
        method (and the message type in __init__).
        """
        return msg.data, 1.0

    def is_valid(self, intention, confidence):
        """Decide whether a command may move the chair."""
        if intention not in COMMANDS:
            return False
        # FUTURE: reject low-confidence intentions here, for example
        #   if confidence < self.min_confidence: return False
        return True
    # -------------------------------------------------------------------

    def command_callback(self, msg):
        intention, confidence = self.parse_message(msg)

        if not self.is_valid(intention, confidence):
            self.get_logger().warning(
                f'Invalid command {msg.data!r}: stopping. '
                f'Valid commands: {", ".join(COMMANDS)}')
            self.active_command = 'STOP'
        else:
            if intention != self.active_command:
                self.get_logger().info(f'Command: {intention}')
            self.active_command = intention

        self.last_command_time = self.get_clock().now()
        self.publish_velocity()

    def command_is_fresh(self):
        if self.last_command_time is None:
            return False
        age = (self.get_clock().now() - self.last_command_time).nanoseconds / 1e9
        return age <= self.command_timeout

    def publish_velocity(self):
        twist = Twist()  # all zeros by default

        if self.command_is_fresh():
            linear_dir, angular_dir = COMMANDS[self.active_command]
            twist.linear.x = linear_dir * self.linear_speed
            twist.angular.z = angular_dir * self.angular_speed
        elif self.active_command != 'STOP':
            self.get_logger().warning(
                f'No command for {self.command_timeout} s: stopping.')
            self.active_command = 'STOP'

        self.cmd_pub.publish(twist)


def main(args=None):
    rclpy.init(args=args)
    node = CommandNode()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()