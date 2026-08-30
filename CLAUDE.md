# CLAUDE.md

Project-specific guidance for Claude Code when working in this repo.

## Build hygiene

After any Swift change, verify with a real build — not just that it compiles, but that it's
warning-free:

```
xcodebuild -project WhisperKeyboard.xcodeproj -scheme WhisperKeyboard -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | grep -iE "warning:|error:|BUILD SUCCEEDED|BUILD FAILED"
```

Treat every compiler warning here as a bug to fix, not noise to filter past — these are
usually real (a deployment-target/linked-framework mismatch, a Swift 6 actor-isolation
violation, a `Sendable` capture across a closure boundary that can actually race). Fix the
root cause rather than suppressing the warning, unless the warning itself is the false
positive (e.g. an Apple framework's `@Sendable`-annotated callback that's documented to run
synchronously — there, `@preconcurrency import` on that one framework is the correct fix, not
a blanket `-Wno-*` flag).

The same applies to `swift build`/`swift test` inside the SPM packages under `Packages/` when
iterating on those directly, and to the equivalent warnings whisper.cpp's own build emits if
`Scripts/setup.sh` is ever re-run after a toolchain change.

**Xcode's issue navigator can show stale warnings** after edits — it doesn't always fully
clear resolved issues from a previous debug session without a `Product > Clean Build Folder`
(⇧⌘K). If a warning appears fixed in the actual `xcodebuild` output above but still shows in
a screenshot of Xcode's sidebar, it's stale UI, not a regression — say so, don't re-chase it,
and suggest the user does a clean build to clear the display.

## TCC / permissions during development

Rebuilding with a different code signing identity (ad-hoc "Sign to Run Locally" vs. a real
Development certificate, or after `xcodegen generate` regenerates the project) can leave
stale or duplicate rows in System Settings → Privacy & Security for this app (Accessibility,
Microphone) — macOS treats a changed signature as a different app. `Scripts/reset-tcc.sh`
clears the Accessibility grant; `tccutil reset Microphone com.omar.whisperkeyboard` does the
same for Microphone. Run whichever is affected, then relaunch and re-grant.
