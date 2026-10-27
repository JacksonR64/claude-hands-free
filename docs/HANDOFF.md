# Development handoff

Updated 27 October 2026. Current source version: **0.7.0**, early macOS prototype. Start here when continuing in Claude Code or Codex. This file is tracked; no assistant's private memory is needed to understand the project.

## Product and scope

Jackson wants to leave the keyboard alone while several existing Claude Code sessions work: hear a reply, answer a question, say “next session” or “switch to the printers session”, and continue in the selected conversation. Keep waiting quiet. The panel should show who receives speech and who needs attention without taking over the screen.

The project combines a Claude Code mod with a native macOS companion app. It uses the user's existing Claude session and usage. It is not a separate agent backend and does not integrate ordinary Claude Desktop/Projects chats. Jackson's current direction is an MIT open-source portfolio project, local reliability first, broader distribution later. No monetisation work is planned.

## What exists

- The live mod registers idle and busy sessions, publishes pending questions/permissions, receives request-bound commands and delivery receipts, and submits messages as user-origin prompts. It retains the original read-aloud speech playback, captions, hotkeys and optional cadence rewrite.
- Native SwiftUI controller offers menu bar, screen edge and floating presentations. Explicit open/Dock recovery shows a visible window. Background starts respect Hide and persistent Quit. Dock presence is on by default and can be disabled in settings.
- Apple on-device English speech recognition produces begin/partial/final events. Speech is pinned to the selected session instance and pending request at its first result. A changed destination rejects delivery for repetition. Ordinary messages queue until idle; one can be queued per session.
- Both apps start with microphone off. Stop listening/Cmd+. stops capture and requests current speech to stop. Quit/Cmd+Q stops the helper and blocks automatic controller relaunch. Live Hide keeps an explicitly enabled mic running; the UI states this. Demo Hide stops audio.
- Input meter measures actual microphone buffers. Captions show recognised text and assistant output. Waveform / Captions / Both are available. Captions do not invoke another model or recogniser.
- Scripted offline demo has separate preferences, processes and IPC, speaks using system voices and never calls Claude. Demo microphone trials end after two minutes. Unscripted background speech is captioned without automatic spoken echo.
- Installer validates, compiles, snapshots the previous mod/helpers/settings, installs with microphone off, and creates links in `~/Applications` without replacing unrelated apps. Rollback removes only links that snapshot created and still owns.

## Latest changes: 0.7.0

The interrupted work after 0.6.0 survived as uncommitted source and was completed. Live capture now uses the raw input path that worked in the demo; the previous voice-processing path had produced DSP errors and stalled demo capture. Default recognition is gated while fresh live session state reports playback. Paused, stale and implausibly future playback states cannot hold the mic gate indefinitely. Headphone interruption is opt-in in both apps; acoustic effectiveness is not established.

Added real-app Dock visibility, standard app-menu Stop/Quit shortcuts, explicit Dock reopening even after a background start, and a per-state-directory controller lock. The listener requires a living controller owner before requesting permissions/starting capture and exits if that owner dies during capture. It does not use a launch agent or login item.

Both app bundles embed their respective listener app and prefer it over the legacy cache location. Builds target the machine's architecture with macOS 14 deployment metadata. A locally compiled Apple Silicon app is not evidence of Intel or macOS 14 runtime compatibility. Signing is ad hoc, without Apple notarisation.

The completed build was installed on the M5 MacBook. Its live window visibly showed microphone off, both stop/quit controls and four registered Code sessions. No microphone or paid model prompt was used for this verification. Deep signature checking caught a stale executable from an earlier demo bundle; the build now removes it, the installer replaces generated bundles completely, and every build verifies all four bundle signatures.

## Source, installation and state

The Git checkout is authoritative. Edit `mod/`, then run `sh scripts/check.sh` and `python3 scripts/install.py`. Do not edit only the installed copy.

| Location | Purpose | Publish? |
| --- | --- | --- |
| `mod/hooks/register.tsx` | Host integration and speech scheduling | Yes |
| `mod/bin/` | Native UI, recognition, IPC and build scripts | Yes |
| `scripts/`, `tests/`, `mod/tests/` | Local tooling and checks | Yes |
| `docs/`, `TASKS.md`, `AGENTS.md`, `CLAUDE.md` | Shared development context | Yes |
| `~/.claude/mods/read-aloud/` | Installed mod; deployment target | No |
| `~/.cache/read-aloud/` | Built helpers and runtime state | No |
| `~/.config/read-aloud/settings.json` | Personal settings | No |
| `work/` | Build output, logs, backups and last-backup pointer | No |
| `PROGRESS.md`, `SESSION_PROMPT.md` | Local historical narrative/research | No |

`CLAUDE.md` imports `AGENTS.md`, which points here. Open the checkout in Claude Code and ask it to read these files. Claude does not need the Codex conversation history. Machine-specific historical backups remain in the ignored local log.

The installer does not change plugin-loading configuration. Existing sessions need `/reload-plugins`. New users must load `mod/` with a compatible host's `--plugin-dir`. Desktop's embedded host can be newer than the shell CLI; `scripts/host.py` selects an installed host at least 2.1.308. The project does not download or upgrade Claude.

## Evidence and limits

See [TESTING.md](TESTING.md) for the current test record and manual trial. Automated routing/approval tests run in Claude's actual mod test runner with mocked model and process interfaces. They prove those tested contracts, not live acoustic performance.

Jackson confirmed the demo could recognise him after capture/permission fixes. He reported slower turn detection and gurgling, then a hidden demo that kept listening. Recovery work stopped it and added visible controls and bounded capture. The final faster endpoint, the transferred live capture path, headphones/music behaviour, and live question/approval conversations still need user testing. Never present compilation or a `ready` event as proof of a complete hands-free conversation.

Gurgling is unresolved. Rendering speech to a file before playback avoids coupling synthesis and playback, but no before/after listening comparison established a fix. A short CPU/memory sample did not establish hardware failure. Locally signed rebuilds can need macOS permission refresh; no global permission resets or TCC database changes should be made.

Do not spend Claude usage, enable a mic, send real task prompts, or exercise physical tools just to get a green test. A real conversation needs available Claude usage and Jackson's spoken trial. The offline demo remains usable without it.

## Continue development

Read [TASKS.md](../TASKS.md), start with the bounded manual trial, and record observed transcript/timing separately from hypotheses. Keep fixes small, maintain the existing flows and isolate demo state. Implementing a second backend, rewriting the UI or distributing unsigned public binaries is not the next milestone.

For a Claude handoff prompt: “Read AGENTS.md, docs/HANDOFF.md, TASKS.md and docs/TESTING.md. Check git status and current installation before changing anything. Continue the local reliability milestone. Keep microphones off until I start a trial; do not use paid test calls without asking. Edit the checkout, test it, install with a backup, and update the tracked handoff.”
