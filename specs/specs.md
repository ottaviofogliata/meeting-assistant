# Meeting Assistant — Product and Technical Specification

Date: 2026-10-26

Status: Product requirements agreed through discussion. Technical settings explicitly marked as proposed, and performance targets below, are starting points to validate during implementation, not measured results.

## 1. Purpose and scope

Build a lightweight, native macOS meeting recorder that produces useful local transcripts and, on explicit request, a structured recap through the Codex CLI.

The first version is for personal use. Development takes place on the user's 128 GB Apple Silicon Mac, but the application must be designed and validated for the intended M5 Pro/Max-class configuration with **24 GB of unified memory**. The larger development machine must not determine the memory budget.

The supported workload is a meeting lasting up to **two hours**, with up to **ten speakers**, in Italian, English, or a mixture of both within the same meeting. Two hours is the required validation workload, not an instruction to stop recording automatically.

Capture, transcription, speaker diarization, screenshot analysis, and OCR run locally. After downloading the required models, recording and local processing must work without Internet access. Recap generation uses the user's configured Codex provider and may require a network connection.

### 1.1 Confirmed product decisions

- Native macOS application with a main window and menu bar controls.
- Local, user-selected archive folder, with one folder per meeting, accessible through Finder and the application.
- Audio recording in all modes; screenshots in the two modes that include screen capture.
- Optional full screen video, selected before recording starts.
- Two transcription modes: background chunks and visible realtime text. Switching is possible before or during recording.
- The default transcription model is **compressed multilingual Whisper large-v3-turbo**, using the WhisperKit variant `large-v3-v20240930_626MB`. No comparative transcription-model selection phase is required.
- **No speaker diarization during recording, in either transcription mode. Speaker identification starts only after Stop.**
- Faithful transcription with automatic punctuation and paragraphs; no paraphrasing or automatic editorial cleanup.
- Editable archived transcript and speaker names, preserving the original automatic result.
- **Recaps are never generated automatically. The user must press “Send to Codex”.**
- Reopening past recordings means reopening meetings created by this application. External audio/video import is outside the first version.
- User media is retained until manually deleted, except for the explicitly specified thinning of periodic screenshots.

### 1.2 Outside the first version

- Meeting bots, participants joining calls, and Meet/Zoom/Teams recording APIs.
- Windows, Linux, Intel Mac support, distribution packaging, and Mac App Store publication.
- Cross-meeting voice recognition, voice enrollment, or automatically resolving real names from meeting platforms.
- Live speaker labels or speaker embeddings computed during recording.
- External recording import, cloud transcription fallback, automatic recap submission, and calendar-driven recording.
- Capturing a physical projector or presentation that is not visible on the Mac. This would require another input source.

## 2. Recording modes

“In-person” describes a physical meeting. It is independent of whether the Mac has an Internet connection.

| Mode | Audio capture | Visual capture | Full video |
| --- | --- | --- | --- |
| Online meeting | Selected microphone plus selected application audio, with an option for all Mac audio | Selected display or window; periodic and change-triggered screenshots | Optional, configured before Start |
| In-person meeting | Selected microphone only | None | Unavailable |
| In-person meeting with presentation | Selected microphone only | Selected display or window showing the presentation; periodic and change-triggered screenshots | Optional, configured before Start |

Audio and visual selections are independent. For example, the app may capture call audio from a browser while taking screenshots of a presentation window in another application.

Application audio is an application-level selection. For browsers, it may include sound from other tabs in that browser. A selected visual window must not be presented as a guarantee of tab-level audio isolation.

## 3. Main workflow

### 3.1 Before Start

The user selects the recording mode, microphone, applicable application/system audio source, applicable visual source, transcription mode, and optional full-video setting.

The application checks required macOS permissions, archive writability, available storage, and local model availability. In-person audio-only recording must not require screen capture permission. Model download and preparation have visible progress and failure states.

