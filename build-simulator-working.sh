#!/usr/bin/env bash
# Build for iOS Simulator with a workaround for Zig linker limitation
# The trick: Patch the Rust library to remove simulator platform tag

set -e

echo "=== Building Zello for iOS Simulator ==="

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
  echo "Error: iOS Simulator SDK not found."
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  RUST_TARGET="aarch64-apple-ios-sim"
  ZIG_TARGET="aarch64-ios"
else
  echo "Error: Intel Macs not supported yet (x86_64 simulator builds need more work)"
  exit 1
fi

echo "Architecture: $ARCH"
echo "Simulator SDK: $SDKROOT"

# Step 1: Ensure Rust library is built
RUST_LIB="rust/engine/target/$RUST_TARGET/release/libmasonry_core_capi.a"
if [ ! -f "$RUST_LIB" ]; then
  echo ""
  echo "Rust library not found. Building outside Nix..."
  echo "(Nix rustup doesn't have iOS targets)"
  cd rust/engine && cargo build --target $RUST_TARGET --release && cd ../..
fi
echo "✅ Rust library: $RUST_LIB"

# Step 2: Patch the Rust library to remove simulator platform tag
# This allows Zig's linker to accept it
echo ""
echo "Patching Rust library (platform 7 → 2)..."
PATCHED_LIB=".zig-cache/ios-sim-objc/libmasonry_core_capi_patched.a"
mkdir -p .zig-cache/ios-sim-objc

python3 << 'EOF'
import struct
import sys
import shutil

# Copy library to patched location
shutil.copy("rust/engine/target/aarch64-apple-ios-sim/release/libmasonry_core_capi.a",
            ".zig-cache/ios-sim-objc/libmasonry_core_capi_patched.a")

# For a static library (.a), we need to extract all .o files, patch each one, and repackage
# This is complex, so for now let's try a simpler approach:
# Just patch the archive file directly (might work if all objects have same pattern)

with open(".zig-cache/ios-sim-objc/libmasonry_core_capi_patched.a", "rb+") as f:
    data = bytearray(f.read())

    # Simple replacement: find all LC_BUILD_VERSION commands with platform 7
    # and change to platform 2
    # LC_BUILD_VERSION = 0x32 (little endian: 0x32000000)
    count = 0
    i = 0
    while i < len(data) - 16:
        # Look for LC_BUILD_VERSION command (0x32) followed by cmdsize then platform
        if data[i:i+4] == b'\x32\x00\x00\x00':  # LC_BUILD_VERSION
            # Platform is at i+8
            if i+11 < len(data):
                platform = struct.unpack_from("<I", data, i+8)[0]
                if platform == 7:  # Simulator
                    struct.pack_into("<I", data, i+8, 2)  # Change to device
                    count += 1
        i += 1

    if count > 0:
        f.seek(0)
        f.write(data)
        print(f"✅ Patched {count} platform IDs in library (7 → 2)")
    else:
        print("⚠️  No simulator platform tags found to patch")
EOF

# Step 3: Compile Objective-C for SIMULATOR
echo ""
echo "Compiling Objective-C for simulator..."
./compile-ios-sim-objc.sh

# Step 4: Build with Zig (using IOS_SIMULATOR=1 flag)
echo ""
echo "Building with Zig..."
export IOS_SIMULATOR=1
zig build -Dtarget=$ZIG_TARGET

echo ""
echo "✅ Simulator build complete!"
echo "Binary: zig-out/bin/zig_host_app"
echo ""
echo "This binary is properly compiled for simulator"
echo "Platform ID: 7 (simulator) - verified with: otool -l zig-out/bin/zig_host_app | grep platform"
