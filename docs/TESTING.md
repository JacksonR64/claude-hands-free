# Validation and trial guide

## Automated checks

From the checkout on macOS with Xcode Command Line Tools, Python 3 and a mod-capable Claude Code host:

```sh
sh scripts/check.sh
```

The script selects a compatible installed host without changing the user's CLI, runs Python tests, validates the plugin, runs tests in the actual host's mod test runner, compiles native helpers, and executes panel assertions in demo mode. Model/process interfaces in mod tests are mocked; no paid model prompt is submitted. Build products stay in ignored `work/`.

Python-only checks can also run without Claude or macOS:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

On 27 October 2026, the full 0.7.0 check passed on the M5 MacBook: 12 Python tests, 7 host mod tests, native compilation and panel assertions. It covers atomic/private IPC, expiry, order, exact instance/request identity, launcher quit guards, rollback-safe Applications links, question result shape, conservative permission handling, idle registration, voice parsing, ambiguity, stale destinations, presentation, audio feedback, endpointing, demo routing/timeout and playback freshness. Both app bundles and both listener bundles passed deep, strict code-signature verification. A failing prerequisite is not a passing integration check.

## Current evidence

| Area | Evidence | Still pending |
| --- | --- | --- |
| Host routing | Actual mod runner checks with mocked host services; earlier local live session registration and read receipt without a model prompt | Full live conversation/question/permission trial |
| Microphone | Earlier demo captured real buffers/recognised words; Jackson confirmed recognition worked | 0.7.0 live capture, accuracy, endpoint timing and device changes |
| UI | Previous demo Stop/Quit/reopen inspected; installed 0.7.0 live window visibly showed microphone off, Stop/Quit and four registered sessions; settings menu present | Live Stop/Quit with capture active, multi-display, crowded menu bar and sleep/wake testing |
| Playback | Local system synthesis/rendering succeeded; demo uses owned file playback | Gurgling cause and audible before/after comparison |
| Interruption | Routing callback and preference assertions | Acoustic barge-in with headphones; speakers/music |
| Distribution | Locally built, ad hoc signed app with embedded listener | Fresh-machine installation, Intel, notarisation and public binary release |

## Safe manual demo trial (no Claude usage)

1. Open `~/Applications/Claude Hands Free Demo.app`. Confirm visible window, menu-bar/Dock entry and Microphone off.
2. Select Captions or Both. Click Test speaker first; check audible quality independently of capture.
3. Explicitly enable the demo microphone and grant only its requested permissions. Confirm arriving input levels and recognised words; a macOS mic indicator or `ready` event alone is insufficient.
4. Answer its scripted question, say “next session”, “ask me a question”, and “read again”. Wait for speech to end with interruption off. Check selected session and both caption lanes.
5. Say “stop listening”. Also verify visible Stop demo and Cmd+. without relying on voice recognition. The demo auto-stops after two minutes.
6. Hide/close, reopen from Dock, Quit/Cmd+Q, then relaunch. Confirm capture and reply stop and microphone remains off. Do not leave a trial running.

## Live trial (Claude usage required)

1. Run local checks/install, then `/reload-plugins` in two harmless Code sessions that load read-aloud. Give them distinct names in the controller.
2. Open `~/Applications/Claude Hands Free.app`, select one session and explicitly enable its microphone. Grant the live listener's own permissions if requested.
3. Dictate a harmless message; compare the caption with the received prompt and queued/started receipt. Switch by name and by next/previous, checking the heading each time.
4. Use an ordinary question to test `AskUserQuestion`. For permission testing use a reversible local operation in a disposable directory. “Yes” must never approve a tool action; “deny action” must decline only the displayed request. Test explicit approval only when intentionally authorised.
5. Change selection during an utterance; expect rejection/repetition rather than delivery to the new session. Check queued-message behaviour while Claude is busy.
6. Stop speech, stop working, stop listening and Quit separately. None of these undoes completed tool actions. Check that future session activity cannot reopen a controller explicitly quit.

## Failure evidence to record

Record version/commit, host version, macOS/input/output devices, interruption setting, exact expected/observed behaviour and approximate timing. Share only a short redacted excerpt if needed. Runtime logs/captions can contain private session text; keep full logs and backups out of GitHub.

If capture stalls, inspect the meter, input name, last buffer time and recognition state before restarting the microphone. Local ad hoc rebuilds may require refreshing that helper's existing Speech Recognition permission in System Settings. Do not reset all Mac permissions, edit TCC databases, kill unrelated audio processes or infer hardware failure from accumulated swap.
