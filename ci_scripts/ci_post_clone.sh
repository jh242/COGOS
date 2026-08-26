#!/bin/sh
# Xcode Cloud has no Trust & Enable dialog. Skip macro validation on this VM
# before package graph construction.
# https://stackoverflow.com/questions/77267883
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
echo "COGOS ci_post_clone: skipMacroValidation"
/bin/sh "${SCRIPT_DIR}/enable_swiftagent_macros.sh"
