# Changelog

## Unreleased

- Fix: the microphone helper never showed macOS's Speech Recognition / Microphone permission prompt (it sat at "Waiting for…"), because a background app is never frontmost. It now comes to the front while asking, then goes back to the background. `read-aloud-listen --status` prints the current permission state without asking or recording.
- Fix: the embedded listener crashed ("Read Aloud Conversation quit unexpectedly") as soon as macOS tried to show the permission prompt, because macOS reads the usage descriptions from the outer app, whose Info.plist had none. Both panel apps now carry the Microphone and Speech Recognition descriptions.
- Fix: with "Wait before reading replies" on, the in-chat band said "Queued to read aloud" with nothing to press. It now says "Ready to read aloud" with a Read now button (the panel's Read reply button did the same for the selected session).
- Fix: long dictation was cut into pieces. Any pause over a second sent the message, and the recogniser's 45-second limit sent the first part on its own. Words now carry across recogniser restarts, and a visible countdown (default 5 s, `sendDelay` in `~/.config/read-aloud/settings.json`, 0 sends at once) runs after you stop talking: more speech cancels it, **Send now** skips it and **Cancel** discards the message.
- The expanded card now tucks back into its icon about two seconds after it opens untouched, or one second after the pointer leaves, with a short shrink-and-fade (not with Reduce Motion).
- Fix: with voice on, questions and permission prompts waited up to five minutes on the voice bridge and then denied if no controller panel was running. The mod now checks the panel's lock (`bridge.py alive`) and leaves the prompt to the host's own UI when nobody can answer.

## 0.7.0 — 27 October 2026

- Carry the working demo capture path, captions and optional headphone interruption into the live controller.
- Gate recognition using fresh playback state; require a living controller owner for microphone capture.
- Add live Dock recovery, Stop/Quit app-menu controls and a single-controller lock.
- Embed microphone helpers inside both app bundles; target macOS 14 for native builds.
- Add rollback-safe Applications links, with microphone off after launch/install.
- Publish shared architecture, validation, backlog and Claude/Codex handoff documentation.

Live speech reliability, acoustic interruption and gurgling remain under investigation. This is a source prototype, not a finished public binary release.

## 0.6.0 — 27 October 2026

- Measured input feedback and Waveform / Captions / Both display.
- Faster endpointing, demo file-based playback and opt-in headphone interruption.
- Visible demo Dock/menu-bar controls, Stop/Quit shortcuts, mic-off launch and two-minute capture limit.
- Stop hidden demo audio and avoid speaking unscripted background input back aloud.

## 0.5.0 — 26 October 2026

- Isolated hands-free offline demo using local Apple recognition and system speech, without Claude calls.

## 0.4.0 — 26 October 2026

- Compact menu-bar, edge and floating modes; opt-in expansion; persistent Hide/Quit.
- Typed offline UI sandbox.

## Initial MVP — 25 October 2026

- Multi-session registry, voice selection, queued prompts and delivery receipts.
- Request-bound question/permission handling and native macOS controller, extending the MIT read-aloud mod.
