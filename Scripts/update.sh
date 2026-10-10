#!/bin/bash
# Pulls the latest main from GitHub, then rebuilds and reinstalls via install.sh and
# relaunches the app. This is what the menu's "Update from GitHub" item runs; it also works
# from a terminal. It does not rebuild whisper.cpp — if the Vendor/whisper.cpp submodule
# moves, run Scripts/setup.sh by hand first.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== $(date) ==="
git pull --ff-only origin main
./Scripts/install.sh
open /Applications/WhisperKeyboard.app
