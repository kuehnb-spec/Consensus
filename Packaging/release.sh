#!/bin/bash
# Builds everything a Consensus release ships, signed with Developer ID:
#   dist/Consensus-<version>.dmg                   the Mac app (drag to Applications)
#   dist/consensus-<version>-macos-arm64.tar.gz    CLI + engine installer
#
#   ./Packaging/release.sh
#
# Notarization runs when NOTARY_PROFILE names a stored notarytool profile
# (one-time setup, done by Brant because it needs his Apple ID password):
#   xcrun notarytool store-credentials consensus-notary \
#       --apple-id <apple id> --team-id WU3TPS59P8
#   NOTARY_PROFILE=consensus-notary ./Packaging/release.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_ID="${SIGN_ID:-Developer ID Application: BRANT DUNCAN KUEHN (WU3TPS59P8)}"
VERSION="$(grep -o 'appVersion = "[^"]*"' "$REPO_ROOT/TranscriboApp/Transcribo/CLI/ConsensusCLI.swift" | cut -d'"' -f2)"
DIST="$REPO_ROOT/dist"
APP="$REPO_ROOT/TranscriboApp/build/Consensus.app"
DMG="$DIST/Consensus-$VERSION.dmg"
TARBALL="$DIST/consensus-$VERSION-macos-arm64.tar.gz"
mkdir -p "$DIST"

echo "==> App $VERSION"
"$REPO_ROOT/TranscriboApp/build-app.sh" --release >/dev/null
# Sign the app as one unit: SwiftPM resource bundles are plain data sealed by
# the app's own signature, and must not be signed separately.
# Everything in Contents/MacOS counts as code, including the MLX kernel
# library colocated with the binary, so it gets its own signature first.
codesign --force --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/mlx.metallib"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Disk image"
STAGE_DMG="$DIST/stage-dmg"
rm -rf "$STAGE_DMG" "$DMG"
mkdir -p "$STAGE_DMG"
ditto "$APP" "$STAGE_DMG/Consensus.app"
ln -s /Applications "$STAGE_DMG/Applications"
hdiutil create -quiet -volname "Consensus $VERSION" -srcfolder "$STAGE_DMG" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
rm -rf "$STAGE_DMG"

echo "==> CLI $VERSION"
"$REPO_ROOT/Packaging/build-release.sh" "$VERSION" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing (Apple usually answers in a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  CLI_ZIP="$DIST/consensus-$VERSION-notarize.zip"
  ditto -c -k "$DIST/stage/consensus-$VERSION/consensus" "$CLI_ZIP"
  xcrun notarytool submit "$CLI_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$CLI_ZIP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "==> Skipping notarization (NOTARY_PROFILE not set): other Macs will warn on first open"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
ls -lh "$DMG" "$TARBALL"
