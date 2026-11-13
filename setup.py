import os
from glob import glob

from setuptools import find_packages, setup

package_name = 'regain_simulation'

setup(
    name=package_name,
    version='0.0.1',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/regain_simulation']),
        ('share/regain_simulation', ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.launch.py')),
        (os.path.join('share' , package_name , 'worlds') , glob('worlds/*.sdf')),
        (os.path.join('share' , package_name , 'models', 'regain_wheelchair') , 
                                        glob('models/regain_wheelchair/*.sdf')),

        (os.path.join('share' , package_name , 'config') , glob('config/*.yaml'))
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='khalid.m2202295@st.futminna.edu.ng',
    maintainer_email='khalid.m2202295@st.futminna.edu.ng',
    description='ReGain: BCI-driven assistive wheelchair simulation in Gazebo Harmonic',
    license='Apache-2.0',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'command_node = regain_simulation.command_node:main',
            'regain_application_node = regain_simulation.regain_application_node:main',
        ],
    },
)