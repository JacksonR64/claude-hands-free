#!/usr/bin/env python3
"""Private, atomic IPC between the floating panel and each mod instance."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid


def key(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value):
        raise ValueError("Invalid identifier")
    return value


def atomic(path, value):
    temp = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        with temp.open("x") as stream:
            os.chmod(temp, 0o600)
            json.dump(value, stream)
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def receipt(root, command, status, detail=""):
    atomic(root / ("ack-" + key(command["id"]) + ".json"), {
        "id": command["id"], "session": command["session"],
        "instance": command["instance"], "status": status,
        "detail": detail, "ts": time.time() * 1000,
    })


def drain(root, session, instance, now=None):
    now = time.time() * 1000 if now is None else now
    commands = []
    for path in sorted(root.glob("cmd-" + key(session) + "-*.json")):
        command = read(path)
        path.unlink(missing_ok=True)
        if not isinstance(command, dict):
            continue
        try:
            key(command["id"])
            key(command["instance"])
            if command["session"] != session:
                continue
            age = now - float(command["ts"])
            if command["instance"] != instance or not 0 <= age <= 30000:
                receipt(root, command, "failed", "Session reloaded or command expired; please repeat.")
            elif command.get("verb") not in {"reply", "stop", "toggle", "play", "drop", "abort", "read", "feedback"}:
                receipt(root, command, "failed", "Unknown command")
            elif not isinstance(command.get("text", ""), str) or len(command.get("text", "")) > 16000:
                receipt(root, command, "failed", "Message is too long")
            else:
                commands.append(command)
        except (KeyError, TypeError, ValueError):
            continue
    return sorted(commands, key=lambda command: command["ts"])


def wait_for_answer(root, session, instance, request, timeout):
    path = root / ("answer-" + key(request) + ".json")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        answer = read(path)
        if answer is not None:
            path.unlink(missing_ok=True)
            if (isinstance(answer, dict) and answer.get("session") == session
                    and answer.get("instance") == instance and answer.get("request") == request
                    and isinstance(answer.get("text"), str)
                    and 0 <= time.time() * 1000 - float(answer.get("ts", 0)) <= 30000):
                receipt(root, {"id": request, "session": session, "instance": instance}, "answered", "Response received")
                return answer
        time.sleep(0.1)
    return {"error": "Voice response timed out"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / ".cache/read-aloud/conversation")
    parser.add_argument("operation", choices=["publish", "drain", "ack", "wait", "remove"])
    parser.add_argument("args", nargs="*")
    opts = parser.parse_args()
    root = opts.root
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    args = opts.args
    if opts.operation == "publish":
        value = json.loads(args[0])
        path = root / ("s-" + key(value["id"]) + ".json")
        prior = read(path)
        if not isinstance(prior, dict) or prior.get("ts", 0) <= value["ts"]:
            atomic(path, value)
    elif opts.operation == "drain":
        print(json.dumps(drain(root, key(args[0]), key(args[1]))))
    elif opts.operation == "ack":
        receipt(root, json.loads(args[0]), args[1], args[2] if len(args) > 2 else "")
    elif opts.operation == "wait":
        print(json.dumps(wait_for_answer(root, key(args[0]), key(args[1]), key(args[2]), float(args[3]))))
    elif opts.operation == "remove":
        path = root / ("s-" + key(args[0]) + ".json")
        value = read(path)
        if isinstance(value, dict) and value.get("instance") == args[1]:
            path.unlink(missing_ok=True)
    # Expire receipts and orphaned answers. Commands have their own short delivery window.
    for pattern in ("ack-*.json", "answer-*.json", "cmd-*.json"):
        for path in root.glob(pattern):
            try:
                if time.time() - path.stat().st_mtime > 86400:
                    path.unlink(missing_ok=True)
            except OSError:
                pass


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
