# Copyright 2019 Red Hat
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import setuptools
import os

setuptools.setup(
    name="podenv",
    version="0.0.1",
    author="Tristan de Cacqueray",
    author_email="tdecacqu@redhat.com",
    description="A podman wrapper",
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    url="https://github.com/podenv/podenv",
    packages=["podenv"],
    install_requires=["PyYAML"],
    package_data={'podenv': [
        item[7:] for sub in map(lambda x: [x[0]] + list(map(
            lambda y: x[0] + '/' + y, x[2])), os.walk(
                'podenv/dhall'))
        for item in sub]},
    entry_points={
        'console_scripts': [
            'podenv=podenv.main:run',
        ],
    },
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: ASL 2.0 License",
        "Operating System :: Linux",
    ],
)
