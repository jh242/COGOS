#!/bin/sh
# Repeat immediately before xcodebuild so Archive sees the skip.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
echo "COGOS ci_pre_xcodebuild: skipMacroValidation"
/bin/sh "${SCRIPT_DIR}/enable_swiftagent_macros.sh"
