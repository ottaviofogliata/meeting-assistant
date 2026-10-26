# Validation record

Date: 26 October 2026. This is an evidence record, not certification against every acceptance target in the specification.

## Environment

- Apple M5 Max, 128 GiB unified memory (`Mac17,7`).
- macOS 27.0.1 (26A434), Xcode 27.1 (27A9275).
- Argmax open-source SDK pinned to 1.1.1; fixed multilingual Whisper turbo `large-v3-v20240930_626MB`.
- Codex CLI 0.160.1. Actual structured transcript/image recap jobs completed using the local authenticated CLI.
- Models and meeting archives are local. Default archive: `~/Meetings`; model cache: Application Support. No real microphone recordings were submitted to Codex during QA.

## Automated checks

`swift test` passes 18 tests: 15 core checks, two audio conversion/level checks and one native H.264 encoding test. They cover the exact fifteen-minute screenshot boundary, retrospective thinning and protected reasons, two-hour cadence, screenshot selection coverage, pause-aware timing, immutable originals, revision ordering, path/symlink containment, archive writability, source-reference validation, bounded audio queues, speech-window boundaries, clock-only OCR changes, transcript scheduling across partial/full windows, and discrete five-channel microphone conversion.

The video test creates and finalizes three successive MP4 files through AVFoundation, opens each with AVFoundation, and checks track presence, independent paths, sidecars and duration within 40 ms. It detects the class of failure where only the first recording interval is finalized.

## Local transcription and speakers

A 40.013-second synthetic Italian/English meeting uses two macOS voices, four turns, an explicit budget, release decision, test owner/deadline and an unresolved feature flag. The final network-denied run produced eight transcript segments and two speaker identities. Audio was read in bounded disk windows; no full-meeting PCM allocation is used.

- Transcription inference: 4.47 seconds.
- Post-stop speaker identification: 5.28 seconds.
- First model preparation in this process: 57.36 seconds; a subsequent cached production-model load measured 0.95 seconds. Core ML cold preparation can take substantially longer than a warm load.
- Simple case/punctuation-normalized word edit distance: 1 edit / 102 reference words (0.98% WER). This small synthetic example does not establish accuracy on natural meetings, overlap or accents.
- Segment and word-derived timestamps were checked against the input duration.
- The entire local run succeeded under `sandbox-exec` with outbound and inbound network denied. First-time model downloads were completed beforehand.

A separate production run processed a complete two-hour synthetic recording cycling ten macOS voices:

| Measure | Observed |
| --- | --- |
| ASR inference over two hours | 1,260.00 seconds (about 21 minutes; 0.175 real-time factor) |
| Post-ASR speaker identification | 40.47 seconds |
| Final transcript segments | 2,879 |
| Automatically detected speakers | 9 of 10 synthetic voices |
| Maximum process resident set | 260,849,664 bytes |
| Peak process footprint reported by `time -l` | 244,761,728 bytes |
| Swaps reported for the process | 0 |

Two similar synthetic voices were merged. Speaker labels remain probabilistic, with uncertain/overlapping words left unassigned. No formal natural-speech diarization-error benchmark has been completed. Process RSS/footprint does not measure all allocations in separate system services or prove compliance on a physical 24 GiB Mac. The two-hour run validates bounded local processing, not a two-hour live online capture or a measured end-to-end finalization target on the target hardware.

## Running application

Microphone and screen/system-audio permissions were authorized by the user and checked on this Mac. Native tests exercised application-selected audio independently from a controlled visual window, microphone capture, realtime/background selection, pause, local recovery, source changes, periodic screenshots and content-change screenshots. Test media remains local.

The following defects were found through actual use and corrected:

- Opening an archived video crashed in the system SwiftUI AVKit bridge (`VideoPlayerView` superclass metadata). The player now uses an `AVPlayerLayer` inside an AppKit view. Selecting video meetings and navigating while recording were then exercised in the app.
- Small, frequent system-audio packets exhausted a callback-count queue limit. The limit now measures queued audio duration and bytes instead; later captures exceeded the previous 45-second failure point.
- Audio-device reconfiguration stopped microphone delivery. The audio engine observes configuration changes, reinstalls its tap/restarts when needed, and monitors stalled input.
- A partial background transcript at roughly 20 seconds could prevent its bounded 24-second window from ever committing. Full windows now commit regardless of the partial-update increment. A regression test covers both background and realtime boundaries.
- Stage Manager exposed transformed thumbnail windows as capture candidates. The source list now includes full offscreen candidates, rejects tiny thumbnails and uses the content filter's actual dimensions. Unavailable frames generate a visible warning. Stage Manager was temporarily disabled with explicit user approval to complete UI testing, then restored.
- ScreenCaptureKit's recording-output path did not reliably start/finalize video intervals after pauses/source changes. Video now uses an explicit, bounded AVFoundation H.264 writer, starts only on a valid frame, and awaits finalization. The analysis path copies at most one frame per second rather than retaining capture-pool surfaces through OCR.

The final native capture ran for 254.5 active seconds through Pause/Resume and a visual-source change. It finalized three playable MP4 intervals (13.100433, 17.275783 and 222.930250 seconds), 128 microphone segments, 128 selected-application audio segments and 29 screenshots, with no capture warnings and no automatic Codex jobs. Muted playback was verified visibly in the application across the resumed video interval.

During that run the user reported missing text after switching to realtime. Investigation confirmed a separate five-channel-to-mono conversion defect: captured PCM was valid but inference received zeros. The source correction passes the discrete-channel regression and recovers the user's expected test phrase from the same recording. Installation and the exact live mode-switch retest were pending when the user explicitly paused development. See `KNOWN_ISSUES.md`.

## Codex boundary

Synthetic-only runs completed with transcript input, and with transcript plus a controlled presentation image. Structured JSON was validated for required sections, requested language and source IDs. Snapshot transcript, selected-image manifest, response and Markdown are retained per job. Real capture tests created no recap jobs automatically.

CLI features unrelated to recap generation are disabled, command execution is disabled, web search is disabled, and the command sandbox is read-only. This is not complete filesystem-read isolation. Authentication stays with the user's installed CLI. Missing CLI/network/authentication and malformed replies leave local media and prior completed recaps intact.

## Remaining acceptance work

- A physical 24 GiB Mac with a real conferencing application; total system memory/energy and p95 realtime latency measurements.
- Long natural Italian/English meetings with ten human speakers, overlap, accents and technical terminology; formal WER/DER and speaker-attributed errors.
- External/USB and Bluetooth/headset routing, built-in-speaker double-talk/echo quality, browser tab audio scope and device-disconnect behavior.
- Labeled webcam-grid, scroll, small code/result changes and animation examples to tune false-positive/missed screenshot rates.
- Full live two-hour audio/video capture; interruption/low-storage fault matrix; a measured worst-case crash-loss bound. Two-second audio containers and durable sidecars support recovery, but do not by themselves certify the five-second target in every system failure.
- Codex hierarchical processing of a transcript larger than the single-call input threshold, and non-default custom Codex providers/profiles.

The specification's initial performance/quality targets remain targets until these runs are completed. They are not silently relaxed by the development-machine results.