The video setting defaults to off. As a first implementation rule, it is fixed for the recording once Start is pressed. The transcription mode and visual source remain changeable while recording.

Codex installation, authentication, or connectivity must not be a prerequisite for recording or local processing.

### 3.2 During recording

- Persist audio continuously and process it using the selected transcription mode.
- Show elapsed recording time, recording/paused state, and audio activity.
- In visual modes, run screenshot scheduling and change detection. Persist video only when enabled before Start.
- Allow switching between background and realtime transcription without restarting capture, losing words, or duplicating transcript intervals.
- When switching to realtime, show the text already processed in the background, followed by live provisional text.
- Keep speaker diarization models unloaded; do not extract voice embeddings in the background.
- Closing the main window leaves recording accessible through the menu bar.

Pause, Resume, and Stop are available from the main window and menu bar. Pause suspends audio, video, screenshot acquisition, and transcription input. Resume continues the same logical meeting. Quitting during recording must resolve the active recording explicitly rather than silently discarding it.

### 3.3 After Stop

1. Finish and durably save captured media.
2. Flush the remaining transcription work and save the original ASR output.
3. Release the transcription model and its large buffers.
4. Load the diarization pipeline, identify speakers across the entire meeting, and align labels with transcript timestamps.
5. Save the original automatic transcript with speaker labels and initialize the editable revision.
6. Release local inference models and mark the meeting ready for review.

These steps run without blocking application navigation. Progress and failures are visible. A failed diarization step must not invalidate saved media or a completed transcript.

### 3.4 Review and manual recap generation

The user can review playback, screenshots, transcript text, speaker names, and the proposed recap language. Local review and editing do not contact Codex.

The **“Send to Codex”** button becomes available when local processing is complete. If processing has failed, the application explains which step needs retrying. There is no automatic submission when recording stops, processing finishes, the archive is reopened, connectivity returns, or the application launches.

Pressing the button creates a snapshot of the selected meeting revision and launches one recap job. Duplicate clicks must not create concurrent jobs for the same snapshot. An explicit retry or later regeneration reuses saved meeting material; recording is not required again.

## 4. Audio capture and synchronization

### 4.1 Inputs and devices

Support calls using headphones or speakers, and in-person recordings using the Mac microphone or an external microphone. Provide an explicit microphone selector and activity indicator.

For online meetings, capture microphone and application/system audio as separate synchronized sources. A source is not a person: several people may share a room microphone, and several remote people may share the application's audio stream.

Use a common monotonic timeline, preserving source timestamps and recording interruptions. Resample for inference as needed, without allowing clocks or device changes to introduce accumulating drift.

If a device disconnects, a selected application exits, or permission is lost, show the affected source and mark its missing interval. Continue unaffected inputs where possible. Never silently replace a selected application with all system audio.

### 4.2 Echo handling

Speaker playback may re-enter the microphone. The pipeline must account for this before speaker attribution so a remote voice is not transcribed twice or identified as another local speaker.

Keep original source recordings available. Validate echo cancellation/suppression using the system audio reference and an appropriate native or embedded audio-processing implementation. Do not assume ScreenCaptureKit alone removes acoustic echo.

Tests must include simultaneous local/remote speech: removing echo must not erase the local speaker. Headphone and speaker configurations require separate acceptance runs.

### 4.3 Persistence

Write captured media incrementally using finalized segments or another recoverable recording format. Do not retain the entire meeting as PCM arrays in memory. Normalized inference audio is derived data; it must not replace the original captured sources.

Compact M4A/AAC source audio is the proposed archival format. The exact durable recording container must satisfy recovery requirements; an unfinalized container plus a metadata checkpoint is not sufficient evidence that audio is recoverable.

## 5. Transcription

### 5.1 Content and language

