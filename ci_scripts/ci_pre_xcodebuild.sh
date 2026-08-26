#!/bin/sh
# Xcode 16.2+ Cloud often ignores the post-clone defaults write unless it is
# repeated immediately before xcodebuild (same Stack Overflow thread).
set -eu

echo "COGOS ci_pre_xcodebuild: skip SwiftAgentMacros fingerprint validation"

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

killall -u "$(whoami)" cfprefsd 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
mkdir -p "${HOME}/Library/org.swift.swiftpm/security"
cp "${SCRIPT_DIR}/macros.json" "${HOME}/Library/org.swift.swiftpm/security/macros.json"

echo "COGOS ci_pre_xcodebuild: IDESkipMacroFingerprintValidation=$(defaults read com.apple.dt.Xcode IDESkipMacroFingerprintValidation)"
