#!/bin/bash
# Prints how many commits origin/main is ahead of the installed app. The app's update check
# runs this; it also works from a terminal. The installed commit is recorded by install.sh;
# before that file exists, the checkout's HEAD stands in for it.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALLED_FILE="$HOME/Library/Application Support/WhisperKeyboard/installed-commit"
installed=$(cat "$INSTALLED_FILE" 2>/dev/null || git rev-parse HEAD)

# BatchMode so a background check never hangs on an SSH passphrase or host-key prompt.
GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git fetch -q origin main
git rev-list --count "$installed..origin/main"
