# Development checkpoint — paused at the user's request

Date: 26 October 2026. Do not continue development until the user asks to resume.

## Objective and repository

The user requested committing/pushing the English specifications, then implementing the entire native macOS Meeting Assistant end-to-end. The current task was explicitly paused for a few hours; it was not completed or cancelled.

- Workspace: `/Users/8/Sites/meeting-assistant`.
- Branch: `codex/meeting-assistant-checkpoint`; origin: `git@github.com:ottaviofogliata/meeting-assistant.git`.
- Specifications committed and pushed: `2577e7a` initially, then `0ca25dc` for the default `~/Meetings` archive. The latter push was confirmed successful.
- Application checkpoint `8493fde` is published on `codex/meeting-assistant-checkpoint` at the user's request. Remote `main` remains at the specification commit `0ca25dc`. Development remains paused.
- Product decisions remain in `specs/specs.md`. Do not reopen model comparisons: compressed multilingual Whisper large-v3-turbo `large-v3-v20240930_626MB` is explicitly chosen by the user.

## Product constraints to preserve

Three recording modes: online microphone + selected app/all-system audio + screen/window; in-person microphone only; in-person with presentation microphone + screen/window. Visual/audio sources are independent. Optional full video is chosen before Start. Background/realtime transcription can switch during capture. Speaker identification runs only after Stop; never infer live speaker identities. Italian/English code switching, up to two hours and ten speakers. Editable text/names preserve automatic originals.

Recap generation is exclusively manual via Send to Codex, including archived app-created recordings. It uses the complete current transcript plus selected screenshots, not audio/video. No external import in the product. Archive default is `~/Meetings`, models are in Application Support, and media is retained until manual deletion except the specified screenshot thinning. Periodic screenshots are every 60 active seconds, retroactively thinned to 120 seconds after fifteen minutes; change/boundary shots are protected.

## Implemented application

Swift/SwiftUI + AppKit, macOS 15+, pinned Argmax SDK 1.1.1, SwiftPM package. Main archive/details window, menu-bar controls, native audio/screen capture, bounded disk-backed ASR, post-stop SpeakerKit, screenshots/OCR/ignore masks, H.264 video, synchronized playback, revisions, manual structured Codex subprocesses and recovery are implemented.

Main files:

- `Sources/MeetingCore`: archive/data models, cadence, clock, speech windows, transcript scheduling, bounded audio queues and text-change policy.
- `Sources/MeetingRuntime`: capture, AudioIO, inference, tokenizer, video writer and Codex subprocess.
- `Sources/MeetingAssistant`: AppState/controller, SwiftUI views and native AVPlayerLayer playback surface.
- `Sources/MeetingAssistantQA`: synthetic fixtures and developer-only local diagnostics.
- `scripts/build_app.py`: builds/signs `dist/Meeting Assistant.app` using an available Apple Development identity, without hardcoded personal credentials.
- `docs/VALIDATION.md`: measured evidence and remaining acceptance limitations.
- `docs/KNOWN_ISSUES.md`: the user's realtime-switch report and investigation.

## Critical latest fix — source is newer than the installed app

The bundled app at `dist/Meeting Assistant.app` includes the working H.264 writer and prior lifecycle fixes, but **does not yet include the latest five-channel audio conversion fix or the final pause metadata checkpoint**. Rebuild/install before the next live transcription test.

The user switched an active background recording to Realtime and said “uno due tre prova”; no transcript appeared. Original microphone CAF files were valid five-channel Float32/48 kHz audio. AVAudioConverter's automatic multichannel remapping yielded a completely silent mono inference buffer. This is a real input-conversion defect, not evidence by itself that the mode-switch UI is broken.

Source corrections in `AudioIO.swift` explicitly mix channels before mono resampling, handle near-cancellation, and adjust speech level only on derived inference audio. `Inference.swift` gates individual speech windows rather than the RMS of a whole mostly-silent block. Originals were not changed.

The same real test recording, reprocessed locally with the correction, now yields nine segments and recognizes the expected phrase at approximately 6.72, 9.72, 12.68, 25.52 and 33.54 seconds. **Exact live switch verification and an eight-second-window replay are still pending.** Do not mark this acceptance case fully verified yet.

## Verification already completed

