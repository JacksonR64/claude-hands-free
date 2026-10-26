# Claude Conversation

Personal macOS voice controller for existing Claude Code sessions, built on the read-aloud mod. Jackson authorized the MVP build on 25 October 2026.

- Current status and handoff: PROGRESS.md. SESSION_PROMPT.md retains the original research brief; its research-only restriction was superseded by Jackson's explicit build request.
- Edit source in mod/. The installed ~/.claude/mods/read-aloud is a deployment target; back it up before changing it.
- Keep the mod's MIT attribution. No publication, Reddit posts, hosted infrastructure or paid test calls without user authorization.
- Use the generated mod types matching the Claude Code host. The Homebrew claude may be older than Desktop's embedded binary.
- Bind speech, delivery receipts and approval responses to a specific session instance and pending request. Ambiguous names must not select a session silently.
- Verify with local tests and compilation. Passing tests do not establish microphone quality, live host behaviour or a successful user trial.
- Default to a menu-bar icon. Floating and screen-edge presentations are optional; new activity must not override an explicit Hide or Quit. Keep a simulation mode usable without Claude credits, including real local microphone input and spoken replies. Isolate its transcripts and processes from live sessions.
