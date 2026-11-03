#!/bin/bash
# Source inside packaging scripts only; no changes to the user's shell or .venv.
nest_environment_repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
UV_PYTHON=$(/usr/bin/python3 "$nest_environment_repo/scripts/bootstrap_runtime.py")
UV_PROJECT_ENVIRONMENT="$nest_environment_repo/.build/packaging-venv"
export UV_PYTHON UV_PROJECT_ENVIRONMENT
