.PHONY: help doctor verify debug run test-python
.DEFAULT_GOAL := help

help:
	@printf '%s\n' 'make doctor       Check local macOS build tools and inputs' 'make verify       Release build, existing tests, bundle checks; save log' 'make debug        Debug build, existing tests, bundle checks; save log' 'make run          Stop any running app, build, then launch build/MiniStats.app' 'make test-python  Cleaner regression tests in temporary directories'

doctor:
	@./scripts/doctor.sh

verify:
	@./scripts/verify.sh

debug:
	@./scripts/verify.sh --debug

run:
	@./scripts/run.sh

test-python:
	@/usr/bin/python3 tests/test_deriveddata.py
