#!/usr/bin/env bash
# Build script for iOS - run within nix develop --impure
# Usage: nix develop --impure --command ./build-ios.sh

set -e

echo "=== Building Zello for iOS ==="

# Ensure we're using system Xcode for iOS SDK
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
  echo "Error: iOS SDK not found. Make sure Xcode is installed."
  exit 1
fi
echo "Using iOS SDK: $SDKROOT"

# Step 1: Compile Objective-C with clang (bypasses Zig's C compiler)
echo ""
echo "Step 1: Compiling Objective-C platform code with clang..."
./compile-ios-objc.sh

# Step 2: Build Rust library for iOS (if not already built)
echo ""
if [ ! -f "rust/engine/target/aarch64-apple-ios/release/libmasonry_core_capi.a" ]; then
  echo "Step 2: Building Rust library for iOS (aarch64-apple-ios)..."
  echo "NOTE: iOS Rust target must be built outside Nix first"
  echo "Run: rustup target add aarch64-apple-ios && cargo build --target aarch64-apple-ios --release"
  exit 1
else
  echo "Step 2: Rust library already built ✓"
fi

# Step 3: Build Zig app for iOS (links pre-compiled Objective-C)
echo ""
echo "Step 3: Building Zig app for iOS..."
zig build -Dtarget=aarch64-ios

echo ""
echo "✅ iOS build complete!"
echo "Binary: zig-out/bin/zig_host_app"
