#!/usr/bin/env bash
# Compile iOS Objective-C files using clang (like xcodebuild does)
# This bypasses Zig's C compiler which has trouble with private iOS headers

set -e

# Ensure we're using system Xcode
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Get iOS SDK path
SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
  echo "Error: iOS SDK not found. Make sure Xcode is installed."
  exit 1
fi

echo "Using iOS SDK: $SDKROOT"

# Output directory
mkdir -p .zig-cache/ios-objc

# Compile the Objective-C file to an object file
# Use modules with proper cache to avoid header issues
mkdir -p .zig-cache/ios-objc/modules

# Use Xcode's clang directly (not Nix wrapper) to avoid conflicts
XCODE_CLANG="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

$XCODE_CLANG \
  -target arm64-apple-ios16.0 \
  -isysroot "$SDKROOT" \
  -iframework "$SDKROOT/System/Library/Frameworks" \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path=.zig-cache/ios-objc/modules \
  -c src/platform/objc/metal_view_ios.m \
  -o .zig-cache/ios-objc/metal_view_ios.o

echo "✅ Compiled metal_view_ios.o"
