#!/bin/sh
# Xcode Cloud has no "Trust & Enable" dialog. The usual fix is:
# https://stackoverflow.com/questions/77267883
# https://fline.dev/blog/solving-swift-macro-trust-issues-in-xcode-cloud-builds/
#
# Equivalent of `xcodebuild -skipMacroValidation`. Must run in this hook
# (same machine as Archive), not as OTHER_SWIFT_FLAGS.
set -eu

echo "COGOS ci_post_clone: skip SwiftAgentMacros fingerprint validation"

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
# Historical misspelling is the key some Xcode versions actually read.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

killall -u "$(whoami)" cfprefsd 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
mkdir -p "${HOME}/Library/org.swift.swiftpm/security"
cp "${SCRIPT_DIR}/macros.json" "${HOME}/Library/org.swift.swiftpm/security/macros.json"

echo "COGOS ci_post_clone: IDESkipMacroFingerprintValidation=$(defaults read com.apple.dt.Xcode IDESkipMacroFingerprintValidation)"
