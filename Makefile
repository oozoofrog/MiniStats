.PHONY: help doctor verify debug test-python
.DEFAULT_GOAL := help

help:
	@printf '%s\n' 'make doctor       Check local macOS build tools and inputs' 'make verify       Release build, existing tests, bundle checks; save log' 'make debug        Debug build, existing tests, bundle checks; save log' 'make test-python  Cleaner regression tests in temporary directories'

doctor:
	@./scripts/doctor.sh

verify:
	@./scripts/verify.sh

debug:
	@./scripts/verify.sh --debug

test-python:
	@/usr/bin/python3 tests/test_deriveddata.py
