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
# -a: pkill skips its own ancestors by default, and when the menu's update item runs this
# via update.sh, the app is an ancestor, so without it the old copy kept running.
pkill -a -x WhisperKeyboard 2>/dev/null || true
rm -rf /Applications/WhisperKeyboard.app
cp -R "$BUILT_PRODUCTS_DIR/WhisperKeyboard.app" /Applications/

# What the "Check for Updates" menu item compares origin/main against. Kept outside the app
# bundle because writing into it after signing would break the signature (and with it the
# app's Accessibility/Microphone grants).
mkdir -p "$HOME/Library/Application Support/WhisperKeyboard"
git rev-parse HEAD > "$HOME/Library/Application Support/WhisperKeyboard/installed-commit"

echo
echo "Installed. Launch it from Spotlight/Launchpad/Finder, or run:"
echo "  open /Applications/WhisperKeyboard.app"
