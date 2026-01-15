# Running Zello in iOS Simulator

## Current Status

iOS Simulator support is **partially working** with a known limitation: Zig's linker doesn't recognize the `ios-simulator` platform tag in Rust-compiled libraries.

## Workaround: Use Device Build in Simulator

For M1+ Macs, the device ARM64 build actually works in the ARM64 simulator since they're the same architecture:

### Quick Start (M1+ Macs):

```bash
# 1. Build for iOS device (already done if you ran build-ios.sh)
nix develop --impure --command ./build-ios.sh

# 2. Package and run
./run-ios-sim.sh
```

The `run-ios-sim.sh` script will:
- Create an `.app` bundle from the device binary
- Boot the iOS Simulator if needed
- Install and launch the app

### Manual Steps:

```bash
# 1. Create app bundle
mkdir -p zig-out/bin/Zello.app
cp zig-out/bin/zig_host_app zig-out/bin/Zello.app/zig_host_app
cp ios/Info.plist zig-out/bin/Zello.app/Info.plist
chmod +x zig-out/bin/Zello.app/zig_host_app

# 2. Get a simulator ID
xcrun simctl list devices available | grep iPhone

# 3. Boot simulator (if not running)
xcrun simctl boot <SIMULATOR_ID>
open -a Simulator

# 4. Install app
xcrun simctl install <SIMULATOR_ID> zig-out/bin/Zello.app

# 5. Launch app
xcrun simctl launch --console <SIMULATOR_ID> com.zello.app
```

## Known Limitations

### Zig Linker + Rust Simulator Libraries

When trying to link Rust libraries compiled for `aarch64-apple-ios-sim`, Zig's linker reports:
```
error: invalid platform: aarch64-ios-simulator
```

This is because:
1. Rust properly marks simulator binaries with the `ios-simulator` platform
2. Zig 0.15.1's linker doesn't recognize this platform variant
3. Zig only knows about `ios` (device) platform

### Potential Solutions

**Option 1: Wait for Zig Update**
- Zig's linker may add simulator platform support in future versions
- Track: https://github.com/ziglang/zig/issues

**Option 2: Use lld Directly**
- Bypass Zig's linker entirely
- Use LLVM's `lld` linker which understands iOS simulator
- More complex build setup

**Option 3: Cross-Compile Hack**
- Tell Rust to compile for device (`aarch64-apple-ios`)
- Link with simulator SDK
- May have runtime issues

**Option 4: Device Build Works on Simulator** (Current Approach)
- M1+ Macs run ARM64 iOS Simulator
- Device ARM64 binary works in ARM64 simulator
- Only limitation: Can't test on Intel Macs (would need x86_64)

## The Platform ID Patch Workaround

Since Zig's linker doesn't support simulator platform, we can patch the device binary:

```bash
# After building for device
./run-sim-manual.sh  # Creates app bundle
./patch-for-simulator.sh  # Patches platform ID: 2 → 7

# Then install and run
export SIM=<SIMULATOR_ID>
xcrun simctl install $SIM zig-out/bin/Zello.app
xcrun simctl launch --console $SIM com.zello.app
```

The `patch-for-simulator.sh` script:
- Changes LC_BUILD_VERSION platform from 2 (device) to 7 (simulator)
- Re-signs the binary
- Creates a backup (zig_host_app.backup)

This works because M1+ simulators are ARM64, same as devices.

## For Intel Macs

Intel Macs need `x86_64-apple-ios` simulator target, which has the same Zig linker issue.

**Workaround**: Test on M1+ Mac or physical device

## Testing

Once running in simulator:

```bash
# View logs
xcrun simctl spawn booted log stream --predicate 'processImagePath contains "zig_host_app"'

# Terminate app
xcrun simctl terminate booted com.zello.app

# Uninstall
xcrun simctl uninstall booted com.zello.app
```

## Future Work

When Zig adds iOS simulator platform support:
1. Update `build.zig` to detect simulator builds
2. Use proper `aarch64-apple-ios-sim` Rust target
3. Test on Intel Mac simulators with `x86_64-apple-ios`

For now, the device build on M1+ simulator works perfectly for UI testing!
