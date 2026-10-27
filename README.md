# whisper-keyboard

Hold down a key while you talk, and when you let go, what you said gets typed wherever your
cursor is. It understands English and Arabic. Everything runs on your Mac (OpenAI's Whisper
model, via [whisper.cpp](https://github.com/ggml-org/whisper.cpp)), so your audio never
leaves your computer and there's nothing to pay for.

You need a Mac with Apple Silicon (M1 or newer) on macOS 13.3 or later.

## Install

Open Terminal (Applications > Utilities > Terminal), paste this, and press Return:

```
curl -fsSL https://raw.githubusercontent.com/obattisha/whisper-keyboard/main/Scripts/get.sh | bash
```

It installs the latest version into your Applications folder and opens it. After that the
app updates itself.

<details>
<summary>Rather not use Terminal?</summary>

Download the zip from the [latest release](https://github.com/obattisha/whisper-keyboard/releases/latest)
and drag WhisperKeyboard into Applications. macOS blocks it the first time because the app
isn't notarized by Apple (that costs $99 a year). To get past it, find **Open Anyway** near
the bottom of **System Settings > Privacy & Security**. You only have to do this once. (The
Terminal command above skips this, since macOS only runs that check on apps downloaded
through a browser.)

</details>

## First launch

A setup window walks you through three things:

1. Downloading the speech model (574 MB, one time).
2. Allowing the microphone.
3. Allowing Accessibility, which is what lets it type into other apps. Click the
   button, then flip the switch next to WhisperKeyboard in the System Settings window that
   opens.

## Using it

Hold **Control + Option + Space** while you talk, then let go. The text shows up a second
or two later.

The **Fn (🌐) key** is easier to hold. To use it, choose **Change Hotkey…** from the mic icon
in the menu bar and turn on "Also hold Fn (🌐) to talk." Then in **System
Settings > Keyboard**, set "Press 🌐 key to" to **Do Nothing**, or macOS will also pop up
the emoji picker every time.

The mic icon in the menu bar also has:

- **Recent Transcriptions.** If text didn't land anywhere (say no text box was selected),
  it's still here; click one to copy it.
- **Language.** Auto-detect works, but picking English or Arabic is more accurate for short
  clips.
- **Model.** The default is the smallest download. `large-v3-turbo` (1.6 GB) is the most
  accurate, and `distil-large-v3` (1.5 GB) is faster but English only.
- **Check for Updates…** It also checks on its own every few hours.

## If something's off

- **Text never shows up:** check that WhisperKeyboard is switched on in **System Settings >
  Privacy & Security > Accessibility**. If it's on and still not working (this happens
  after reinstalling), switch it off and on again.
- **It types the wrong language:** pick your language from the Language menu instead of
  Auto-detect.

---

## For developers

### Building from source

1. Install **Xcode** from the App Store (the Command Line Tools alone are missing the Metal
   compiler whisper.cpp needs), then run
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and open Xcode once to
   accept the license.
2. Run `./Scripts/setup.sh`. It fetches the whisper.cpp submodule, builds
   `whisper.xcframework` with Metal, and generates `WhisperKeyboard.xcodeproj` with
   XcodeGen.
3. Open the project in Xcode and press **Cmd+R**. Do the first build from the Xcode window
   so it can pick a signing team from the Apple ID in **Xcode > Settings > Accounts** (a
   free personal team works). To make that survive regenerating the project, put
   `DEVELOPMENT_TEAM = <your team id>` in `Config/Local.xcconfig` (gitignored).
4. `./Scripts/install.sh` builds a Release copy into `/Applications`.

Keep the same signing team across builds. macOS ties the Microphone and Accessibility
permissions to the app's signature, and treats a build signed by a different team as a new
app.
`Scripts/reset-tcc.sh` clears a stale Accessibility grant.

### Releasing

```
./Scripts/release.sh 0.3.0
```

This builds a Release zip, signs it with the Sparkle key in the login keychain, and
publishes a GitHub Release with the zip and an `appcast.xml`. Installed copies read the
appcast from `releases/latest` (Sparkle), and `Scripts/get.sh` installs from the same
place, so publishing is all it takes. Back up the Sparkle key with `generate_keys -x <file>`
(in Sparkle's `bin/` under DerivedData's `SourcePackages/artifacts`); without it, existing
installs can't be updated.

### Layout

- `App/`: everything in the menu bar, plus hotkeys (the Fn monitor too), settings,
  onboarding and Sparkle.
- `Packages/TranscriptionKit`: Swift wrapper over whisper.cpp plus model download and
  SHA-256 verification (`ModelManager`, hashes pinned in `Types.swift`;
  `Scripts/fetch-model.sh` prints the hash of a fresh download if upstream files change).
- `Packages/AudioCaptureKit`: microphone capture, resampled to the 16 kHz mono Float32
  Whisper expects.
- `Packages/InputInjectionKit`: types text through the Accessibility API, falling back to a
  clipboard paste for apps that ignore it (Electron apps like Claude, Slack and VS Code
  always get the paste).
- `Vendor/whisper.cpp`: git submodule pinned to a tagged release, built with its own
  `build-xcframework.sh`.

`TranscriptionKit` and `AudioCaptureKit` are plain SPM packages, so `swift build` and
`swift test` work on them directly (`swift test` in TranscriptionKit needs a model first:
`Scripts/fetch-model.sh`).

### Known limitations

- Not sandboxed, so it can't go on the App Store; the Accessibility API it types through
  needs that.
- Transcribes once per hold rather than streaming, which is fine for dictation-length
  clips.

### Appendix: iOS companion app (experimental)

There's an untested-lately iOS target, `WhisperKeyboardMobile`. iOS doesn't let apps type
into other apps, and keyboard extensions can't fit a Whisper model in memory, so it's a
standalone app you trigger from the Action Button (or a Shortcut): it records, transcribes,
and copies the text to the clipboard. To try it, pick the **WhisperKeyboardMobile** scheme
in Xcode with your iPhone as the destination and press Cmd+R, then add the "Dictate" action
to a Shortcut and assign it under **Settings > Action Button**.