- Support Italian and English, including language changes within a meeting and mixed-language utterances.
- Preserve the language spoken in each passage. Do not translate the transcript into one language.
- Add punctuation, capitalization, and paragraphs while preserving wording and meaning.
- Do not intentionally paraphrase, remove repetitions or false starts, invent missing speech, or perform the cleanup expected of a recap.
- Preserve names, technical terms, numbers, and code-related language as accurately as possible.
- Store timestamps and source provenance. Represent uncertain or unavailable speech explicitly rather than filling it with guessed sentences.

Language handling must be tested on actual code switching; detecting one language at the beginning and assuming it applies to the whole recording is insufficient.

### 5.2 Background chunks

Continuously transcribe short, bounded audio windows without displaying a live transcript. Prefer speech/silence boundaries and a small context overlap. Persist completed results incrementally.

The initial engineering target is to commit text approximately every 20–30 seconds of speech. This mode aims to reduce update frequency and processing overhead, rather than defer the entire recording until Stop.

### 5.3 Realtime text

Display provisional partial text, then replace or merge it with committed segments. Text may change while an utterance is decoded. Clearly distinguish provisional and committed text without displaying speaker identities.

Use one continuous timestamp and segment identity scheme across both modes. Switching modes must preserve already processed material and any pending audio, with overlap reconciled instead of duplicated.

If transcription falls behind, keep capture intact and queue references to audio on disk. Show a processing delay instead of dropping recorded speech or silently changing the selected mode.

## 6. Speaker identification after Stop

Run diarization only after capture ends and transcription has been flushed. Detect the number of speakers automatically within the supported workload; ten is the supported maximum, not an instruction to always create ten labels.

Assign stable, meeting-local IDs such as `speaker_001`, displayed as “Speaker 1”, “Speaker 2”, etc. The user can assign or correct display names. Names do not establish voice profiles for future meetings.

Speaker labels must remain consistent across the entire recording, including separate audio-processing windows. Independently labeling each chunk and concatenating its local speaker numbers is not acceptable. Bounded segmentation and embedding extraction must feed meeting-wide reconciliation/clustering.

Align labels with transcript timing, allowing a transcript segment to be divided at a speaker turn when supported by reliable timing. Preserve overlap and uncertainty where the audio does not support a confident single-speaker assignment. Do not infer real identities from voice alone or ask Codex to invent them.

Renaming a speaker updates all linked transcript passages and subsequent recap input. Speaker segmentation editing, manual cluster merging, and cross-meeting identification are not required for the first version.

## 7. Screenshots and significant changes

### 7.1 Source and timeline

The user chooses a display or window before Start and may change it during recording. Record source changes on the meeting timeline and immediately capture a boundary image for the new source.

Use **active recording duration**, excluding pauses, for screenshot cadence and the fifteen-minute threshold. Also retain wall-clock timestamps so interruptions remain understandable.

### 7.2 Periodic schedule and thinning

| Active duration | Periodic capture policy |
| --- | --- |
| Up to and including 15 minutes | Every 60 seconds |
| Once duration exceeds 15 minutes | Every 120 seconds, aligned to the recording's original start |

When active duration first exceeds 900 seconds, retroactively retain one periodic screenshot per two minutes from the first fifteen minutes. For example, retain periodic captures at minutes 2, 4, 6, 8, 10, 12, and 14, and remove the unprotected captures at minutes 1, 3, 5, 7, 9, 11, 13, and 15. The next scheduled capture is minute 16, then 18, 20, and so on.

A recording ending at exactly fifteen minutes retains the sixty-second cadence. The threshold applies only once active duration exceeds fifteen minutes.

Every image has one or more reasons: `periodic`, `significant_change`, `recording_start`, `recording_end`, `resume`, or `source_change`. Start/end/resume boundary images are proposed engineering defaults, independent of the periodic schedule.

**Thinning may delete only images whose sole retention reason is periodic and whose original schedule slot is removed.** Change-triggered and boundary images are protected, even if they also represent a periodic slot. Coalescing captures of the same frame must preserve all reasons.