- Latest `swift test`: **18 passing tests**, including discrete five-channel audio, quiet speech level, irregular timestamp video encoding over three successive files, transcript scheduling and archive/retention integrity. Output: `.local/final-unit-tests.log`.
- Final native online capture: `~/Meetings/2026-10-26_14-44-45_43197456`, title `TEST H264 · cattura corretta`; 254.5 active seconds, Pause/Resume, source change, three valid MP4s, 128 microphone + 128 app-audio segments, 29 screenshots, zero capture warnings, zero automatic recap jobs. Visible muted playback was checked. Its archived transcript is still the pre-fix empty transcript; diagnostic results are separate.
- Real local diagnostic after the channel fix: `.local/diagnostics/43197456-…-0.json` (use `rg --files --hidden .local/diagnostics` for the full UUID). It contains real test speech and must remain local.
- Synthetic bilingual fixture: `.local/fixtures/bilingual-meeting.wav`; final prior 24-second-window run under network-denied sandbox produced eight segments/two speakers, 4.47 s ASR + 5.28 s diarization. Case/punctuation-normalized WER was 1/102 on this small synthetic sample. Those timing/quality numbers precede the latest signal-conversion changes; do not silently present them as a fresh benchmark.
- Two-hour synthetic ten-voice run: `.local/stress-archive/2026-10-26_13-21-09_1C470D0C`; ASR 1,260 s, diarization 40.47 s, 2,879 segments, nine detected speakers for ten voices. Similar voices merged. Max process RSS 260,849,664 bytes; system-service/unified-memory allocations were not fully measured. Do not rerun the whole 21-minute ASR unnecessarily.
- Actual synthetic Codex recap jobs succeeded with transcript + image. The GUI Send to Codex button was also exercised after text/name edits. Synthetic GUI archive: `~/Meetings/2026-10-26_12-31-56_E95946D2`, title `QA · riunione di test italiano / English`. Speaker names changed to Marta/Luca, `2000` corrected to `duemila`; immutable originals retained, stale recap indication verified, manual regeneration completed at transcript revision 165. No real capture was sent to Codex.

## Resume sequence

1. Read this file, known issues and live Git status. Preserve all media/originals and existing changes.
2. Build/install the newest source with `python3 scripts/build_app.py --launch`. The last operation before pausing only rebuilt the QA executable; no model/recording job remains running.
3. Run the exact short replay, for example `.build/out/Products/Debug/meeting-assistant-qa diagnose-audio ~/Meetings/2026-10-26_14-44-45_43197456 0 8`. This works locally and writes only ignored diagnostic files; no Codex invocation.
4. Run the synthetic bilingual fixture with `--realtime-windows` to exercise the eight-second inference windows. This QA flag was compiled immediately before pausing but has not been run yet. A normal 24-second fixture can verify regressions after signal conversion changes. No other ASR model comparisons are wanted.
5. Verify the app's background→realtime→background transition with actual speech, including Pause/Resume, and confirm no loss/duplication. The selected mode is correctly saved as realtime in the reported test; the signal path was the confirmed failure.
6. Finish practical recovery/quit checks as appropriate. Do not claim a certified five-second worst-case audio crash-loss bound or target-hardware results without measurement.
7. Update validation/issue status, commit and push final fixes on the checkpoint branch when ready, package the signed app and leave it idle. Keep the implementation on this branch; `main` contains the specifications.

## Test safety, user preferences and cleanup

- The user explicitly authorized microphone and screen/system-audio access for tests. Keep real test recordings local. Use only synthetic content for Codex recap QA.
- The user asked to stop the looping test sound; it was stopped. Do not start audible fixtures again unprompted. Screen fixtures without an audio argument are silent. Playback has a mute control and was tested muted.
- Stage Manager caused tiny/transformed window candidates and Computer Use failures. The user explicitly approved temporary disabling for testing, followed by restoration. It was **restored to enabled before this pause** (`GloballyEnabled=1`). Preserve/restore the user's original setting after any later authorized test adjustment.
- All Meeting Assistant, Capture Fixture, QA CLI and local HTTP test-server processes were stopped before pausing. No recording or Codex job is active.
- Use CUA for native UI interactions. After a REPL reset, its first call must be exactly one documented entrypoint. Stage Manager can make background CUA captures fail with -3811/-3812; do not repeatedly create invalid capture streams. The source picker rejects tiny thumbnails and records an unavailable-frame warning.
- Earlier failed native test archives are still in `~/Meetings`; their warnings are historical. Do not delete them or rewrite their automatic originals silently.
- No subagents were used or requested. Do not spawn them unless the user or applicable instructions explicitly authorizes delegation.

## Outstanding broader acceptance limits

Development hardware is M5 Max/128 GiB on macOS 27.0.1, Xcode 27.1, Codex CLI 0.160.1. A physical 24 GiB machine, real conferencing load, ten natural speakers, overlap, external/Bluetooth microphones, speaker double-talk and formal latency/energy/diarization benchmarks remain unvalidated. See the validation record for the full list. These are targets/limitations, not reasons to erase completed work or restart the design.
