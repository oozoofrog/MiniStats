.PHONY: help doctor verify debug run install test-python

DIR ?= $(HOME)/Applications

.DEFAULT_GOAL := help

help:
	@printf '%s\n' \
		'make doctor                    Check local macOS build tools and inputs' \
		'make verify                    Release build, existing tests, bundle checks; save log' \
		'make debug                     Debug build, existing tests, bundle checks; save log' \
		'make run                       Build, install to ~/Applications, then launch' \
		'make run DIR=/Applications     Build, install to /Applications, then launch' \
		'make install                   Build then install to ~/Applications' \
		'make install DIR=/Applications Build then install to /Applications' \
		'make test-python               Cleaner regression tests in temporary directories'

doctor:
	@./scripts/doctor.sh

verify:
	@./scripts/verify.sh

debug:
	@./scripts/verify.sh --debug

run:
	@DIR="$(DIR)" ./scripts/run.sh

install:
	@./scripts/install.sh "$(DIR)"

test-python:
	@/usr/bin/python3 tests/test_deriveddata.py
