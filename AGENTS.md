# Claude Hands Free

Personal macOS voice controller for existing Claude Code sessions, built on the read-aloud mod. Jackson authorized the MVP build on 25 October 2026 and public GitHub source publication on 27 October 2026.

- Start with tracked docs/HANDOFF.md, TASKS.md and docs/TESTING.md. Update these when behaviour, validation or priorities change, so Claude and Codex share the same context. CLAUDE.md imports this file. Ignored PROGRESS.md is the local historical log, not the only handoff. Ignored SESSION_PROMPT.md is the superseded original research brief.
- Edit source in mod/. The installed ~/.claude/mods/read-aloud is a deployment target; back it up before changing it.
- Keep the mod's MIT attribution. No publication, Reddit posts, hosted infrastructure or paid test calls without user authorization.
- Public source publication is authorized for this project. Keep backups, logs, transcripts, session data, generated host types and personal machine paths out of Git history. Public binaries, marketplace distribution and Reddit promotion are separate from this source publication.
- Use the generated mod types matching the Claude Code host. The Homebrew claude may be older than Desktop's embedded binary.
- Bind speech, delivery receipts and approval responses to a specific session instance and pending request. Ambiguous names must not select a session silently.
- Verify with local tests and compilation. Passing tests do not establish microphone quality, live host behaviour or a successful user trial.
- Keep measured microphone input and playback activity visible. Distinguish permission/startup, arriving audio and recognised speech; a ready event alone is not proof of a working hands-free loop.
- Keep the demo discoverable in the Dock and menu bar, with an obvious stop control. Hiding the demo stops its audio; microphone trials are bounded. Leave its microphone off after installs and recovery work unless Jackson explicitly starts another trial. Do not echo unscripted background speech aloud.
- Both controllers start with microphone off. Preserve the single-controller lock, listener-owner watchdog, explicit stop controls and Dock recovery. Live Hide can keep an explicitly enabled microphone running; make that visible. Demo Hide stops it. Do not enable either microphone automatically for verification.
- Default to a menu-bar icon. Floating and screen-edge presentations are optional; new activity must not override an explicit Hide or Quit. Keep a simulation mode usable without Claude credits, including real local microphone input and spoken replies. Isolate its transcripts and processes from live sessions.
