#!/usr/bin/env python3
"""Prints {"title","local"} for a Claude Code CLI session id, as the Claude desktop app has it.
Generic titles (remote-control / project-thread sessions) get a label from the folder and the app's one-line status."""
import glob, json, os, re, sys

sid = sys.argv[1]
root = os.path.expanduser("~/Library/Application Support/Claude/claude-code-sessions")
out = {"title": "", "local": ""}
for f in glob.glob(root + "/**/local_*.json", recursive=True):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if d.get("cliSessionId") != sid:
        continue
    title = d.get("title") or ""
    out["local"] = d.get("sessionId") or os.path.basename(f)[:-5]
    if re.match(r"^(Remote Control session|Claude Code session|Untitled)", title, re.I):
        folder = os.path.basename((d.get("cwd") or "").rstrip("/"))
        detail = ((d.get("postTurnSummary") or {}).get("status_detail") or "").strip()
        words = " ".join(detail.split()[:7])
        title = " · ".join(x for x in (folder, words) if x) or title
    out["title"] = title
    break
print(json.dumps(out))
