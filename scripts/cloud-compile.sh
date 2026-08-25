#!/usr/bin/env bash
# Install Swift + XcodeGen if needed, generate the Xcode project, then compile.
# On macOS this is `xcodebuild`. On Linux (cloud agents) it compiles the
# IMAP/SwiftMail sources through SwiftPM — the iOS app itself needs Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${HOME}/.swiftly/bin:${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/bin:${PATH}"
if [[ -f "${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/env.sh" ]]; then
  # shellcheck disable=SC1091
  . "${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/env.sh"
fi

ensure_linux_swift_deps() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    return
  fi
  if ldconfig -p 2>/dev/null | grep -q 'libncurses.so.6' \
    && command -v g++ >/dev/null 2>&1; then
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Missing libncurses / g++ and apt-get is not available." >&2
    return 1
  fi
  echo "Installing Swift toolchain apt packages…"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gnupg2 libcurl4-openssl-dev libpython3-dev libxml2-dev \
    libncurses-dev libz3-dev g++ build-essential pkg-config
}

ensure_swift() {
  ensure_linux_swift_deps
  if command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; then
    swift --version
    return
  fi
  echo "Installing Swift via Swiftly…"
  local tmp
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    curl -fsSL -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
    tar zxf "swiftly-$(uname -m).tar.gz"
    ./swiftly init --assume-yes --quiet-shell-followup
  )
  rm -rf "$tmp"
  # shellcheck disable=SC1091
  . "${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/env.sh"
  hash -r
  swift --version
}

ensure_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen --version
    return
  fi
  echo "Building XcodeGen…"
  local src="${HOME}/.cache/XcodeGen"
  mkdir -p "$(dirname "$src")"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch 2.46.0 https://github.com/yonaskolb/XcodeGen.git "$src"
  fi
  (
    cd "$src"
    swift build -c release --product xcodegen
  )
  mkdir -p "${HOME}/.local/bin"
  cp "$src/.build/release/xcodegen" "${HOME}/.local/bin/xcodegen"
  xcodegen --version
}

ensure_swift
ensure_xcodegen

echo "Generating COGOS.xcodeproj…"
(
  cd "$ROOT"
  xcodegen generate
)

if command -v xcodebuild >/dev/null 2>&1; then
  echo "Compiling iOS app with xcodebuild…"
  (
    cd "$ROOT"
    xcodebuild -scheme COGOS -destination 'generic/platform=iOS' -quiet build
  )
else
  echo "xcodebuild not available; compiling IMAP + SwiftMail with SwiftPM…"
  (
    mkdir -p "$ROOT/scripts/linux-compile/Sources/IMAPCore"
    cp "$ROOT/COGOS/API/IMAPClient.swift" \
       "$ROOT/COGOS/API/IMAPCredentials.swift" \
       "$ROOT/COGOS/API/IMAPSearchQuery.swift" \
       "$ROOT/scripts/linux-compile/Sources/IMAPCore/"
    cd "$ROOT/scripts/linux-compile"
    extra_cc=()
    if [[ -d /usr/include/c++/13 ]]; then
      extra_cc+=(-Xcc -I/usr/include/c++/13)
    fi
    if [[ -d /usr/include/x86_64-linux-gnu/c++/13 ]]; then
      extra_cc+=(-Xcc -I/usr/include/x86_64-linux-gnu/c++/13)
    fi
    swift build -c release "${extra_cc[@]}"
  )
fi

echo "Compile finished."
