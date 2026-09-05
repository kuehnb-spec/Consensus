#!/bin/bash
set -euo pipefail

# ============================================================================
# build-app.sh — Build Consensus as a macOS .app bundle with MLX metallib
#
# This script:
#   1. Builds the Swift executable via `swift build`
#   2. Compiles MLX Metal shaders into mlx.metallib using xcrun metal
#   3. Assembles a proper macOS .app bundle with the metallib included
#
# Prerequisites:
#   - Full Xcode installation (not just Command Line Tools)
#   - Metal Toolchain: run `xcodebuild -downloadComponent MetalToolchain` if needed
#   - Set DEVELOPER_DIR or run `sudo xcode-select -s /Applications/Xcode.app`
#
# Usage:
#   ./build-app.sh [--release] [--install]
#
#   --release   Build in release mode with optimizations
#   --install   Copy the .app to /Applications after building
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Consensus 1.1"
SWIFT_BINARY_NAME="Consensus"
BUNDLE_EXECUTABLE="Consensus"
BUNDLE_ID="com.bdk.consensus"
BUNDLE_SHORT_VERSION="1.1"
BUNDLE_VERSION="3"
ICON_SOURCE_DIR="$SCRIPT_DIR/Design/AppIcon"
LOGO_SOURCE_PATH="$SCRIPT_DIR/Design/Logo/consensus_logo_transparent.png"

# Parse arguments
BUILD_CONFIG="debug"
SWIFT_BUILD_FLAGS=""
INSTALL=false

for arg in "$@"; do
    case "$arg" in
        --release)
            BUILD_CONFIG="release"
            SWIFT_BUILD_FLAGS="-c release"
            ;;
        --install)
            INSTALL=true
            ;;
    esac
done

# Ensure Xcode (not just CLT) is available for Metal compilation
if ! xcrun --sdk macosx --find metal &>/dev/null; then
    echo "Error: Metal compiler not found."
    echo "Ensure full Xcode is installed and selected:"
    echo "  sudo xcode-select -s /Applications/Xcode.app"
    echo ""
    echo "If Metal Toolchain is missing, run:"
    echo "  xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

echo "=== Building $APP_NAME ($BUILD_CONFIG) ==="

# --------------------------------------------------------------------------
# Step 1: Build the Swift executable
# --------------------------------------------------------------------------
echo ""
echo "[1/4] Building Swift executable..."
cd "$SCRIPT_DIR"
swift build $SWIFT_BUILD_FLAGS 2>&1

BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/$BUILD_CONFIG"
BINARY="$BUILD_DIR/$SWIFT_BINARY_NAME"

if [ ! -f "$BINARY" ]; then
    echo "Error: Built binary not found at $BINARY"
    exit 1
fi
echo "  Binary: $BINARY"

# --------------------------------------------------------------------------
# Step 2: Compile Metal shaders into mlx.metallib
#
# Delegates to speech-swift's reference script, which compiles the full 32-file
# kernel set from `Source/Cmlx/mlx/mlx/backend/metal/kernels/`. Previously this
# script compiled its own subset (9 files) from `mlx-generated/metal/`,
# producing a 3.1 MB metallib that was missing kernels exercised at runtime.
# Slice 4 of the Word Timeline Rebuild (Apr 17, 2026) confirmed the
# discrepancy. See Brainstorming/WORD-TIMELINE-REBUILD-PLAN.md.
# --------------------------------------------------------------------------
echo ""
echo "[2/4] Compiling Metal shaders via speech-swift reference script..."

SPEECH_SWIFT_SCRIPT="$SCRIPT_DIR/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh"
if [ ! -x "$SPEECH_SWIFT_SCRIPT" ]; then
    echo "Error: speech-swift metallib script not found at $SPEECH_SWIFT_SCRIPT"
    echo "Run 'swift package resolve' first."
    exit 1
fi

METALLIB_PATH="$SCRIPT_DIR/.build/$BUILD_CONFIG/mlx.metallib"

# The Metal shaders only change when the MLX dependency changes, but the
# toolchain that compiles them can vanish across Xcode/macOS updates (the
# MetalToolchain component is a separate download). Rather than block the whole
# build on that, reuse a previously compiled metallib when the compiler is
# unavailable — the shaders in it are still valid.
# `xcrun --find metal` and `xcodebuild -showComponent` both succeed even when
# the toolchain can't actually run, so invoke the compiler to test it.
if xcrun -sdk macosx metal --version &>/dev/null; then
    BUILD_DIR="$SCRIPT_DIR/.build" "$SPEECH_SWIFT_SCRIPT" "$BUILD_CONFIG"
else
    echo "  Metal toolchain unavailable — looking for a previously built metallib."
    if [ ! -f "$METALLIB_PATH" ]; then
        for fallback in "$SCRIPT_DIR/build/$APP_NAME.app/Contents/Resources/mlx.metallib" \
                        "/Applications/$APP_NAME.app/Contents/Resources/mlx.metallib"; do
            if [ -f "$fallback" ]; then
                echo "  Reusing metallib from: $fallback"
                mkdir -p "$(dirname "$METALLIB_PATH")"
                cp "$fallback" "$METALLIB_PATH"
                break
            fi
        done
    fi
    if [ ! -f "$METALLIB_PATH" ]; then
        echo "Error: no Metal toolchain and no previously built mlx.metallib to reuse."
        echo "Install the toolchain with: xcodebuild -downloadComponent MetalToolchain"
        exit 1
    fi
