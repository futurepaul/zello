#!/usr/bin/env bash
# Package and run Zello in iOS Simulator
# Usage: ./run-ios-sim.sh

set -e

APP_NAME="Zello"
BUNDLE_ID="com.zello.app"
APP_BUNDLE="zig-out/bin/${APP_NAME}.app"

echo "=== Packaging ${APP_NAME} for iOS Simulator ==="

# Step 1: Build for simulator (if binary doesn't exist)
if [ ! -f "zig-out/bin/zig_host_app" ]; then
  echo "Binary not found. Building for simulator..."
  nix develop --impure --command ./build-ios-sim.sh
fi

# Step 2: Create app bundle structure
echo ""
echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"

# Copy binary
cp zig-out/bin/zig_host_app "$APP_BUNDLE/zig_host_app"
chmod +x "$APP_BUNDLE/zig_host_app"

# Copy Info.plist
cp ios/Info.plist "$APP_BUNDLE/Info.plist"

echo "✅ App bundle created: $APP_BUNDLE"

# Step 3: Boot simulator if not running
echo ""
echo "Checking iOS Simulator..."
SIMULATOR_ID=$(xcrun simctl list devices available 2>/dev/null | grep "iPhone" | grep "Booted" | head -1 | grep -Eo "[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}")

if [ -z "$SIMULATOR_ID" ]; then
  echo "No simulator running. Booting default iPhone simulator..."
  # Get first available iPhone simulator
  SIMULATOR_ID=$(xcrun simctl list devices available 2>/dev/null | grep "iPhone" | head -1 | grep -Eo "[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}")

  if [ -z "$SIMULATOR_ID" ]; then
    echo "Error: No iPhone simulators found"
    echo "Create one in Xcode (Xcode -> Window -> Devices and Simulators)"
    exit 1
  fi

  echo "Booting simulator: $SIMULATOR_ID"
  xcrun simctl boot "$SIMULATOR_ID"
  # Wait for boot
  echo "Waiting for simulator to boot..."
  sleep 3
  # Open Simulator app
  open -a Simulator
  sleep 2
fi

echo "Using simulator: $SIMULATOR_ID"

# Step 4: Install app
echo ""
echo "Installing app to simulator..."
xcrun simctl install "$SIMULATOR_ID" "$APP_BUNDLE"

# Step 5: Launch app
echo ""
echo "Launching ${APP_NAME}..."
xcrun simctl launch --console "$SIMULATOR_ID" "$BUNDLE_ID"

echo ""
echo "✅ ${APP_NAME} is running in iOS Simulator!"
echo ""
echo "To view logs:"
echo "  xcrun simctl spawn $SIMULATOR_ID log stream --predicate 'processImagePath contains \"zig_host_app\"'"
echo ""
echo "To terminate:"
echo "  xcrun simctl terminate $SIMULATOR_ID $BUNDLE_ID"
