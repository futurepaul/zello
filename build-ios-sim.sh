#!/usr/bin/env bash
# Build script for iOS Simulator - run within nix develop --impure
# Usage: nix develop --impure --command ./build-ios-sim.sh

set -e

echo "=== Building Zello for iOS Simulator ==="

# Ensure we're using system Xcode for iOS SDK
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
  echo "Error: iOS Simulator SDK not found. Make sure Xcode is installed."
  exit 1
fi
echo "Using iOS Simulator SDK: $SDKROOT"

# Detect architecture (M1+ = arm64, Intel = x86_64)
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  RUST_TARGET="aarch64-apple-ios-sim"
  ZIG_TARGET="aarch64-ios"
  CLANG_TARGET="arm64-apple-ios16.0-simulator"
else
  RUST_TARGET="x86_64-apple-ios"
  ZIG_TARGET="x86_64-ios"
  CLANG_TARGET="x86_64-apple-ios16.0-simulator"
fi
echo "Building for: $ARCH ($RUST_TARGET)"

# Set environment variable to tell build.zig this is simulator
export IOS_SIMULATOR=1

# Step 1: Compile Objective-C with clang
echo ""
echo "Step 1: Compiling Objective-C platform code with clang..."
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

echo "✅ Compiled metal_view_ios.o for simulator"

# Step 2: Build Rust library for iOS simulator (if not already built)
echo ""
if [ ! -f "rust/engine/target/$RUST_TARGET/release/libmasonry_core_capi.a" ]; then
  echo "Step 2: Rust library not found for simulator"
  echo "Please build it first (outside Nix):"
  echo "  rustup target add $RUST_TARGET"
  echo "  cd rust/engine && cargo build --target $RUST_TARGET --release"
  exit 1
else
  echo "Step 2: Rust library already built ✓"
fi

# Step 3: Update build.zig to use simulator object file
echo ""
echo "Step 3: Building Zig app for iOS Simulator..."

# Temporarily copy simulator object to where build.zig expects it
mkdir -p .zig-cache/ios-objc
cp .zig-cache/ios-sim-objc/metal_view_ios.o .zig-cache/ios-objc/metal_view_ios.o

# Update Rust lib path temporarily
RUST_LIB="rust/engine/target/$RUST_TARGET/release/libmasonry_core_capi.a"
if [ ! -f "$RUST_LIB" ]; then
  echo "Error: Rust library not found at $RUST_LIB"
  exit 1
fi

# Build with Zig
# Note: Zig doesn't have a simulator target, so we just use ios target
# The object file is already compiled for simulator
zig build -Dtarget=${ZIG_TARGET}

echo ""
echo "✅ iOS Simulator build complete!"
echo "Binary: zig-out/bin/zig_host_app"
