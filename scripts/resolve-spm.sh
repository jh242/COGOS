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

# SwiftAgent's Package.swift tracks MacPaw/OpenAI on branch: main. That
# branch renamed Includable / ToolChoicePayload (MacPaw #423), which
# SwiftAgent 48bfda92 still references. Keep the revision SwiftAgent
# itself resolved so OpenAIGenerationOptions compiles.
python3 - "$DEST/Package.resolved" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
pin = "a6e2f87cd13ba062110af9880a40313b7ba860fc"
data = json.loads(path.read_text())
found = False
for item in data["pins"]:
    if item.get("identity") == "openai":
        item.setdefault("state", {})["branch"] = "main"
        item["state"]["revision"] = pin
        found = True
        break
if not found:
    raise SystemExit("resolve-spm.sh: OpenAI pin missing from Package.resolved")
path.write_text(json.dumps(data, indent=2) + "\n")
print(f"Pinned OpenAI to {pin}")
PY

echo "Wrote $DEST/Package.resolved"
