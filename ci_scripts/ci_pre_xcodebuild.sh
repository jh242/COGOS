#!/bin/sh
# Repeat immediately before xcodebuild. Xcode 16.2+ Cloud often ignores the
# post-clone defaults write unless it is applied again here.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
COGOS_KILL_BUILD_SERVICE=1
export COGOS_KILL_BUILD_SERVICE
echo "COGOS ci_pre_xcodebuild: enable SwiftAgentMacros"
sh "${SCRIPT_DIR}/enable_swiftagent_macros.sh"
