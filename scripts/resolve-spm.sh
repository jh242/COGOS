#!/usr/bin/env bash
# Resolve SwiftAgent + SwiftMail (and transitives) into the Xcode workspace
# Package.resolved that Xcode Cloud requires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/COGOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
export PATH="${HOME}/.local/bin:${HOME}/.swiftly/bin:${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/bin:${PATH}"
if [[ -f "${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/env.sh" ]]; then
  # shellcheck disable=SC1091
  . "${SWIFTLY_HOME_DIR:-${HOME}/.local/share/swiftly}/env.sh"
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required to resolve packages." >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/Sources/COGOSResolved"
cat > "$tmp/Sources/COGOSResolved/Empty.swift" <<'EOF'
// Placeholder so SwiftPM has a target to attach package products to.
EOF
cat > "$tmp/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "COGOSResolved",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftedMind/SwiftAgent", revision: "48bfda9219a5014c117aff3294e7987e17218a9d"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail", exact: "1.11.0"),
    ],
    targets: [
        .target(
            name: "COGOSResolved",
            dependencies: [
                .product(name: "OpenAISession", package: "SwiftAgent"),
                .product(name: "SwiftMail", package: "SwiftMail"),
            ]
        ),
    ]
)
EOF

(
  cd "$tmp"
  swift package resolve
)

mkdir -p "$DEST"
cp "$tmp/Package.resolved" "$DEST/Package.resolved"
echo "Wrote $DEST/Package.resolved"
