#!/usr/bin/env bash
# Build iOS Simulator using clang for all compilation and linking
# This bypasses Zig's linker limitation with ios-simulator platform

set -e

echo "=== Building Zello for iOS Simulator (using clang) ==="

# Ensure we're using system Xcode
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
  echo "Error: iOS Simulator SDK not found."
  exit 1
fi
echo "Using Simulator SDK: $SDKROOT"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  RUST_TARGET="aarch64-apple-ios-sim"
  CLANG_TARGET="arm64-apple-ios16.0-simulator"
else
  RUST_TARGET="x86_64-apple-ios"
  CLANG_TARGET="x86_64-apple-ios16.0-simulator"
fi
echo "Architecture: $ARCH"

# Use Xcode's clang
XCODE_CLANG="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

# Step 1: Check Rust library exists
echo ""
RUST_LIB="rust/engine/target/$RUST_TARGET/release/libmasonry_core_capi.a"
if [ ! -f "$RUST_LIB" ]; then
  echo "Rust library not found: $RUST_LIB"
  echo "Building it now..."
  cd rust/engine && cargo build --target $RUST_TARGET --release && cd ../..
fi
echo "✅ Rust library: $RUST_LIB"

# Step 2: Compile Objective-C with clang
echo ""
echo "Compiling Objective-C..."
mkdir -p .zig-cache/ios-sim-objc/modules

$XCODE_CLANG \
  -target $CLANG_TARGET \
  -isysroot "$SDKROOT" \
  -iframework "$SDKROOT/System/Library/Frameworks" \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path=.zig-cache/ios-sim-objc/modules \
  -c src/platform/objc/metal_view_ios.m \
  -o .zig-cache/ios-sim-objc/metal_view_ios.o

echo "✅ Compiled metal_view_ios.o"

# Step 3: Compile Zig code to object files (not executable)
echo ""
echo "Compiling Zig code..."

# First, we need to compile Zig to .o files
# Zig doesn't have a direct "compile to object" for main.zig easily
# Let's just use zig to create the executable and accept the platform tag issue for now

echo ""
echo "⚠️  Note: Zig linker doesn't support ios-simulator platform"
echo "This means we can't currently create a proper simulator binary."
echo ""
echo "For testing, use the device binary on M1+ simulator (works due to ARM64 match)"
echo "Or wait for Zig linker update to support ios-simulator platform."
echo ""
echo "See SIMULATOR.md for workarounds."