Update metadata and files consistently. Retrying thinning after a crash must be safe and must never remove a protected image.

### 7.3 Meaning of “significant change”

Capture an additional screenshot when useful, persistent visual content appears or changes substantially, including:

- A different slide, page, window, or document section.
- Scrolling that exposes new content, once the view settles.
- Meaningful changes to text, code, charts, command output, or results.

Ignore cursor movement, blinking carets, clocks, decorative animation, transitions, and movement within webcam tiles. Large pixel changes caused by faces are not automatically useful; small changes in a code or output region may be useful.

This is an operational definition to validate on examples, rather than a claim of complete semantic understanding of the screen.

### 7.4 Proposed lightweight detector

1. Sample approximately one reduced-resolution frame per second.
2. Compare against the last accepted stable scene, while also tracking recent frames. Comparing only adjacent frames would miss gradual changes.
3. Combine tiled visual differences and perceptual/structural similarity. Use local OCR to check candidate text changes where appropriate, rather than running a large vision-language model continuously.
4. Exclude dynamic regions from scoring. Use source-specific motion analysis and configurable ignored regions to handle webcam tiles and similar areas. Recheck masks after source or geometry changes.
5. Require approximately two stable samples before capturing settled content. Use an initial five-second cooldown with a pending latest candidate so continuous scrolling does not create a burst or permanently suppress the final view.
6. Acquire the retained screenshot at readable resolution. Never save the reduced analysis thumbnail as the only archival image.

Pixel, tile, similarity, OCR, and stability thresholds are calibration parameters. Tune them against slide changes, scrolling, small meaningful text edits, typing, animated cursors, webcam grids, and application transitions.

Ignored regions affect change scoring; this does not imply redaction from archived screenshots. The selected display/window determines the captured visual content.

The initial retained-image default is high-quality JPEG, preserving aspect ratio with a maximum long edge around 2560 pixels. Increase quality/resolution or use a lossless format if text readability tests require it.

### 7.5 Selecting screenshots for Codex

Retained images form the visual archive. Select a subset for Codex using time coverage, visual diversity, readable content, change events, and relevance to nearby transcript passages. OCR/token overlap can assist local ranking; semantic analysis is completed by Codex when requested.

Prefer representative distinct content over repeated copies of the same view. The initial input budget is approximately 24 images for a two-hour meeting, adjustable after testing image readability and the configured Codex model's limits. This is a selection budget, not an archival deletion policy.

Keep each selected image's ID, capture reason, source, and timestamp. Make the chosen materials inspectable before submission without requiring a second approval step after “Send to Codex”.

## 8. Optional full video

In visual modes, the user may enable full screen recording before Start. Audio and screenshot capture continue to follow their own rules regardless of this option.

Proposed defaults are hardware-encoded H.264, up to a 1920×1080 bounding box at 30 fps, preserving aspect ratio. Optional video must not make screen-change analysis run at the video's frame rate.

Support source changes and pauses as one logical meeting. Physical video segments are acceptable if playback and timestamps remain continuous and understandable. Synchronize video with the authoritative audio timeline and make recorded video playable with meeting audio.

Finalize incrementally and avoid an entire-meeting video buffer in RAM. Video is retained locally; sending full audio or video to Codex is outside the agreed recap input.

## 9. Archive, originals, and editing

### 9.1 Organization

The user selects a local archive root. Each meeting has a stable ID and its own folder, discoverable in the main window and Finder. The application indexes these folders; a rebuildable index must not become the sole copy of meeting content.

An illustrative layout is:

```text
<archive-root>/2026-10-26_14-30-00_<meeting-id>/
  meeting.json
  capture/
    manifest.json
    audio/
    video/                       # Only when enabled
  screenshots/
    manifest.json
    <screenshot-id>.jpg
  transcripts/
    asr-original.json
    original.json                # Automatic result with speaker labels
    current.json                 # Editable revision
    current.md
  recaps/
    <run-id>/
      input-manifest.json
      transcript-snapshot.json
      recap.json
      recap.md
```

