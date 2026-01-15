#!/usr/bin/env bash
# Patch iOS device binary to run in simulator
# This changes the LC_BUILD_VERSION platform from 2 (device) to 7 (simulator)

set -e

BINARY="zig-out/bin/Zello.app/zig_host_app"

if [ ! -f "$BINARY" ]; then
  echo "Error: Binary not found at $BINARY"
  echo "Run ./run-sim-manual.sh first to create the app bundle"
  exit 1
fi

echo "Patching $BINARY for simulator..."

# Make backup
cp "$BINARY" "$BINARY.backup"

# Find LC_BUILD_VERSION command and change platform from 2 to 7
# Platform is at offset +8 from LC_BUILD_VERSION (after cmd and cmdsize)
# We'll use Python for this since it's reliable for binary patching

python3 << 'EOF'
import struct

binary_path = "zig-out/bin/Zello.app/zig_host_app"

with open(binary_path, "rb") as f:
    data = bytearray(f.read())

# Mach-O magic (0xfeedfacf for 64-bit)
magic = struct.unpack_from("<I", data, 0)[0]
if magic != 0xfeedfacf:
    print(f"Error: Not a 64-bit Mach-O file (magic: {hex(magic)})")
    exit(1)

# Read number of load commands
ncmds = struct.unpack_from("<I", data, 16)[0]

# LC_BUILD_VERSION = 0x32
LC_BUILD_VERSION = 0x32

offset = 32  # Start of load commands (after mach_header_64)
found = False

for i in range(ncmds):
    cmd = struct.unpack_from("<I", data, offset)[0]
    cmdsize = struct.unpack_from("<I", data, offset + 4)[0]

    if cmd == LC_BUILD_VERSION:
        platform_offset = offset + 8
        platform = struct.unpack_from("<I", data, platform_offset)[0]
        print(f"Found LC_BUILD_VERSION at offset {hex(offset)}")
        print(f"  Current platform: {platform} (2=iOS device)")

        if platform == 2:
            # Change to platform 7 (iOS simulator)
            struct.pack_into("<I", data, platform_offset, 7)
            print(f"  Patched to: 7 (iOS simulator)")
            found = True
        else:
            print(f"  Platform already set to {platform}")

        break

    offset += cmdsize

if not found:
    print("Warning: LC_BUILD_VERSION with platform=2 not found")
    exit(1)

# Write patched binary
with open(binary_path, "wb") as f:
    f.write(data)

print("✅ Binary patched successfully!")
EOF

# Re-sign after patching
codesign -s - --force --deep zig-out/bin/Zello.app

echo "✅ Ready for simulator!"
echo ""
echo "To restore original:"
echo "  mv $BINARY.backup $BINARY"
