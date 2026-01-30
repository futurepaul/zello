#!/usr/bin/env bash
# Compile iOS Objective-C specifically for SIMULATOR

set -e

# Ensure we're using system Xcode
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Get iOS Simulator SDK path
SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
  echo "Error: iOS Simulator SDK not found."
  exit 1
fi

echo "Using iOS Simulator SDK: $SDKROOT"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  CLANG_TARGET="arm64-apple-ios16.0-simulator"
else
  CLANG_TARGET="x86_64-apple-ios16.0-simulator"
fi
echo "Target: $CLANG_TARGET"

# Output directory
mkdir -p .zig-cache/ios-sim-objc/modules

# Use Xcode's clang directly (not Nix wrapper)
XCODE_CLANG="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

$XCODE_CLANG \
  -target $CLANG_TARGET \
  -isysroot "$SDKROOT" \
  -iframework "$SDKROOT/System/Library/Frameworks" \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path=.zig-cache/ios-sim-objc/modules \
  -c src/platform/objc/metal_view_ios.m \
  -o .zig-cache/ios-sim-objc/metal_view_ios.o

echo "✅ Compiled metal_view_ios.o for SIMULATOR"
