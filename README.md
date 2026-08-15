# whisper-keyboard

Local, offline dictation for macOS. Hold a hotkey, speak (English or Arabic), release —
the transcribed text is inserted at your cursor. Runs OpenAI's Whisper (`large-v3-turbo`)
entirely on-device via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Metal
acceleration — no cloud API, no subscription.

## Architecture

- `Packages/TranscriptionKit` — Swift facade over whisper.cpp (`WhisperEngine`) and model
  download/verification (`ModelManager`). Platform-agnostic; this is what a future iOS
  shell would reuse unchanged.
- `Packages/AudioCaptureKit` — microphone capture via `AVAudioEngine`, resampled to the
  16kHz mono Float32 format Whisper expects.
- `Packages/InputInjectionKit` — macOS-only. Inserts text via the Accessibility API, with
  a clipboard-paste fallback for apps with weak AX trees (browsers, Electron, Terminal).
- `App/` — the menu bar shell: status item, hotkey wiring, settings, first-run onboarding.
- `Vendor/whisper.cpp` — git submodule, pinned to a tagged release. Built into
  `whisper.xcframework` via whisper.cpp's own `build-xcframework.sh` (the officially
  supported Apple-platform integration path — it handles Metal shader embedding, which is
  a known pain point when hand-vendoring ggml's C sources into a custom SPM target).

## First-time setup

1. Install full **Xcode** from the App Store (Command Line Tools alone lack the Metal
   shader compiler `whisper.cpp` needs). Then:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
   Open Xcode once to accept the license and install additional components.
2. Run:
   ```
   ./Scripts/setup.sh
   ```
   This installs XcodeGen (if needed), fetches the whisper.cpp submodule, builds
   `whisper.xcframework` with Metal support, and generates `WhisperKeyboard.xcodeproj`.
3. Open `WhisperKeyboard.xcodeproj` in Xcode, press **Cmd+R**. First launch walks you
   through downloading the model and granting Microphone + Accessibility permissions.

Default hotkey is **⌃⌥Space** (hold to talk) — changeable from the menu bar icon's
"Change Hotkey…" item.

## Model verification

`ModelManager` pins an expected SHA-256 for each model file and refuses to use a download
that doesn't match. **The placeholder hashes in
`Packages/TranscriptionKit/Sources/TranscriptionKit/Types.swift` must be replaced** with
the real digests from https://huggingface.co/ggerganov/whisper.cpp before first use —
`Scripts/fetch-model.sh` prints the actual hash of what it downloads if you need to
re-verify.

## Development

- `Packages/TranscriptionKit` and `Packages/AudioCaptureKit` are plain SPM packages —
  iterate on them directly with `swift build` / `swift test` without Xcode's signing
  flow. `swift test` in `TranscriptionKit` needs a downloaded model first:
  `Scripts/fetch-model.sh`.
- `Scripts/reset-tcc.sh` clears a stale Accessibility grant (common during development,
  since rebuilding from Xcode can churn the code signature TCC keys off of).
- Adding new source files: re-run `xcodegen generate` (or `./Scripts/setup.sh` again) —
  `WhisperKeyboard.xcodeproj` is generated from `project.yml` and is not committed to git.

## Known limitations (v1)

- Hotkey is a conventional modifier+key combo (default ⌃⌥Space), not a Fn-hold or
  double-tap gesture — `KeyboardShortcuts`'s underlying `RegisterEventHotKey` API doesn't
  support standalone-modifier gestures. A Fn-hold trigger would need a separate
  `CGEventTap`-based implementation.
- Not sandboxed, so not App Store-distributable — required for the Accessibility API this
  app depends on for text insertion. Fine for personal use; share via Developer ID +
  notarization if ever needed.
- Batch transcription only (whisper.cpp runs once per utterance on hotkey release), not
  streaming. Fine for hold-to-talk lengths; would need revisiting for very long holds.
- iOS is not implemented — `TranscriptionKit`/`AudioCaptureKit` are written to be reusable
  by a future iOS target; `InputInjectionKit` is macOS-only by nature and would need an
  iOS-appropriate replacement (or removal, if text is just returned to the host app).
