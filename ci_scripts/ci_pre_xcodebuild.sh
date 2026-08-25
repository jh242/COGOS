#!/bin/sh
# Re-apply immediately before xcodebuild; Xcode 16 sometimes ignores the
# post-clone defaults write for Archive.
set -euo pipefail

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