Version JSON schemas. Store timestamps, pause/gap intervals, input/source changes, source-to-media mappings, capture reasons, model/configuration versions, transcript revision, and processing state. Store UTC wall-clock time with display timezone information and a monotonic active-recording timebase.

Avoid duplicating large media files for recap snapshots. Reference immutable screenshot/media IDs and retain the exact transcript snapshot and source manifest used for each recap.

### 9.2 Manual corrections

The archived transcript supports text corrections and assigning/correcting speaker display names. Preserve the original automatic output unchanged.

Autosave edits as a new current revision. Edited text remains associated with its original segment time interval. If word timings no longer match edited words, retain segment-level navigation and mark word-level timing as stale rather than inventing timestamps.

Editing text, speaker names, or recap language makes a previously generated recap stale. Keep it readable with its source revision and provide manual regeneration through “Send to Codex”. Editing must never trigger regeneration automatically.

Playback, transcript passages, screenshots, and recap references share the same timeline. A timestamp reference in the application seeks to the associated audio/video position and displays the relevant visual material when available.

### 9.3 Retention and deletion

Keep original audio, optional video, retained screenshots, original transcripts, edits, and recap versions until the user deletes them. The only automatic removal of retained evidence is the specified periodic screenshot thinning. Disposable caches and temporary derived files may be cleaned independently.

Manual deletion should move meeting folders to macOS Trash rather than irreversibly removing them. Detect missing or moved files gracefully and avoid silently deleting the remaining material when an archive entry is incomplete.

## 10. Codex integration and recap

### 10.1 Invocation

Launch the installed Codex CLI as a subprocess through Swift `Process`; a visible Terminal window is not required. Use a configured or discovered executable path and validate required capabilities against the installed version.

Pass arguments as an argument array and meeting content through stdin or prepared input files. Never construct a shell command by interpolating transcript text, meeting titles, or file paths.

The current CLI supports non-interactive `codex exec`, stdin prompts, image attachments, JSONL events, structured final output, and a final-output file. Use supported options such as `--image`, `--json`, `--output-schema`, `--output-last-message`, `--skip-git-repo-check`, and `--sandbox read-only` as appropriate to the installed version. Consider `--ephemeral` so the application owns recap history without requiring separate persistent CLI sessions.

Use the user's selected Codex model/profile; do not silently choose a different provider or paid transcription service. Validate that the chosen model can process the selected visual inputs.

Prepare a minimal input snapshot, request recap generation only, and restrict tool capabilities and filesystem mutation as supported by the CLI. A read-only command sandbox prevents writes; it must not be described as complete filesystem-read isolation. Treat transcript and screenshot text as source material, not as instructions to execute commands or access unrelated accounts.

### 10.2 Input contract

Each manually initiated run receives:

- The complete current transcript, with segment IDs, timestamps, speaker IDs, and assigned names.
- The selected screenshots as images, with their timestamp/source manifest and useful local OCR where available.
- Meeting metadata needed to interpret the content and the selected recap language.
- A versioned recap instruction template and output schema.

Do not send raw audio, full video, unrelated meetings, or unrelated archive files. Do not silently truncate the transcript to satisfy a context limit. If necessary, use bounded, traceable processing passes that cover the complete transcript, then consolidate the recap while retaining source references.

### 10.3 Language

Default to the predominant spoken language of the meeting, estimated from speech-bearing segments rather than screenshot text or UI language. Allow the user to override this choice for each recap.

For a near tie or uncertain detection, show the proposed language before submission and use the preferred recap language from settings as the engineering fallback. Preserve proper names, code, and technical expressions where translation would distort them.

### 10.4 Required recap structure

