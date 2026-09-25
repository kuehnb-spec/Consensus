#!/bin/bash
# Builds the distributable Consensus CLI tarball.
#   ./Packaging/build-release.sh [version]
# Produces dist/consensus-<version>-macos-arm64.tar.gz plus a .sha256.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(grep -o 'appVersion = "[^"]*"' "$REPO_ROOT/TranscriboApp/Transcribo/CLI/ConsensusCLI.swift" | cut -d'"' -f2)}"
SIGN_ID="${SIGN_ID:-Developer ID Application: BRANT DUNCAN KUEHN (WU3TPS59P8)}"
STAGE="$REPO_ROOT/dist/stage/consensus-$VERSION"
OUT="$REPO_ROOT/dist/consensus-$VERSION-macos-arm64.tar.gz"

echo "==> Building release binary"
cd "$REPO_ROOT/TranscriboApp"
swift build -c release --product consensus
# Xcode 27's SwiftPM writes to .build/out/Products/Release; ask rather than guess.
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Staging $STAGE"
rm -rf "$REPO_ROOT/dist/stage"
mkdir -p "$STAGE/VibeVoiceSidecar"
cp "$BIN_DIR/consensus" "$STAGE/consensus"
# Developer ID signature + hardened runtime, so Gatekeeper accepts it once notarized.
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$STAGE/consensus"
cp "$REPO_ROOT/TranscriboApp/Scripts/VibeVoiceSidecar/run.py" "$STAGE/VibeVoiceSidecar/run.py"
cp "$REPO_ROOT/Packaging/install.sh" "$STAGE/install.sh"
cp "$REPO_ROOT/Packaging/requirements.txt" "$STAGE/requirements.txt"
cp "$REPO_ROOT/Packaging/README-INSTALL.md" "$STAGE/README.md"
chmod +x "$STAGE/install.sh" "$STAGE/consensus"

# The payload is code only. Never sweep in TestAudio, transcripts, or configs:
# this repository holds real client recordings.
echo "==> Payload"
find "$STAGE" -type f | sed "s|$STAGE/||" | sort | sed 's/^/    /'

echo "==> Archiving"
mkdir -p "$REPO_ROOT/dist"
tar -czf "$OUT" -C "$REPO_ROOT/dist/stage" "consensus-$VERSION"
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $(du -h "$OUT" | cut -f1)  $OUT"
