import os 

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription, TimerAction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import Node

def generate_launch_description():
    pkg_ros_gz_sim = get_package_share_directory('ros_gz_sim')
    pkg_regain = get_package_share_directory('regain_simulation')

    world_path  = os.path.join(pkg_regain , 'worlds' , 'regain_house.sdf')
    wheelchair_path = os.path.join(pkg_regain , 'models' , 'regain_wheelchair' , 'model.sdf')
    config_path  = os.path.join(pkg_regain , 'config' , 'command_node.yaml')


    gz_sim = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(pkg_ros_gz_sim , 'launch' , 'gz_sim.launch.py')
        ), 
        launch_arguments={
            'gz_args': f'-r {world_path}', 
            'on_exot_shutdown': 'true',

        }.items(),
    )

    spawn_wheelchair = TimerAction(
        period=3.0 ,
        actions=[
            Node(
                package='ros_gz_sim',
                executable='create',
                arguments=[
                    '-world', 'regain_world',
                    '-name' , 'regain_wheelchair',
                    '-file', wheelchair_path,
                    '-x', '1.0' , '-y' , '0.8' , '-z' , '0.05', '-Y', '0.0',
                ], #-Y is the yaw
                output ='screen',
            )
        ],
    )

    bridge = Node(
        package='ros_gz_bridge',
        executable ='parameter_bridge',
        arguments = [
            '/clock@rosgraph_msgs/msg/Clock[gz.msgs.Clock]',
            '/regain/cmd_vel@geometry_msgs/msg/Twist]gz.msgs.Twist',
            '/regain/odom@nav_msgs/msg/Odometry[gz.msgs.Odometry', 
        ],
        output = 'screen',
    )

    command_node = Node(
        package= 'regain_simulation',
        executable='command_node',
        name='regain_command_node',
        parameters=[config_path],
        output = 'screen'
    )

    return LaunchDescription([
        gz_sim,
        spawn_wheelchair,
        bridge,
        command_node,
        ])