| Section | Required content |
| --- | --- |
| Summary | A concise account of the meeting's purpose and outcome |
| Topics discussed | Main topics and relevant context, grouped clearly |
| Decisions | Decisions actually made, distinct from suggestions or unresolved discussion |
| Action items | Task, responsible person when explicit, deadline when explicit, and source reference |
| Open questions | Unresolved issues, missing information, and dependencies raised in the meeting |
| References | Traceable transcript timestamps/segment IDs and relevant screenshots |

Use the selected language for headings and prose. Do not invent decisions, owners, dates, participant identities, or agreement. Label missing owners/deadlines as unspecified and preserve uncertainty.

Store validated structured JSON and render a readable Markdown recap. A malformed, interrupted, or partial response must not replace an existing completed recap or be marked successful.

### 10.5 Job lifecycle

Show sending/running/completed/failed/cancelled status. Capture exit status and useful diagnostics without logging credentials or full meeting content indiscriminately.

Missing CLI, authentication failure, network failure, or model/input limits leave the local meeting intact. The user can retry explicitly after resolving the problem. Reopening the app or regaining connectivity must not start a new Codex job automatically.

Preserve previous completed recap versions. If the user edits the meeting while a job runs, associate its output with the submitted snapshot and mark it stale relative to newer edits.

## 11. Interface

### 11.1 Main window

- Meeting archive with title, date, duration, recording mode, and processing/recap state.
- Pre-recording controls for all applicable sources and settings.
- Recording view with timer, audio activity, transcription mode switch, source switching, Pause/Resume, and Stop.
- Realtime text only when that mode is selected; no speaker labels during capture.
- Meeting detail view with synchronized playback, editable archived transcript, speaker names, screenshot timeline/gallery, and recap.
- Manual “Send to Codex” action, visible readiness/failure state, recap language override, and access to the folder in Finder.

### 11.2 Menu bar

Provide quick Start, Pause/Resume, Stop, current recording duration/state, transcription mode switching, and access to the main window. The main window is not required to remain open while recording.

Do not present code, internal queue details, model tensor settings, or subprocess flags in ordinary recording controls. Technical diagnostics belong in settings or an explicit diagnostic view.

## 12. State, recovery, and resource scheduling

Keep recording/local-processing state separate from recap state. For example, a meeting can be ready locally and have no recap, or retain a successful earlier recap while a new manual run fails.

Suggested local states are `recording`, `paused`, `finalizing_media`, `finalizing_transcript`, `identifying_speakers`, `ready`, `interrupted`, and `processing_failed`. Recap states are `not_sent`, `running`, `completed`, `failed`, and `cancelled`, with a separate revision-based stale flag.

Persist durable media references, processing checkpoints, and state transitions atomically where appropriate. On relaunch, recover finalized media and resumable local processing. Never automatically resume microphone/screen capture or submit recovered material to Codex.

The initial recovery target is at most five seconds of unrecoverable audio after a forced process termination, subject to verification with the chosen recording format. A checkpoint must correspond to durable, decodable media.

Handle disk exhaustion, lost permission, capture source closure, device changes, and model/processing failure with explicit state and preserved material. If capture cannot continue safely, stop affected capture and finalize what is recoverable; do not claim that the recording remains healthy.

Prioritize active capture over post-processing older meetings. Persist queued local work, bound concurrent inference, and checkpoint/defer older inference if a new recording needs the memory budget. Run at most one heavyweight local model pipeline at a time. Codex operates after local processing and does not require keeping local inference models loaded.

## 13. Proposed technical architecture

| Area | Choice and status |
| --- | --- |
| Application | Swift, SwiftUI, and targeted AppKit integration |
| Visual/application audio capture | ScreenCaptureKit |
| Microphone/audio processing and media I/O | AVFoundation/Core Audio, with validated echo handling |
| Transcription | WhisperKit/Core ML; compressed multilingual Whisper large-v3-turbo, confirmed default |
| Speaker diarization | Pyannote community-1 through SpeakerKit/Core ML, conditional on bounded-memory validation |
| OCR and screenshot comparison | Apple Vision plus lightweight local image analysis |
| Archive | Versioned JSON/Markdown sidecars and media files; optional rebuildable local index |
| Recap integration | Foundation `Process` invoking the installed Codex CLI |

