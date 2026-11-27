# Changelog


## Window reader (free route), 27 November 2026

- The Sender helper gained a watch mode (`--watch <dir> <panel pid>`). Every two seconds it writes what the Claude desktop window shows to `claude-window.json`; the panel reads new Claude replies from it aloud and lists them under "waiting on you". No thread has to do anything, so it costs no usage.
- It sees only the project chat and thread that are on screen. First sight of a chat is a silent baseline. A drop for the same thread within 90 seconds is treated as the same message.
- Setting `watchWindow` (default true). The panel shows an orange note until "Claude Hands Free Sender" is allowed under Accessibility.

## Unreleased

- **Project threads.** Cloud project threads cannot load the mod, so they drop one small JSON file per message into an inbox folder on the Mac (`threadInbox` in `~/.config/read-aloud/settings.json`, default `~/.cache/read-aloud/threads/inbox`). The app reads each one aloud itself, with the project and thread name first, through the same one-voice-at-a-time lock the sessions use.
- **Numbered waiting list.** Threads that need an answer, and sessions with a pending question, share one numbered "Waiting on you" list in the panel. A number stays with its item until it is answered or dismissed. Voice: "who's waiting", "read number two", "open number two", "dismiss number two", and "reply to number four, …" (or "reply to number four", a tone, then the message).
- **Replying to a thread.** A new helper, Claude Hands Free Sender, opens the thread's link in the Claude desktop app, checks the page address and the reply box, pastes the words, checks they arrived and presses Return, so the reply is an ordinary message from the user. It needs the macOS Accessibility permission and is rebuilt only when its own source changes, so the permission survives other updates. The clipboard is put back afterwards.
- The microphone is also gated while the app itself is speaking.

- Fix: the microphone helper never showed macOS's Speech Recognition / Microphone permission prompt (it sat at "Waiting for…"), because a background app is never frontmost. It now comes to the front while asking, then goes back to the background. `read-aloud-listen --status` prints the current permission state without asking or recording.
- Fix: the embedded listener crashed ("Read Aloud Conversation quit unexpectedly") as soon as macOS tried to show the permission prompt, because macOS reads the usage descriptions from the outer app, whose Info.plist had none. Both panel apps now carry the Microphone and Speech Recognition descriptions.
- Fix: with "Wait before reading replies" on, the in-chat band said "Queued to read aloud" with nothing to press. It now says "Ready to read aloud" with a Read now button (the panel's Read reply button did the same for the selected session).
- Fix: long dictation was cut into pieces. Any pause over a second sent the message, and the recogniser's 45-second limit sent the first part on its own. Words now carry across recogniser restarts, and a visible countdown (default 5 s, `sendDelay` in `~/.config/read-aloud/settings.json`, 0 sends at once) runs after you stop talking: more speech cancels it, **Send now** skips it and **Cancel** discards the message.
- One reader, one off switch: reading now only happens while the app is running and **Read replies aloud** (panel settings) is on, so quitting the app silences everything, including replies from other sessions and the cloud relay. Quitting while something is being read stops it.
- The cloud-thread relay no longer speaks on its own. It hands each comment to the app's inbox (`@name:` header, taken from a leading `[Thread title]` or "Cloud thread"), so those replies use the same queue, panel, names and settings as local sessions. Inbox items older than 10 minutes are dropped.
- Dictation now starts only with the wake phrase ("okay Claude …"); saying just the phrase arms the next utterance for 8 seconds. Commands ("next session", "pause", "approve action") need no wake phrase and skip the send countdown. `requireWake: false` in settings restores dictating without it.
- Optional **Handy** dictation (panel settings → Dictation → Handy, shown when Handy is installed). "Okay Claude, dictate" starts Handy through its command line, a pause ends the recording, and the app reads the transcript from Handy's history database and sends it after the usual countdown. Set Handy's Paste method to None so it doesn't also type into the front app. With Apple dictation the same phrase arms the next sentence as a message.
- With **Read replies aloud** off, the panel also tells any session that is still reading to stop, so sessions running an older copy of the mod (started before the setting existed) go quiet too. Reload the plugin in those sessions to get the setting itself.
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
