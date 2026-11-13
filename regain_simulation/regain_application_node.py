"""ReGain application node (Stage 7).

Consumes /regain/eeg_intent (JSON in std_msgs/String), runs the destination
state machine, and publishes the resulting state on /regain/app_state.
It never publishes /cmd_vel and never moves the wheelchair.
"""
import json

import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import (QoSProfile, ReliabilityPolicy, DurabilityPolicy,
                       HistoryPolicy)
from std_msgs.msg import String

from regain_simulation.state_machine import (ApplicationStateMachine,
                                             parse_intent, NO_ACTION_INTENTS)


class RegainApplicationNode(Node):
    def __init__(self):
        super().__init__('regain_application_node')
        self.sm = ApplicationStateMachine()
        self.counts = dict(received=0, malformed=0, no_action=0, suppressed=0,
                           acted=0, destination_changes=0, confirmations=0)

        # Input: same QoS as the MATLAB publisher (reliable, depth 10).
        self.create_subscription(String, '/regain/eeg_intent', self.on_intent, 10)

        # Output: transient_local, so a subscriber that starts late still gets
        # the last state.
        state_qos = QoSProfile(reliability=ReliabilityPolicy.RELIABLE,
                               durability=DurabilityPolicy.TRANSIENT_LOCAL,
                               history=HistoryPolicy.KEEP_LAST, depth=1)
        self.state_pub = self.create_publisher(String, '/regain/app_state', state_qos)

        self.say('Application node started. State: IDLE | Destination: '
                 f'{self.sm.destination}')
        self.publish_state('start', [])

    def say(self, text):
        self.get_logger().info(f'[ReGain] {text}')

    def on_intent(self, msg):
        self.counts['received'] += 1
        intent, reason = parse_intent(msg.data)
        if intent is None:                       # never crash, never act
            self.counts['malformed'] += 1
            self.get_logger().warning(f'[ReGain] Ignored message: {reason}')
            return

        events = self.sm.step(intent)
        if intent in NO_ACTION_INTENTS:
            self.counts['no_action'] += 1        # REST / NO_DECISION: silent
            return
        if not events:
            self.counts['suppressed'] += 1       # actionable but latched: silent
            return

        self.counts['acted'] += 1
        self.say(f'State: {self.sm.state} | Intent: {intent}')
        for e in events:
            self.say(e)
            if e.startswith('Selected destination'):
                self.counts['destination_changes'] += 1
            if e.startswith('Destination confirmed'):
                self.counts['confirmations'] += 1
        self.publish_state(intent, events)

    def publish_state(self, intent, events):
        out = String()
        out.data = json.dumps({
            'state': self.sm.state,
            'destination': self.sm.destination,
            'confirmed_destination': self.sm.confirmed_destination,
            'last_intent': intent,
            'events': events,
        })
        self.state_pub.publish(out)

    def log_summary(self):
        self.say('Summary: ' + ', '.join(f'{k}={v}' for k, v in self.counts.items()))


def main(args=None):
    rclpy.init(args=args)
    node = RegainApplicationNode()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.log_summary()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()