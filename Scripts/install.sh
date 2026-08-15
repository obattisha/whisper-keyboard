#!/bin/bash
# Builds a Release configuration and installs it to /Applications, replacing any existing
# copy there. Run this after the first successful Cmd+R build in Xcode (that step is what
# resolves DEVELOPMENT_TEAM for your Apple ID — see README "First-time setup").
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building Release configuration..."
xcodebuild -project WhisperKeyboard.xcodeproj -scheme WhisperKeyboard \
    -configuration Release -destination 'platform=macOS,arch=arm64' build

BUILT_PRODUCTS_DIR=$(xcodebuild -project WhisperKeyboard.xcodeproj -scheme WhisperKeyboard \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')

echo "Installing to /Applications/WhisperKeyboard.app..."
pkill -x WhisperKeyboard 2>/dev/null || true
rm -rf /Applications/WhisperKeyboard.app
cp -R "$BUILT_PRODUCTS_DIR/WhisperKeyboard.app" /Applications/

echo
echo "Installed. Launch it from Spotlight/Launchpad/Finder, or run:"
echo "  open /Applications/WhisperKeyboard.app"
