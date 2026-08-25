#!/bin/sh
# Xcode Cloud runs this after clone. SwiftAgent's SwiftAgentMacros plugin
# otherwise fails Archive with: must be enabled before it can be used.
set -euo pipefail

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
# Historical misspelling is the key Xcode actually reads for package plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
