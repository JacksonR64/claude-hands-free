# Claude Conversation

A personal macOS voice controller for existing Claude Code sessions. A menu-bar icon opens a panel showing which conversation receives your speech and which others are working or waiting for an answer.

Built from the **read-aloud** mod, retaining its MIT license and attribution. This is an early local MVP, with no hosted service or separate model account.

## What it does

- Keeps connected sessions visible after they finish a reply.
- Selects a conversation by name, or moves to the next/previous session.
- Sends ordinary speech to the selected session as your own message.
- Shows whether Claude is working, ready for a follow-up, asking a question, or requesting permission.
- Sends answers through `AskUserQuestion` and approves or denies an individual permission request through its actual hook.
- Separates stopping speech from stopping a running turn.
- Displays queued, started and failed delivery receipts.
- Recognises speech on the Mac. It refuses to start if on-device recognition is unavailable.

## Requirements

macOS 14+, Python 3, Xcode Command Line Tools (`swiftc`), and a Claude Code host at **2.1.308 or later** that supports mods. Desktop can bundle a newer host than the shell's `claude`; the scripts look for a compatible installed host without upgrading it.

Claude Code remains responsible for authentication, tools, context and model usage. The optional existing “Natural spoken rewrite” uses a small model through your Claude session and consumes its normal usage. Turn it off in the panel to speak cleaned text without that extra pass. Speech recognition uses Apple's local engine, and playback uses `say`/`afplay`; no audio service or API key is added.

## Local setup

```sh
sh scripts/check.sh
python3 scripts/install.py
```

The installer validates and compiles before replacing `~/.claude/mods/read-aloud`, backs up the previous source, compiled helpers and read-aloud settings under ignored `work/backups/`, and leaves the microphone off. It retains other settings. It does not change Claude's plugin-loading configuration or modify the Claude application.

If read-aloud was already loaded globally, run `/reload-plugins` in each Claude Code session you want to use. Otherwise load this project's `mod/` as a local plugin using a compatible host's `--plugin-dir` option. Only sessions that load the mod participate. A normal Claude/Projects chat is not a Code session and will not appear.

The helper app is built at `~/.cache/read-aloud/ReadAloudConversation.app`. Open it, then click its waveform icon in the menu bar. Choose a session, then click the microphone. macOS may ask for Microphone and Speech Recognition permission for **Read Aloud Conversation**. Existing hotkeys still use the read-aloud Accessibility permission.

## Keep it out of the way

The panel's **…** menu offers three presentations:

- **Menu bar** (default): a single icon; click to open or dismiss its popover.
- **Screen edge**: a small tab on the left or right of the screen.
- **Floating icon**: a small icon at the panel's last floating position.

The two compact presentations expand on click, optionally on hover, and collapse after eight seconds without pointer or keyboard interaction. Disable hover or idle collapse in the same menu if preferred. **Pop up for new activity** is off by default; when enabled, new questions, permissions and completed replies can expand the panel once per event.

**X**, Escape or **Hide** removes both the panel and compact tab until you click the menu-bar icon. Background updates do not undo Hide. **Quit · stop background relaunch** also switches the microphone off and blocks automatic launches from later session starts. To resume after Quit, explicitly open `ReadAloudConversation.app`, then use its menu-bar icon. Reload the plugin in existing sessions after installing this version so they use the updated launcher.

## Test without Claude usage

Open `~/.cache/read-aloud/ReadAloudDemo.app` after installation, or `work/build/ReadAloudDemo.app` after running the checks. It has a ladybird menu-bar icon and opens visibly so you can find the sandbox. It uses separate UI preferences and fake sessions; its microphone and real session IPC are disabled.

Try the presentation options, Hide, hover and idle collapse. Type **next session**, **move to printers session**, or an ordinary answer into **Simulate speech**, then press Return. **Question**, **Approval**, **Finished** and **All quiet** simulate session activity. **Reset demo** restores the sample sessions. The text field exercises the transcript routing after recognition; it does not test microphone accuracy. Simulated approvals execute nothing and consume no Claude usage.

## Try it

Give sessions short voice names by right-clicking their rows, for example **Printers**, **Website** and **Home Assistant**.

1. Choose a session and enable the microphone.
2. Speak a normal message and pause. Check its delivery receipt.
3. Say “okay, next session” or “switch to the printers session”. The heading changes and its latest answer or pending request is read.
4. Answer questions naturally. For a permission request, say exactly “approve action” or “deny action”. An ordinary “yes” never grants a tool permission.
5. Say “stop speaking” to cut playback, or “stop working” to cancel that session's current turn. Completed actions are not undone.

“Previous session”, “open chat”, “read again” (button), and “cancel message” are also available. Session names must match exactly or as a unique phrase. Ambiguous matches leave selection unchanged.

A session/request is pinned when recognition first produces speech. If it changes before the final transcript arrives, the message is rejected for repetition instead of being redirected. A message submitted while Claude works is queued until that turn finishes. Queued prompts are not immediate mid-turn steering. One voice message can await its turn per session; another gets an explicit rejection until that queued message starts.

## Roll back

The last backup location is in ignored `work/last-backup.txt`:

```sh
python3 scripts/install.py --rollback "$(cat work/last-backup.txt)"
```

Reload the plugin afterwards. Backups are local and may contain personal settings; do not publish `work/`.

## How it fits together

- `mod/hooks/register.tsx`: a mod in each Code session; lifecycle state, message delivery, questions, permission requests and spoken replies.
- `mod/bin/bar.swift`: the native SwiftUI menu-bar popover, compact panels, selection, simulation and delivery state.
- `mod/bin/listen.swift`: on-device recognition and silence-based turn detection, active only with the microphone enabled.
- `mod/bin/VoiceCore.swift`: command parsing, session matching and destination checks.
- `mod/bin/bridge.py`: atomic IPC in a user-private directory, with instance/request binding, expiration and receipts.

The control directory `~/.cache/read-aloud/conversation/` contains session labels, current speech captions, command/response files and a local transcript-event log (`voice.log`, reset when the listener starts). This MVP does not record audio. Existing read-aloud temporary speech files still use `/tmp/read-aloud`. Quit the panel to turn its microphone off.

## Validation and current limits

`sh scripts/check.sh` runs Python bridge/launcher tests, the actual Claude mod test runner, native compilation, and panel routing/presentation tests with simulated sessions. No test calls a paid model, operates a printer, or sends a task to another chat. A `--demo` launch of the panel also enters the offline sandbox.

Automated checks cover destination changes, duplicate/ambiguous names, expired sessions and commands, request-bound responses, approval denial on error, preservation of prior permission decisions, actual question result shape and idle session registration.

Live microphone accuracy, echo cancellation, natural pauses, hardware changes and in-app end-to-end conversation still require a real user trial. Speech currently uses a silence threshold, not a conversational audio model; long pauses can split a thought. The controller supports main-session `AskUserQuestion` and `PermissionRequest`; it does not surface every possible connector login/elicitation or subagent question. Voice requests time out after five minutes without approving anything. Choosing a question option by button is single-choice; multiple selections can be spoken together.

Mods are an early-access API. Changes in the host may require updates. Ordinary Claude Desktop/Projects conversations, cold-starting arbitrary closed chats, wake-from-sleep use, and a public distribution package are outside this MVP.

The GitHub/release and Reddit/portfolio presentation remain future work. Nothing is published by the build or install scripts.
