#!/bin/sh
# Trust SwiftAgentMacros for this machine. Xcode stores that approval in
# UserDefaults + ~/Library/org.swift.swiftpm/security/macros.json — never in
# the app target's SWIFT_UPCOMING_FEATURE / OTHER_SWIFT_FLAGS. Graph
# construction (ComputeTargetDependencyGraph) reads those stores before any
# COGOS compile flags apply.
#
# Equivalent of `xcodebuild -skipMacroValidation`, which Cloud's Archive
# action has no field for. Called from ci_post_clone, ci_pre_xcodebuild, and
# the shared COGOS scheme Archive/Build pre-actions.
set -eu

echo "COGOS: enabling SwiftAgentMacros for Archive"

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
# Historical misspelling is the key some Xcode versions actually read.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
defaults write -currentHost com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES 2>/dev/null || true

if [ -n "${HOME:-}" ]; then
  defaults write "${HOME}/Library/Preferences/com.apple.dt.Xcode" \
    IDESkipMacroFingerprintValidation -bool YES 2>/dev/null || true
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
MACROS_JSON="${SCRIPT_DIR}/macros.json"
for dest in \
  "${HOME}/Library/org.swift.swiftpm/security" \
  "${HOME}/.swiftpm/security"
do
  mkdir -p "${dest}"
  cp "${MACROS_JSON}" "${dest}/macros.json"
done

killall -u "$(whoami)" cfprefsd 2>/dev/null || true
# Restart the build service only before xcodebuild starts. Scheme pre-actions
# run inside an already-launched xcodebuild — skip the kill there.
if [ "${COGOS_KILL_BUILD_SERVICE:-}" = "1" ]; then
  killall SWBBuildService 2>/dev/null || true
  killall com.apple.dt.SWBBuildService 2>/dev/null || true
fi

echo "COGOS: IDESkipMacroFingerprintValidation=$(defaults read com.apple.dt.Xcode IDESkipMacroFingerprintValidation 2>/dev/null || echo missing)"
echo "COGOS: copied ${MACROS_JSON} into SwiftPM security stores"
