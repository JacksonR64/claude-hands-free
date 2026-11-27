# Development priorities

Updated 27 October 2026. Ship local reliability before general distribution. See [handoff](docs/HANDOFF.md) for context and [testing](docs/TESTING.md) for acceptance steps.

## Next: project threads trial (added 27 November 2026)

- [ ] Grant Accessibility to Claude Hands Free Sender, then with the microphone on try "who's waiting", "read number one" and "reply to number one, …" against a real thread. Record what was heard and what arrived.
- [ ] Confirm threads in other projects drop files (account skill `hands-free-drop`) and that names are spoken clearly.
- [ ] Clear a waiting thread automatically when the user answers it by typing.

## Then: bounded hands-free trial on the M5 MacBook

- [ ] Run a short scripted demo trial with captions and measured input visible. Check Stop, Quit, Dock reopening and mic-off launch. Record user observations; do not silently restart listening.
- [ ] Measure end-of-speech to final transcript and final transcript to response start. Tune the existing endpoint only from observed examples of slow responses or split sentences.
- [ ] With Claude usage available, test two harmless live Code sessions: naming, switching, normal message, question answer and explicit request-bound deny/approve. Never use a physical tool as the approval test.
- [ ] Compare built-in speakers with headphones, then background music. Keep interruption off until testing headphones. Record echo, false positives and timing separately.
- [ ] Reproduce gurgling using Test speaker and unrelated Mac audio. Capture a short diagnostic window before assigning a hardware cause. File rendering is not a proven fix.
- [ ] Check screen changes, menu-bar crowding, secondary monitor removal, sleep/wake, live Hide while listening and explicit Quit while work is still completing.

## Then: make the source easier for others to try

- [ ] Test a fresh account/machine with no existing read-aloud loader; document the compatible host/mod loading path from actual evidence.
- [ ] Test supported macOS versions and Intel separately; native compilation on Apple Silicon does not establish either.
- [ ] Decide stable bundle identifiers and a signing/notarisation strategy before a public binary release. Check permission persistence across signed upgrades.
- [ ] Define update/uninstall and runtime-data cleanup behaviour. Keep a rollback path and do not remove unrelated plugin settings.
- [ ] Add CI for checks that can run without a proprietary authenticated host. Keep full host integration checks as an explicit local requirement until they can run honestly in CI.
- [ ] Prepare a short demonstration and portfolio/Reddit text only after the workflow is repeatable. No posting is part of the current build.

## Routed to-do from Jackson's list (2026-11-24, via brainZ)

- [ ] Investigate how to correct the words Handy consistently transcribes incorrectly (source `/Users/jacksonrhoden/Downloads/No Usage Todo/No Usage Todo - Cleaned.md`, line 28). brainZ's guess is this belongs here; if it belongs with brainZ, tell brain2. First step: collect the repeat mis-transcriptions (diff the raw export `No Usage Todo.md` against the cleaned file in the same folder) and check whether Handy supports a custom vocabulary or post-replace list. Not started.

## Completed foundations

- [x] Persistent multi-session registry, explicit selection and unique voice names.
- [x] Request/instance-bound delivery, receipts and conservative permission handling.
- [x] Menu-bar/edge/floating UI with persistent Hide/Quit.
- [x] Offline spoken demo, input feedback, captions and bounded demo listening.
- [x] Discoverable Stop/Quit and Dock recovery in both controllers.
- [x] Live capture path aligned with the working demo; playback gating and owner watchdog.
- [x] Bundled listeners, local installer backups and rollback-safe Applications links.
- [x] Tracked architecture, testing and Claude/Codex handoff documentation.
