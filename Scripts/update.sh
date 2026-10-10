#!/bin/bash
# Pulls the latest main from GitHub, then rebuilds and reinstalls via install.sh and
# relaunches the app. This is what the menu's update item runs; it also works from a
# terminal. It does not rebuild whisper.cpp — if the Vendor/whisper.cpp submodule moves,
# run Scripts/setup.sh by hand first.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== $(date) ==="
git pull --ff-only origin main
./Scripts/install.sh

# install.sh kills the running copy, but LaunchServices takes a moment to notice it's gone;
# an `open` before then fails with -600 and nothing relaunches. Wait it out, then retry.
for _ in $(seq 1 20); do
    pgrep -x WhisperKeyboard >/dev/null || break
    sleep 0.25
done
for _ in 1 2 3 4 5; do
    open /Applications/WhisperKeyboard.app && exit 0
    sleep 1
done
exit 1
