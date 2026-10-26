# Meeting Assistant

A native macOS recorder with local Italian/English transcription, post-recording speaker identification, contextual screenshots, and an explicitly requested Codex recap.

## Build and run

Requires an Apple Silicon Mac, macOS 15 or later, and Xcode 16+ / Swift 6+. The current development toolchain is Xcode 27.1. Dependencies are pinned in `Package.resolved`.

```sh
python3 scripts/build_app.py --launch
```

The script builds `dist/Meeting Assistant.app`, generates the icon, and signs the app with an available Apple Development identity (or an ad-hoc signature if no identity exists). Set `MEETING_CODESIGN_IDENTITY` to choose a specific signing identity. For a faster development build, add `--configuration debug`.

Open `Package.swift` in Xcode to work on the sources. Use the bundled `.app` for microphone/screen permission testing, not an unsigned executable from a terminal.

## First use

1. The default archive is **`~/Meetings`**, outside Documents and iCloud Drive. A different folder can be selected in Settings.
2. Prepare the local models in Settings, or allow the first recording's preparation to finish. Models are cached in `~/Library/Application Support/MeetingAssistant/Models`, outside iCloud.
3. Allow microphone and, for visual/online modes, screen and system-audio access in macOS Privacy & Security. Source selection refreshes the available displays, windows, and applications.
4. Choose Online, In person, or In person with presentation; select the applicable inputs. Video is optional and chosen before Start.
5. Record using background chunks or visible realtime text. The mode and visual source can be changed during capture. Pause/Resume keeps the same logical meeting.
6. After Stop, local transcription finishes and speakers are identified. Review or correct text and speaker names; the automatic originals remain in the meeting folder.
7. Press **Send to Codex** to generate a recap. Stopping, editing, reopening, or reconnecting never submits a meeting automatically.

The menu bar keeps recording controls available when the main window is closed. Archived timestamps seek in synchronized audio/video playback. Meeting deletion uses macOS Trash.

## Models and Codex

- Transcription: **compressed multilingual Whisper large-v3-turbo**, variant `large-v3-v20240930_626MB`, via WhisperKit/Core ML. Language detection is restricted to Italian/English and repeated at utterance boundaries.
- Speakers: SpeakerKit/Pyannote after Stop, using bounded audio windows and meeting-wide centroid reconciliation. No speaker inference runs during recording.
- Codex: install and authenticate the Codex CLI separately. Settings discover common executable paths and the configured model. The app starts `codex exec` with prepared transcript/image input, structured JSON output, a read-only command sandbox, and unrelated agent tools disabled. Audio and full video are not submitted.

Screenshots come from the existing selected capture stream. Periodic shots use 60-second cadence, switching retroactively to 120 seconds after fifteen active minutes. Change/boundary images are protected. Local change detection, face/region masks, and OCR select contextual images for the recap.

The archive contains versioned metadata, two-second recoverable PCM/CAF audio segments, optional H.264 MP4 video intervals, screenshots, original/current transcripts, and separate recap runs. The index can be rebuilt from these files. Interrupted recordings remain available for local recovery; Codex jobs require an explicit retry. Video uses AVFoundation and the same selected screen stream as screenshot analysis.

## Validation

```sh
swift test
python3 scripts/create_fixture.py
swift run meeting-assistant-qa fixture .local/fixtures/bilingual-meeting.wav .local/qa-archive
```

The fixture generator uses macOS voices and requires FFmpeg for test audio assembly; FFmpeg is **not** an application runtime dependency. The fixture exercises Italian/English turns, local transcription, post-stop diarization, and archive persistence. Add `--codex` only to explicitly test a real Codex recap using synthetic content.

`swift run meeting-assistant-qa screen-fixture` opens a controlled presentation window for screen/video testing without playing audio. QA archives are separate from the default user archive. See [validation results and remaining acceptance work](docs/VALIDATION.md), and the [specifications](specs/specs.md) for the full behavior. Performance targets in the specification are not claims of certification on a 24 GB machine.

## Source layout

- `Sources/MeetingCore`: archive schemas, revisions, timestamps, cadence/retention, speech windows, and speaker reconciliation.
- `Sources/MeetingRuntime`: native capture, media playback, local inference, screenshot analysis, and Codex subprocesses.
- `Sources/MeetingAssistant`: SwiftUI application, main window, menu bar, and settings.
- `Sources/MeetingAssistantQA`: developer-only synthetic pipeline and controlled capture fixtures.
- `Tests`: deterministic archive, retention, timing, and content-integrity checks.

WhisperKit/SpeakerKit are provided by the [Argmax open-source SDK](https://github.com/argmaxinc/argmax-oss-swift). Dependencies and downloaded weights retain their respective upstream licenses.