fi

if [ ! -f "$METALLIB_PATH" ]; then
    echo "Error: mlx.metallib not found at $METALLIB_PATH"
    exit 1
fi
echo "  Metallib: $METALLIB_PATH ($(du -h "$METALLIB_PATH" | cut -f1))"

# --------------------------------------------------------------------------
# Step 3: Assemble the .app bundle
# --------------------------------------------------------------------------
echo ""
echo "[3/4] Assembling app bundle..."

APP_DIR="$SCRIPT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
APP_ICON_PATH="$RESOURCES_DIR/AppIcon.icns"
LOGO_DESTINATION_PATH="$RESOURCES_DIR/consensus_logo_transparent.png"

# Clean previous build
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/$BUNDLE_EXECUTABLE"

# Place mlx.metallib next to binary (search path #1 in device.cpp)
cp "$METALLIB_PATH" "$MACOS_DIR/mlx.metallib"

# Also place in Resources/ (search path #2 in device.cpp: "Resources/mlx")
cp "$METALLIB_PATH" "$RESOURCES_DIR/mlx.metallib"

# Build and copy the macOS app icon if source PNGs are available
if [ -d "$ICON_SOURCE_DIR" ]; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    cp "$ICON_SOURCE_DIR/icon_16x16.png" "$ICONSET_DIR/icon_16x16.png"
    cp "$ICON_SOURCE_DIR/icon_32x32.png" "$ICONSET_DIR/icon_16x16@2x.png"
    cp "$ICON_SOURCE_DIR/icon_32x32.png" "$ICONSET_DIR/icon_32x32.png"
    cp "$ICON_SOURCE_DIR/icon_64x64.png" "$ICONSET_DIR/icon_32x32@2x.png"
    cp "$ICON_SOURCE_DIR/icon_128x128.png" "$ICONSET_DIR/icon_128x128.png"
    cp "$ICON_SOURCE_DIR/icon_256x256.png" "$ICONSET_DIR/icon_128x128@2x.png"
    cp "$ICON_SOURCE_DIR/icon_256x256.png" "$ICONSET_DIR/icon_256x256.png"
    cp "$ICON_SOURCE_DIR/icon_512x512.png" "$ICONSET_DIR/icon_256x256@2x.png"
    cp "$ICON_SOURCE_DIR/icon_512x512.png" "$ICONSET_DIR/icon_512x512.png"
    cp "$ICON_SOURCE_DIR/icon_1024x1024.png" "$ICONSET_DIR/icon_512x512@2x.png"

    iconutil -c icns "$ICONSET_DIR" -o "$APP_ICON_PATH"
    echo "  Created app icon: $APP_ICON_PATH"
else
    echo "  Warning: Icon source directory not found at $ICON_SOURCE_DIR"
fi

# Copy the brand logo into the bundle for future in-app use
if [ -f "$LOGO_SOURCE_PATH" ]; then
    cp "$LOGO_SOURCE_PATH" "$LOGO_DESTINATION_PATH"
    echo "  Copied logo: $LOGO_DESTINATION_PATH"
else
    echo "  Warning: Logo source not found at $LOGO_SOURCE_PATH"
fi

# Copy the SPM resource bundles that belong to *this* build.
#
# `swift build` does not garbage-collect bundles from earlier builds, so a
# renamed target leaves its old bundle behind in .build. Shipping the stale one
# crashed the 1.1 app at launch: the binary wanted Consensus_ConsensusCore.bundle
# and only the pre-rename Consensus_Consensus.bundle was copied, so Bundle.module
# hit its fatalError before any window opened. Only ship bundles at least as new
# as the executable we just built.
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        bundle_name=$(basename "$bundle")
        # Orphan from before the target rename (Consensus -> ConsensusCore).
        # Shipping it alongside the real one is what crashed 1.1 at launch.
        if [ "$bundle_name" = "Consensus_Consensus.bundle" ]; then
            echo "  Skipping orphaned bundle: $bundle_name"
            continue
        fi
        echo "  Copying bundle: $bundle_name"
        cp -R "$bundle" "$RESOURCES_DIR/$bundle_name"
    fi
done

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Consensus</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.bdk.consensus</string>
    <key>CFBundleDisplayName</key>
    <string>__APP_NAME__</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>__APP_NAME__</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__BUNDLE_SHORT_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__BUNDLE_VERSION__</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Consensus needs microphone access for live transcription.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

sed -i '' \
    -e "s|__APP_NAME__|$APP_NAME|g" \
    -e "s|__BUNDLE_SHORT_VERSION__|$BUNDLE_SHORT_VERSION|g" \
    -e "s|__BUNDLE_VERSION__|$BUNDLE_VERSION|g" \
    "$CONTENTS_DIR/Info.plist"

echo "  App bundle: $APP_DIR"

# --------------------------------------------------------------------------
# Step 4: Optional install
# --------------------------------------------------------------------------
if $INSTALL; then
    echo ""
    echo "[4/4] Installing to /Applications..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
    echo "  Installed: /Applications/$APP_NAME.app"
else
    echo ""
    echo "[4/4] Skipping install (use --install to copy to /Applications)"
fi

echo ""
echo "=== Build complete ==="
echo ""
echo "App bundle contents:"
find "$APP_DIR" -not -path '*/\.*' | sed "s|$APP_DIR/||" | sort
echo ""
echo "To run: open '$APP_DIR'"
echo "To install: $0 --install"
