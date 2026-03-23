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
APP_NAME="Consensus"
SWIFT_BINARY_NAME="Consensus"
BUNDLE_EXECUTABLE="Consensus"
BUNDLE_ID="com.bdk.consensus"

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
# --------------------------------------------------------------------------
echo ""
echo "[2/4] Compiling Metal shaders..."

MLX_CHECKOUT="$SCRIPT_DIR/.build/checkouts/mlx-swift"
MLX_METAL_DIR="$MLX_CHECKOUT/Source/Cmlx/mlx-generated/metal"
AIR_DIR="$BUILD_DIR/metallib-build"
mkdir -p "$AIR_DIR"

METAL_FLAGS="-Wall -Wextra -fno-fast-math -Wno-c++17-extensions"

# Determine Metal version include path (use 3_1 for macOS 14+, 3_0 for older)
METAL_VERSION_DIR="$MLX_METAL_DIR/metal_3_1"
if [ ! -d "$METAL_VERSION_DIR" ]; then
    METAL_VERSION_DIR="$MLX_METAL_DIR/metal_3_0"
fi

# Collect all .metal files
METAL_FILES=()
for f in "$MLX_METAL_DIR"/*.metal; do
    [ -f "$f" ] && METAL_FILES+=("$f")
done
# Include subdirectory .metal files (steel attention, etc.)
while IFS= read -r -d '' f; do
    METAL_FILES+=("$f")
done < <(find "$MLX_METAL_DIR" -mindepth 2 -name "*.metal" -print0 2>/dev/null)

AIR_FILES=()
COMPILE_FAILED=false

for metal_file in "${METAL_FILES[@]}"; do
    base=$(basename "$metal_file" .metal)
    air_file="$AIR_DIR/${base}.air"

    if xcrun -sdk macosx metal $METAL_FLAGS \
        -c "$metal_file" \
        -I"$MLX_METAL_DIR" \
        -I"$METAL_VERSION_DIR" \
        -o "$air_file" 2>&1; then
        AIR_FILES+=("$air_file")
        echo "  Compiled: $base.metal"
    else
        echo "  FAILED:   $base.metal"
        COMPILE_FAILED=true
    fi
done

if [ ${#AIR_FILES[@]} -eq 0 ]; then
    echo "Error: No Metal shaders compiled successfully"
    exit 1
fi

if $COMPILE_FAILED; then
    echo "Warning: Some Metal shaders failed to compile (continuing with available ones)"
fi

# Link all .air files into mlx.metallib
METALLIB_PATH="$AIR_DIR/mlx.metallib"
echo ""
echo "  Linking ${#AIR_FILES[@]} shaders into mlx.metallib..."
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$METALLIB_PATH" 2>&1
echo "  Created: $METALLIB_PATH ($(du -h "$METALLIB_PATH" | cut -f1))"

# --------------------------------------------------------------------------
# Step 3: Assemble the .app bundle
# --------------------------------------------------------------------------
echo ""
echo "[3/4] Assembling app bundle..."

APP_DIR="$SCRIPT_DIR/build/Consensus.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Clean previous build
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/$BUNDLE_EXECUTABLE"

# Place mlx.metallib next to binary (search path #1 in device.cpp)
cp "$METALLIB_PATH" "$MACOS_DIR/mlx.metallib"

# Also place in Resources/ (search path #2 in device.cpp: "Resources/mlx")
cp "$METALLIB_PATH" "$RESOURCES_DIR/mlx.metallib"

# Copy any SPM resource bundles that exist alongside the built binary
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        bundle_name=$(basename "$bundle")
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
    <string>Consensus</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Consensus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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
