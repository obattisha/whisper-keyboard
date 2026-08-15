#!/bin/bash
# Standalone CLI equivalent of TranscriptionKit's ModelManager, for dev/testing without
# going through the app's onboarding UI (e.g. before running `swift test`).
set -euo pipefail

VARIANT="${1:-large-v3-turbo}"
FILENAME="ggml-${VARIANT}.bin"
DEST_DIR="$HOME/Library/Application Support/WhisperKeyboard/Models"
DEST="$DEST_DIR/$FILENAME"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$FILENAME"

if [[ -f "$DEST" ]]; then
    echo "Already present: $DEST"
    exit 0
fi

mkdir -p "$DEST_DIR"
echo "Downloading $FILENAME (this is a large file, may take a while)..."
curl -L --fail --progress-bar -o "$DEST.download" "$URL"
mv "$DEST.download" "$DEST"
echo "Saved to $DEST"
echo
echo "NOTE: verify the SHA-256 against the digest listed on"
echo "https://huggingface.co/ggerganov/whisper.cpp before trusting this file, and update"
echo "the pinned hash in TranscriptionKit/Sources/TranscriptionKit/Types.swift if it changed."
shasum -a 256 "$DEST"
