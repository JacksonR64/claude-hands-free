# Changelog

## Unreleased

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
