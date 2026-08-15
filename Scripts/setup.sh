#!/bin/bash
# First-time machine setup for whisper-keyboard.
# Requires full Xcode (not just Command Line Tools) — whisper.cpp's Metal backend needs
# the Metal shader compiler, which only ships with the full Xcode.app.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: full Xcode is required (not just Command Line Tools)." >&2
    echo "Install it from the App Store, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

# XcodeGen 2.43+ defaults to objectVersion 77 (Xcode 16+ project format). Xcode 15.4's
# command-line builder (xcodebuild) tolerates a project.pbxproj forced down to an older
# objectVersion via sed, but Xcode's GUI project editor does not — it crashes when
# opening a project whose declared objectVersion doesn't match its actual structure
# (needed for the Signing & Capabilities pane, among other things). XcodeGen 2.42.0
# predates that default change and emits a natively Xcode-15-compatible project, so pin
# to it explicitly rather than patching output from whatever XcodeGen Homebrew has.
XCODEGEN_VERSION="2.42.0"
XCODEGEN_DIR="$HOME/.cache/whisper-keyboard/xcodegen-${XCODEGEN_VERSION}"
XCODEGEN_BIN="$XCODEGEN_DIR/xcodegen/bin/xcodegen"
if [[ ! -x "$XCODEGEN_BIN" ]]; then
    echo "Fetching XcodeGen ${XCODEGEN_VERSION} (pinned for Xcode 15.4 project-format compatibility)..."
    mkdir -p "$XCODEGEN_DIR"
    curl -sL -o "$XCODEGEN_DIR/xcodegen.zip" \
        "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
    unzip -o -q "$XCODEGEN_DIR/xcodegen.zip" -d "$XCODEGEN_DIR"
fi

echo "Fetching whisper.cpp submodule..."
git submodule update --init --recursive

echo "Building whisper.xcframework (this compiles whisper.cpp with Metal support, takes a few minutes)..."
(cd Vendor/whisper.cpp && ./build-xcframework.sh)

echo "Generating WhisperKeyboard.xcodeproj..."
"$XCODEGEN_BIN" generate

echo
echo "Setup complete. Open WhisperKeyboard.xcodeproj in Xcode and press Cmd+R to build and run."
echo "First launch will walk you through downloading the model and granting permissions."
