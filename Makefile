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

all: test dhall doc

dhall: dhall-lint dhall-freeze

dhall-lint:
	find . -name "*.dhall" -exec dhall --ascii format --inplace {} \;

dhall-freeze:
	dhall freeze --inplace podenv/dhall/package.dhall --all

test: test-type test-unit test-lint

test-type:
	mypy --strict podenv

test-unit:
	@(PYTHONPATH=. python3 -m unittest -v tests/*.py)

test-lint:
	flake8

# Generate README.md content manually... to be replaced by sphinx autoclass?
doc:
	@(PYTHONPATH=. python3 docs/generate.py)
