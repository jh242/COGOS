#!/bin/sh
# Xcode Cloud has no "Trust & Enable" dialog. Enable SwiftAgentMacros on this
# fresh VM before package graph construction.
# https://stackoverflow.com/questions/77267883
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
COGOS_KILL_BUILD_SERVICE=1
export COGOS_KILL_BUILD_SERVICE
echo "COGOS ci_post_clone: enable SwiftAgentMacros"
sh "${SCRIPT_DIR}/enable_swiftagent_macros.sh"
