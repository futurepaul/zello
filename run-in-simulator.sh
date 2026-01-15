#!/usr/bin/env bash
# One-command script to run Zello in iOS Simulator
# Usage: ./run-in-simulator.sh

set -e

echo "=== Running Zello in iOS Simulator ==="

# Step 1: Ensure device binary exists
if [ ! -f "zig-out/bin/zig_host_app" ]; then
  echo "Device binary not found. Please build first:"
  echo "  nix develop --impure --command ./build-ios.sh"
  exit 1
fi

# Step 2: Create app bundle
echo ""
echo "Creating app bundle..."
./run-sim-manual.sh > /dev/null 2>&1

# Step 3: Patch for simulator
echo "Patching binary for simulator platform..."
./patch-for-simulator.sh

# Step 4: Get simulator
echo ""
echo "Finding simulator..."
SIMULATOR_ID=$(xcrun simctl list devices available | grep "iPhone" | head -1 | grep -Eo "[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}")

if [ -z "$SIMULATOR_ID" ]; then
  echo "Error: No iPhone simulators found"
  exit 1
fi

SIMULATOR_NAME=$(xcrun simctl list devices available | grep "$SIMULATOR_ID" | sed 's/ (.*//')
echo "Using: $SIMULATOR_NAME"

# Step 5: Boot simulator
echo ""
STATUS=$(xcrun simctl list devices | grep "$SIMULATOR_ID" | grep -o "([^)]*)" | tail -1 | tr -d '()')
if [ "$STATUS" != "Booted" ]; then
  echo "Booting simulator..."
  xcrun simctl boot "$SIMULATOR_ID"
  open -a Simulator
  sleep 3
else
  echo "Simulator already booted"
fi

# Step 6: Install app
echo ""
echo "Installing Zello..."
xcrun simctl install "$SIMULATOR_ID" zig-out/bin/Zello.app

# Step 7: Launch app
echo ""
echo "Launching Zello..."
echo ""
xcrun simctl launch --console "$SIMULATOR_ID" com.zello.app
