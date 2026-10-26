# Known issues and investigations

## Realtime transcription after switching an active recording

- Reported by the user on 26 October 2026 during the live application test.
- Started a recording in background transcription mode, switched to Realtime without stopping, and spoke “uno due tre prova”. The expected text did not appear.
- Status: **underlying audio-conversion defect reproduced and corrected in source; live switch verification pending**.
- Preserve and inspect the local captured microphone audio and transcript cursor around the switch. Do not submit these real test recordings to Codex.
- Acceptance for a fix: start in background mode, switch to realtime during capture, speak a recognizable phrase, verify it appears with a continuous timestamp, switch back and repeat. Compare saved audio with the transcript, and repeat across Pause/Resume.

Valid five-channel microphone PCM was present in the original CAF files, but the previous AVAudioConverter channel remapping produced an entirely silent mono inference signal. This affects transcription before and after a mode switch. Explicit channel mixing before resampling now preserves the signal; speech level adjustment runs only on derived inference audio. Originals remain unchanged.

Reprocessing the same 254.5-second real test recording locally after this correction recovered nine segments, including the reported phrase at approximately 6.72, 9.72, 12.68, 25.52 and 33.54 seconds. The diagnostic output stays in ignored local files. An automated regression test covers a discrete five-channel microphone with speech only in its last channel.

At the user's pause request, the correction had passed the test suite but had **not yet been installed in the bundled app**. The exact live mode-switch scenario remains an acceptance task. See `DEVELOPMENT_STATE.md` for the resume point.
