#!/bin/sh
# Trust SwiftAgentMacros for headless Xcode Cloud Archive.
# CWD is ci_scripts when Cloud runs the named hooks; this also works from repo root.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
MACROS_JSON="${SCRIPT_DIR}/macros.json"

echo "COGOS: trusting SwiftAgentMacros (repo=${REPO_ROOT})"

skip_validation() {
  domain="$1"
  defaults write "$domain" IDESkipMacroFingerprintValidation -bool YES || true
  # Historical misspelling is the key some Xcode versions read for plugins.
  defaults write "$domain" IDESkipPackagePluginFingerprintValidatation -bool YES || true
  defaults write "$domain" IDESkipPackagePluginFingerprintValidation -bool YES || true
}

skip_validation com.apple.dt.Xcode
skip_validation com.apple.dt.XCBuild
skip_validation NSGlobalDomain

install_macros_json() {
  dir="$1"
  mkdir -p "$dir"
  cp "$MACROS_JSON" "$dir/macros.json"
  echo "COGOS: installed $dir/macros.json"
}

install_macros_json "${HOME}/Library/org.swift.swiftpm/security"
install_macros_json "${HOME}/.swiftpm/security"

# Best-effort PATH shim. Cloud often calls xcodebuild by absolute path, so this
# may no-op; macros.json is the trust-store fix either way.
real_xcodebuild="$(xcrun -f xcodebuild 2>/dev/null || true)"
if [ -n "$real_xcodebuild" ]; then
  for shim_dir in /usr/local/bin "${HOME}/bin"; do
    if mkdir -p "$shim_dir" 2>/dev/null && [ -w "$shim_dir" ]; then
      cat > "${shim_dir}/xcodebuild" <<EOF
#!/bin/sh
exec "${real_xcodebuild}" -skipMacroValidation -skipPackagePluginValidation "\$@"
EOF
      chmod +x "${shim_dir}/xcodebuild"
      echo "COGOS: wrote xcodebuild shim to ${shim_dir}/xcodebuild"
    fi
  done
fi

# Cloud's Archive xcodebuild ignores the defaults key; -skipMacroValidation is
# the flag that actually plans macro targets. Resolve once after clone so the
# trust store is populated before Archive. Skip on the pre-xcodebuild hook.
if [ "${1:-}" = "--resolve" ] && command -v xcodebuild >/dev/null 2>&1; then
  project="${CI_PRIMARY_REPOSITORY_PATH:-$REPO_ROOT}/COGOS.xcodeproj"
  if [ -f "$project/project.pbxproj" ]; then
    echo "COGOS: xcodebuild -resolvePackageDependencies -skipMacroValidation"
    xcodebuild -resolvePackageDependencies \
      -project "$project" \
      -scheme COGOS \
      -skipMacroValidation \
      -skipPackagePluginValidation \
      || echo "COGOS: package resolve with skipMacroValidation returned $?"
  fi
fi
