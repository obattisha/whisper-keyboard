#!/bin/bash
# One-line installer for people who just want the app:
#
#   curl -fsSL https://raw.githubusercontent.com/obattisha/whisper-keyboard/main/Scripts/get.sh | bash
#
# Downloads the latest release, puts it in /Applications, and opens it. Fetched with curl
# rather than a browser, the app never gets macOS's quarantine flag, so it opens the first
# time without the "can't be opened" / Open Anyway detour. Rerunning it reinstalls the
# latest version; after the first install, the app updates itself.
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "whisper-keyboard needs an Apple Silicon Mac (M1 or newer)." >&2
    exit 1
fi

# The appcast attached to the latest release names that release's zip.
FEED="https://github.com/obattisha/whisper-keyboard/releases/latest/download/appcast.xml"
ZIP_URL=$(curl -fsSL "$FEED" | sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' | head -1)
if [[ -z "$ZIP_URL" ]]; then
    echo "Couldn't find the latest release. Download it by hand from" >&2
    echo "https://github.com/obattisha/whisper-keyboard/releases/latest" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $(basename "$ZIP_URL")..."
curl -fsSL "$ZIP_URL" -o "$TMP/WhisperKeyboard.zip"
ditto -x -k "$TMP/WhisperKeyboard.zip" "$TMP"

echo "Installing to /Applications..."
pkill -x WhisperKeyboard 2>/dev/null || true
rm -rf /Applications/WhisperKeyboard.app
ditto "$TMP/WhisperKeyboard.app" /Applications/WhisperKeyboard.app

open /Applications/WhisperKeyboard.app
echo "Done. whisper-keyboard is open: look for the mic icon in your menu bar."