The runtime should be native; it does not require a Python/PyTorch service or a separate backend. Initial platform scope is Apple Silicon on the user's current macOS. An older macOS support floor is not a first-version product commitment; select API deployment targets when dependencies are pinned.

### 13.1 Model configuration and memory constraints

Use **compressed multilingual Whisper large-v3-turbo** through WhisperKit/Core ML, with the confirmed variant `large-v3-v20240930_626MB`, as the default for both transcription modes. The artifact's size is not its runtime RAM usage. Validate quality, latency, and memory for this chosen model; benchmarking alternative transcription models is outside the agreed implementation scope.

Pin SDK/model versions and record their identifiers. Verify redistribution/use terms for actual model weights. Model upgrades require repeat quality and resource evaluation rather than silently changing an installed meeting pipeline.

WhisperKit's documented default whole-file loading is inappropriate for long meetings. Use incremental loading or explicitly bounded audio windows. Use bounded decoder buffers and queues; an audio-processing backlog remains on disk.

SpeakerKit is a candidate, not an unconditional dependency decision. At the time of specification, upstream issue #551 reports growing peak memory with recording length in its default diarization path, including unbounded queued segmenter outputs. Validate the selected version and require backpressure, bounded concurrency, and incremental segmentation/embedding extraction. Do not assume invoking a whole-file API or independently diarizing short chunks satisfies memory and global speaker-consistency requirements.

If the selected SDK version cannot meet these constraints, integrate a bounded pipeline or evaluate another native local Pyannote-compatible implementation before adopting it. Do not weaken the local-processing requirement or move speaker recognition into the live capture path as a workaround.

### 13.2 Implementation boundaries

Separate capture/timeline management, media persistence, transcription, post-stop diarization, screenshot scheduling/detection, archive/revisions, and Codex jobs behind clear interfaces. Heavy work must stay off the main UI thread. UI state must be driven by actual capture/process completion, not by an optimistic timer.

## 14. Initial performance targets

These are **engineering targets to measure and adjust with evidence**, not benchmark claims. Measure on a 24 GB target configuration while a real conferencing application is active. Results from the 128 GB development machine alone are insufficient validation.

| Measure | Starting target |
| --- | --- |
| Idle app footprint | At most approximately 150 MB, with inference models unloaded |
| Steady recording/transcription footprint | At most approximately 2 GB across the app and its local workers |
| Post-stop local-processing peak | At most approximately 3 GB across the app and its local workers |
| Realtime text latency | Warm-pipeline p95 around 3 seconds or less to provisional text |
| Background transcript commits | Approximately every 20–30 seconds of speech |
| Local finalization after a two-hour meeting | Approximately 120 seconds or less, including final speaker attribution |
| Stable significant-change capture | Approximately 3 seconds after new content becomes stable |
| Crash recovery loss | At most approximately 5 seconds of audio |

Include capture buffers, optional video encoding, OCR, and native inference allocations in resource evaluation. Measure unified-memory pressure as well as process footprint, and report Codex process usage separately; excluding it from the app budget does not make its usage disappear.

Test video enabled and disabled, both transcription modes, and headset/speaker configurations. Models should be released after work completes. Memory must remain bounded across the two-hour workload instead of growing with media duration or queued frame/audio buffers.

Measure CPU/energy impact and conferencing audio glitches alongside latency. Favor the agreed balance of quality, speed, and limited RAM. Do not silently sacrifice transcript coverage or speaker consistency to meet a latency number.

## 15. Acceptance scenarios

The implementation must be exercised in the running macOS application, with real playback and captured output, rather than relying only on unit tests or a successful build.

