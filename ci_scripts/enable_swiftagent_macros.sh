#!/bin/sh
# Unconditionally skip Swift macro / package-plugin fingerprint validation.
# Same effect as `xcodebuild -skipMacroValidation` (Cloud Archive has no
# extra-args field). Do not put that flag in OTHER_SWIFT_FLAGS — swiftc
# rejects it, and ComputeTargetDependencyGraph runs before swiftc.
set -eu

echo "COGOS: skipMacroValidation=YES"

skip() {
  defaults write "$1" IDESkipMacroFingerprintValidation -bool YES
  defaults write "$1" IDESkipPackagePluginFingerprintValidatation -bool YES
  defaults write "$1" IDESkipPackagePluginFingerprintValidation -bool YES
  defaults write "$1" IDESkipPackageSignatureValidation -bool YES
}

skip com.apple.dt.Xcode
skip -g
skip com.apple.dt.XCBuild
skip com.apple.dt.SWBBuildService
defaults write -currentHost com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES 2>/dev/null || true

if [ -n "${HOME:-}" ]; then
  plist="${HOME}/Library/Preferences/com.apple.dt.Xcode"
  skip "${plist}" 2>/dev/null || true
fi

killall -u "$(whoami)" cfprefsd 2>/dev/null || true
killall SWBBuildService 2>/dev/null || true
killall com.apple.dt.SWBBuildService 2>/dev/null || true
killall XCBBuildService 2>/dev/null || true

echo "COGOS: IDESkipMacroFingerprintValidation=$(defaults read com.apple.dt.Xcode IDESkipMacroFingerprintValidation 2>/dev/null || echo missing)"
