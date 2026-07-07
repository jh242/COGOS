#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# COGOS is an iOS-only app, so remote Linux sessions cannot run xcodebuild.
# This hook installs what CAN run on Linux so sessions are still able to:
#   - typecheck Swift sources (swiftc -typecheck / -parse)
#   - run platform-independent XCTest subsets via throwaway SwiftPM packages
#   - regenerate COGOS.xcodeproj from project.yml (xcodegen generate)
#
# First run downloads ~800 MB and builds XcodeGen (~10 min); the container
# state is cached afterwards, so subsequent sessions hit the fast path.
set -euo pipefail

# Local (macOS) sessions have Xcode; only remote containers need this.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SWIFT_HOME=/opt/swift
SWIFT_URL="https://download.swift.org/swift-6.1-release/ubuntu2404/swift-6.1-RELEASE/swift-6.1-RELEASE-ubuntu24.04.tar.gz"
XCODEGEN_VERSION=2.45.4

CURL_ARGS=(-sSL --retry 3)
# Outbound HTTPS goes through the agent proxy; use its CA bundle when present.
if [ -f /root/.ccr/ca-bundle.crt ]; then
  CURL_ARGS+=(--cacert /root/.ccr/ca-bundle.crt)
fi

if [ ! -x "$SWIFT_HOME/usr/bin/swift" ]; then
  echo "Installing Swift 6.1 toolchain to $SWIFT_HOME ..."
  tmp=$(mktemp -d)
  curl "${CURL_ARGS[@]}" -o "$tmp/swift.tar.gz" "$SWIFT_URL"
  mkdir -p "$SWIFT_HOME"
  tar xzf "$tmp/swift.tar.gz" -C "$SWIFT_HOME" --strip-components=1
  rm -rf "$tmp"
fi

export PATH="$SWIFT_HOME/usr/bin:$PATH"

if [ ! -x /usr/local/bin/xcodegen ] || [ ! -d /usr/local/share/xcodegen/SettingPresets ]; then
  echo "Building XcodeGen $XCODEGEN_VERSION from source ..."
  tmp=$(mktemp -d)
  git clone --depth 1 --branch "$XCODEGEN_VERSION" \
    https://github.com/yonaskolb/XcodeGen.git "$tmp/XcodeGen"
  (cd "$tmp/XcodeGen" && swift build -c release)
  install -m 755 "$tmp/XcodeGen/.build/release/xcodegen" /usr/local/bin/xcodegen
  # Without its SettingPresets the binary emits 'No "iOS" settings found' and
  # generates a project missing all platform build settings. Mirror the
  # layout XcodeGen's own `make install` uses: PREFIX/share/xcodegen.
  mkdir -p /usr/local/share/xcodegen
  rm -rf /usr/local/share/xcodegen/SettingPresets
  cp -R "$tmp/XcodeGen/SettingPresets" /usr/local/share/xcodegen/SettingPresets
  rm -rf "$tmp"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$SWIFT_HOME/usr/bin:\$PATH\""
    # xcodegen aborts with "Couldn't find current username" if USER is unset.
    echo 'export USER="${USER:-claude}"'
  } >> "$CLAUDE_ENV_FILE"
fi

swift --version
USER="${USER:-claude}" xcodegen --version
echo "Session setup complete."
