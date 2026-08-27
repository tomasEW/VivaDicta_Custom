# VivaDicta Mac (native macOS prototype)

This directory contains a clean native macOS front-end built on the public VivaDicta modules in this repository. It does **not** depend on the private/closed-source VivaDicta macOS application.

## First milestone

- Native SwiftUI macOS app (macOS 14+)
- Global `Control + Option + Space` dictation shortcut
- Recording through the existing `AudioRecording` module
- **Groq transcription is the default** (`whisper-large-v3-turbo`) and requires no local model download
- Optional local WhisperKit transcription
- Local model is downloaded **only when the user explicitly clicks Download Local Model**
- Groq API key stored in macOS Keychain
- Automatic paste back into the app that was active when dictation started
- Clipboard fallback when Accessibility permission is unavailable

## Build and run

1. Open `VivaDictaMac.xcodeproj` in Xcode.
2. Let Xcode resolve the local Swift packages and their dependencies.
3. Select the `VivaDictaMac` scheme and **My Mac**.
4. Build and Run.
5. Allow microphone access when prompted.
6. For system-wide automatic paste, click **Request Accessibility Permission** and enable VivaDicta Mac in:
   `System Settings → Privacy & Security → Accessibility`.

## Groq mode (recommended for first run)

1. Leave **Groq** selected.
2. Enter a Groq API key and click **Save**.
3. Keep Language on **Auto Detect** for mixed Chinese/English speech.
4. Put the cursor in any app.
5. Press `Control + Option + Space` to start recording.
6. Press it again to stop. The transcript is sent to Groq and pasted back into the original app.

No WhisperKit model is downloaded in this flow.

## Local mode

1. Select **Local WhisperKit**.
2. Click **Download Local Model**.
3. The app downloads and prepares `openai_whisper-large-v3-v20240930_turbo_632MB` through the repository's existing `LocalTranscription` module.
4. Once ready, dictation uses the local model and no audio is sent to Groq.

The local model is never downloaded automatically at launch.

## Scope intentionally excluded from this milestone

- iOS keyboard extension / Live Activities / Watch app / widgets
- Closed-source VivaDicta macOS implementation details
- Text refinement / VivaMode (next integration layer after transcription is stable)
- InputMethodKit input source (current MVP uses Accessibility + paste)

The goal of this target is to prove the end-to-end Mac path first: **hotkey → record → transcribe → paste**.