1. **Three recording modes:** each captures precisely its applicable inputs. Audio-only in-person recording works without requesting screen capture. Presentation capture uses the selected Mac display/window.
2. **Online sources:** application-only and all-system audio choices behave as labeled, independently of the visual source. Test browser audio scope and switching/loss of selected sources.
3. **Devices and echo:** headphones, built-in speakers/microphone, and an external microphone work. Simultaneous local/remote speech is not duplicated or removed by echo handling.
4. **Transcription modes:** switch repeatedly in both directions during speech and silence. Verify continuous timestamps, no missing/duplicated content, and no loaded diarization pipeline or live speaker labels.
5. **Languages and speakers:** use Italian, English, code switching, technical names/numbers, and recordings ranging from one to ten speakers. Verify final meeting-wide identities after Stop. Report word error, diarization error, and speaker-attributed transcription error by scenario, including overlap/uncertainty.
6. **Screenshot schedule:** verify recordings shorter than, equal to, and longer than fifteen active minutes. Check retroactive odd-minute removal, two-minute alignment, pauses, and protection of dual-reason/change/boundary images.
7. **Visual changes:** test slides, scrolling, small meaningful code/output updates, source switching, clocks, cursors, transitions, and moving webcam grids. Review missed useful content and unnecessary captures against labeled examples.
8. **Video:** enable before Start, record through pauses and source changes, and verify audio/video synchronization, playable output, and resource bounds. With video disabled, no full-video file is created.
9. **Archive and edits:** reopen an app-created meeting without recording again, correct text and speaker names, retain automatic originals, seek from timestamps, and verify Markdown/JSON persistence across relaunch.
10. **Manual Codex boundary:** Stop, finalization, archive opening, text edits, relaunch, and connectivity changes invoke no Codex job. Only pressing “Send to Codex” or an explicit retry/regeneration initiates one.
11. **Recap correctness:** inspect the exact submitted transcript revision and selected images. Verify predominant/overridden language, required sections, explicit owners/deadlines, source references, and no invented decisions. Edits during a run must not silently relabel its output as current.
12. **Failure and recovery:** test forced termination, low disk, source/device loss, denied permissions, inference failure, missing/auth-failing CLI, network failure, malformed recap, and cancellation. Media/originals and prior valid recaps remain recoverable.
13. **Two-hour workload:** run representative online and in-person workloads under a 24 GB memory envelope, measuring steady/peak memory, delay, finalization time, UI responsiveness, synchronization drift, and capture continuity.

## 16. Required validation before fixing technical defaults

Product behavior above is decided. The following engineering choices still require implementation evidence:

- Pinned WhisperKit SDK/model revisions for the chosen `large-v3-v20240930_626MB` variant, multilingual decoding configuration, and realtime/background window settings.
- A diarization implementation that meets global identity consistency and bounded-memory requirements on two-hour audio.
- Echo handling that preserves local speech with speaker playback and the supported input devices.
- Significant-change thresholds, ignored-region behavior, screenshot readability, and Codex image-selection budget.
- Durable recording containers/segmentation and demonstrated crash recovery.
- Installed Codex compatibility, model image support, input limits, constrained subprocess behavior, and structured-output validation.
- Achievable quality, latency, and memory thresholds on the target configuration, with explicit evidence for any proposed target changes.

## 17. References and research notes

- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) — native visual/audio capture, filtering, and sample-buffer handling.
- [Argmax Open-Source SDK / WhisperKit / SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) — native Core ML transcription/diarization, model variants, and incremental audio loading.
- [SpeakerKit issue #551](https://github.com/argmaxinc/argmax-oss-swift/issues/551) — upstream report of duration-dependent diarization memory growth; verified open during specification research. It is an upstream report, not a benchmark performed for this application.
- [OpenAI: Codex exec](https://learn.chatgpt.com/docs/developer-commands#codex-exec) — non-interactive CLI execution. Relevant installed options were also checked with `codex exec --help`; no meeting recap job was executed during specification work.
