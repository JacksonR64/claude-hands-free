#!/bin/bash
# Starts the always-on Claude Hands Free worker: one Claude Code session, Remote Control on,
# hidden in its own tmux session. Idempotent: does nothing if that tmux session already exists.
# Settings: env vars, or ~/.config/claude-hands-free/worker.env (sourced; same names):
#   HF_WORKER_NAME   session name in ListAgents / the Claude app  (default "Claude Hands Free worker")
#   HF_WORKER_TMUX   tmux session name                            (default hands-free)
#   HF_WORKER_DIR    folder the session works in                  (default this repo)
#   HF_WORKER_BRIEF  first prompt                                 (default scripts/worker-brief.md)
#   HF_WORKER_EXTRA  optional extra brief appended to it, e.g. your own mailbox instructions
#   HF_WORKER_RULES  system-prompt rules appended to every turn    (default scripts/worker-rules.md)
#   HF_WORKER_ESCALATE how the worker reaches you; replaces {ESCALATE} in the rules
#                    (default: write a note file under ~/.local/state/claude-hands-free/for-owner/)
#   HF_WORKER_TRUST  1 = mark HF_WORKER_DIR trusted in ~/.claude.json (backed up first); default 0
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${HF_WORKER_CONFIG:-$HOME/.config/claude-hands-free/worker.env}"
[ -f "$CONF" ] && . "$CONF"
# A session started from inside another Claude session inherits its auth proxy and comes up "Not logged in".
for v in $(env | grep -oE '^(CLAUDE|ANTHROPIC)[A-Z_]*'); do unset "$v"; done
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" LANG="${LANG:-en_US.UTF-8}"
NAME="${HF_WORKER_NAME:-Claude Hands Free worker}"
T="${HF_WORKER_TMUX:-hands-free}"
DIR="${HF_WORKER_DIR:-$REPO}"
BRIEF="${HF_WORKER_BRIEF:-$REPO/scripts/worker-brief.md}"
RULES="${HF_WORKER_RULES:-$REPO/scripts/worker-rules.md}"
INBOX="$HOME/.local/state/claude-hands-free/for-owner"
ESCALATE="${HF_WORKER_ESCALATE:-write a markdown note to $INBOX/<UTC timestamp>-<short-slug>.md (create the folder if needed).}"

command -v tmux >/dev/null || { echo "tmux not found (brew install tmux)"; exit 1; }
command -v claude >/dev/null || { echo "claude CLI not found"; exit 1; }
[ -f "$BRIEF" ] || { echo "no brief at $BRIEF"; exit 1; }
[ -f "$RULES" ] || { echo "no rules at $RULES"; exit 1; }
if tmux has-session -t "=$T" 2>/dev/null; then echo "already running: tmux session $T"; exit 0; fi

if [ "${HF_WORKER_TRUST:-0}" = 1 ]; then
  python3 - "$DIR" <<'PY' || echo "trust step failed for $DIR"
import json, os, shutil, sys, time
p = os.path.expanduser("~/.claude.json"); d = os.path.realpath(sys.argv[1])
c = json.load(open(p)); proj = c.setdefault("projects", {}).setdefault(d, {})
if not proj.get("hasTrustDialogAccepted"):
    shutil.copy2(p, p + ".bak-" + time.strftime("%Y%m%dT%H%M%S"))
    proj["hasTrustDialogAccepted"] = True
    tmp = p + ".tmp"; json.dump(c, open(tmp, "w"), indent=2); os.replace(tmp, p)
    print("trusted " + d)
PY
fi

PROMPT="$(cat "$BRIEF")"
if [ -n "${HF_WORKER_EXTRA:-}" ] && [ -f "$HF_WORKER_EXTRA" ]; then PROMPT="$PROMPT

$(cat "$HF_WORKER_EXTRA")"; fi
PROMPT="${PROMPT//\{NAME\}/$NAME}"
SYS="$(cat "$RULES")"; SYS="${SYS//\{ESCALATE\}/$ESCALATE}"
# The worker is hidden, so it must never block on an in-session question.
tmux new-session -d -s "$T" -n worker -c "$DIR" -x 200 -y 50 \
  claude --remote-control "$NAME" -n "$NAME" --disallowedTools AskUserQuestion \
  --append-system-prompt "$SYS" "$PROMPT" && echo "started \"$NAME\" in tmux session $T ($DIR)"
