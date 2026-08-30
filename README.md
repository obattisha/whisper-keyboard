# whisper-keyboard

Local, offline dictation for macOS and iOS. On the Mac, hold a hotkey, speak (English or
Arabic), release — the transcribed text is inserted at your cursor. Runs OpenAI's Whisper
entirely on-device via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Metal
acceleration — no cloud API, no subscription. Defaults to the Q5-quantized `large-v3-turbo`
(574MB, multilingual, fastest to download and run); switch to the full `large-v3-turbo` or
the faster-but-English-only `distil-large-v3` from the menu bar's Model menu.

## Architecture

- `Packages/TranscriptionKit` — Swift facade over whisper.cpp (`WhisperEngine`) and model
  download/verification (`ModelManager`). Platform-agnostic, used unchanged by both the
  macOS and iOS targets.
- `Packages/AudioCaptureKit` — microphone capture via `AVAudioEngine`, resampled to the
  16kHz mono Float32 format Whisper expects. Shared by both targets; the iOS side adds a
  small `AVAudioSession` activation step macOS doesn't need.
- `Packages/InputInjectionKit` — macOS-only. Inserts text via the Accessibility API, with
  a clipboard-paste fallback for apps with weak AX trees (browsers, Electron, Terminal). No
  iOS equivalent exists (see "iOS companion app" below for how iOS delivers text instead).
- `App/` — the macOS menu bar shell: status item, hotkey wiring, settings, first-run
  onboarding.
- `iOSApp/` — the iOS companion app: a SwiftUI recording screen plus a `DictateIntent`
  (`AppIntents`) that's assignable to the Action Button or the Shortcuts app.
- `Vendor/whisper.cpp` — git submodule, pinned to a tagged release. Built into
  `whisper.xcframework` via whisper.cpp's own `build-xcframework.sh` (the officially
  supported Apple-platform integration path — it handles Metal shader embedding, which is
  a known pain point when hand-vendoring ggml's C sources into a custom SPM target). This
  produces macOS *and* iOS device/simulator slices in one pass — `Scripts/setup.sh`
  already builds everything both targets need.

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
3. Open `WhisperKeyboard.xcodeproj` in Xcode and press **Cmd+R** — build from the Xcode
   GUI the first time, not `xcodebuild` from the command line. The project has no
   `DEVELOPMENT_TEAM` hardcoded (that's account-specific, so a value that works on one Mac
   would just break the build on anyone else's); Xcode resolves it from whichever Apple ID
   is signed into **Xcode > Settings > Accounts**, prompting you to sign in and pick
   "Automatically manage signing" if you haven't already. A free personal team is enough —
   no paid Apple Developer Program membership needed. Once resolved this way, subsequent
   `Cmd+R`/`xcodebuild` builds keep using it — you only need the GUI step again if you
   re-run `xcodegen generate` (e.g. after adding new source files), which regenerates
   `WhisperKeyboard.xcodeproj` from scratch.
4. First launch walks you through downloading the model and granting Microphone +
   Accessibility permissions.

Default hotkey is **⌃⌥Space** (hold to talk) — changeable from the menu bar icon's
"Change Hotkey…" item.

Since you're building from source, macOS never quarantines the app the way it would a
downloaded binary — there's no Gatekeeper "unidentified developer" warning to click
through.

## Installing permanently

`Cmd+R` runs the app straight out of Xcode's DerivedData folder, which is fine for
iterating but not for daily use. Once the Xcode GUI build from step 3 above has succeeded
at least once (so your signing team is resolved), run:
```
./Scripts/install.sh
```
This builds a Release configuration and installs it to `/Applications/WhisperKeyboard.app`.
Launch it from Spotlight/Launchpad/Finder going forward, and grant Microphone/Accessibility
once when prompted — that grant persists across future `install.sh` reruns as long as the
same Apple ID/team keeps signing it.

## iOS companion app

iOS has no Accessibility API and custom keyboard extensions run under a memory ceiling
(~48MB) that a Whisper model can't fit in — so this isn't a system keyboard, and can't
insert text at the cursor in an arbitrary app the way the macOS version does. Instead it's
a standalone app you trigger via the **Action Button** (or the Shortcuts app on phones
without one): tap to open the app and start recording, tap again in-app to stop — the
transcript lands on your clipboard, ready to paste anywhere.

1. In `WhisperKeyboard.xcodeproj`, switch the scheme to **WhisperKeyboardMobile** and pick
   your iPhone (or a Simulator, though the Action Button and real microphone input only
   work on a physical device) as the destination, then **Cmd+R**. Same first-time signing
   note as the macOS target applies — Xcode resolves your team via a signed-in Apple ID.
2. First launch walks you through granting Microphone access and downloading the model
   (defaults to the smaller Q5-quantized variant — 574MB — since phone storage/RAM is more
   constrained than a Mac).
3. To assign it to the **Action Button**: open the Shortcuts app, create a new shortcut
   using the "Dictate" action (whisper-keyboard's `DictateIntent`), save it, then in
   **Settings > Action Button > Shortcut**, pick that shortcut.

This is a first pass, not feature parity with the macOS app: the Action Button only
fixed-trigger-fires third-party actions (no true continuous hold-to-record the way physical
hotkeys or Apple's own Camera/Voice Memo actions get), and delivery is clipboard-paste
rather than seamless cursor insertion.

## Model verification

`ModelManager` pins an expected SHA-256 for each model file (`Types.swift`) and refuses to
use a download that doesn't match — verified against the Git LFS OIDs from
https://huggingface.co/ggerganov/whisper.cpp. If whisper.cpp ever ships new model files
upstream, `Scripts/fetch-model.sh` prints the actual hash of what it downloads so you can
re-pin them.

## Development

- `Packages/TranscriptionKit` and `Packages/AudioCaptureKit` are plain SPM packages —
  iterate on them directly with `swift build` / `swift test` without Xcode's signing
  flow. `swift test` in `TranscriptionKit` needs a downloaded model first:
  `Scripts/fetch-model.sh`.
- `Scripts/reset-tcc.sh` clears a stale Accessibility grant (common during development,
  since rebuilding from Xcode can churn the code signature TCC keys off of).
- Adding new source files: re-run `xcodegen generate` (or `./Scripts/setup.sh` again) —
  `WhisperKeyboard.xcodeproj` is generated from `project.yml` and is not committed to git.
  This wipes the signing team Xcode resolved earlier, so open the regenerated project once
  in the Xcode GUI to re-pick it before your next `Cmd+R` or `install.sh`.

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
- iOS is a first pass, not feature parity — see "iOS companion app" above. Notably: no
  continuous hold-to-record (Action Button fixed-trigger-fires third-party actions once,
  not held-and-released), and clipboard-paste delivery instead of cursor insertion (no iOS
  equivalent of the Accessibility API `InputInjectionKit` uses on macOS).
- The iOS Simulator can't test the Action Button (no physical button) or real microphone
  input — those need a physical device.
