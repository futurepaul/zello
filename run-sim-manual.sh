#!/usr/bin/env bash
# Manual steps to run in iOS Simulator
# Run this if run-ios-sim.sh has issues

set -e

APP_NAME="Zello"
BUNDLE_ID="com.zello.app"
APP_BUNDLE="zig-out/bin/${APP_NAME}.app"

echo "=== Manual iOS Simulator Setup ==="
echo ""

# Create app bundle
echo "1. Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"
cp zig-out/bin/zig_host_app "$APP_BUNDLE/zig_host_app"
chmod +x "$APP_BUNDLE/zig_host_app"
cp ios/Info.plist "$APP_BUNDLE/Info.plist"
echo "   ✅ Created: $APP_BUNDLE"
echo ""

# Get simulator ID
echo "2. Available simulators:"
xcrun simctl list devices available | grep "iPhone" | head -5
echo ""

# Instructions
echo "3. To run manually:"
echo ""
echo "   # Pick a simulator ID from above (the UUID)"
echo "   export SIM=<SIMULATOR_ID>"
echo ""
echo "   # Boot it"
echo "   xcrun simctl boot \$SIM"
echo "   open -a Simulator"
echo ""
echo "   # Install app"
echo "   xcrun simctl install \$SIM $APP_BUNDLE"
echo ""
echo "   # Launch app"
echo "   xcrun simctl launch --console \$SIM $BUNDLE_ID"
echo ""
echo "Example (using first iPhone):"
SIM_ID=$(xcrun simctl list devices available | grep "iPhone" | head -1 | grep -Eo "[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}")
echo ""
echo "   export SIM=$SIM_ID"
echo "   xcrun simctl boot \$SIM && open -a Simulator"
echo "   xcrun simctl install \$SIM $APP_BUNDLE"
echo "   xcrun simctl launch --console \$SIM $BUNDLE_ID"
