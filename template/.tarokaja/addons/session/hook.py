#!/usr/bin/env python3
"""Tarokaja add-on "session": a Claude Code hook that binds an interactive session to a ticket.

Claude Code runs this file on SessionStart, UserPromptSubmit, PostToolUse, and Stop (install.py adds the hooks).
It acts only when meeting.sh started the session: TK_TICKET is set and TK_HEADLESS is not.
  - logs/sessions/<session id>.json: session, ticket, surface, workspace (cmux), last_seen
  - the ticket frontmatter gets session: <session id>, so the next meeting resumes it
  - with the timelog add-on: agent_start on a prompt, agent_tick after a tool (at most once a minute), agent_end on Stop
It never prints and always exits 0, so it can never block or change a Claude session.
"""
import json
import os
import re
import subprocess
import sys
import time

TK_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # keep symlinks: no realpath
VAULT = os.path.dirname(TK_DIR)
SESSIONS = os.path.join(TK_DIR, "logs", "sessions")
TICK_EVERY = 60
ID_RE = re.compile(r"^T-\d+$")
SID_RE = re.compile(r"^[A-Za-z0-9-]{1,100}$")


def _conf(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                m = re.match(r"^([A-Z_]+)=(.*)$", ln.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2)
    except OSError:
        pass
    return out


def addons():
    val = os.environ.get("ADDONS") or _conf(os.path.join(TK_DIR, "config")).get("ADDONS", "")
    return [a.strip() for a in val.split(",") if a.strip()]


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_file(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def ticket_file(tid):
    folder = os.path.join(VAULT, "Tickets")
    for name in sorted(os.listdir(folder)):
        if name.startswith(tid + " ") and name.endswith(".md"):
            return os.path.join(folder, name)
    return None


def set_session(path, sid):
    """Set session: SID in the ticket frontmatter. Change nothing else."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return
    end = next((i for i in range(1, len(lines)) if lines[i] == "---"), None)
    if end is None:
        return
    for i in range(1, end):
        if re.match(r"^session:", lines[i]):
            if lines[i].split(":", 1)[1].strip().strip('"') == sid:
                return
            lines[i] = "session: " + sid
            break
    else:
        lines.insert(end, "session: " + sid)
    write_file(path, "\n".join(lines))


def unbind_others(tid, sid):
    """A ticket has one session: clear the ticket in the records of its older sessions."""
    for name in os.listdir(SESSIONS):
        if not name.endswith(".json") or name == sid + ".json":
            continue
        path = os.path.join(SESSIONS, name)
        rec = read_json(path)
        if rec.get("ticket") == tid:
            rec["ticket"] = ""
            write_file(path, json.dumps(rec) + "\n")


def timelog(tid, kind, sid):
    script = os.path.join(TK_DIR, "addons", "timelog", "timelog.py")
    if os.path.isfile(script):
        subprocess.run([sys.executable, "-I", script, "add", tid, kind, sid],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def main():
    tid = os.environ.get("TK_TICKET", "")
    if not ID_RE.match(tid) or os.environ.get("TK_HEADLESS"):
        return
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    sid, event = str(payload.get("session_id") or ""), payload.get("hook_event_name")
    if not SID_RE.match(sid):
        return
    now = int(time.time())
    os.makedirs(SESSIONS, exist_ok=True)
    path = os.path.join(SESSIONS, sid + ".json")
    rec = read_json(path)
    new_binding = rec.get("ticket") != tid
    rec.update({"session": sid, "ticket": tid, "surface": os.environ.get("CMUX_SURFACE_ID", ""),
                "workspace": os.environ.get("CMUX_WORKSPACE_ID", ""), "last_seen": now})

    kind = None
    if "timelog" in addons():
        if event == "UserPromptSubmit":
            kind = "agent_start"
        elif event == "PostToolUse" and now - int(rec.get("last_tick") or 0) >= TICK_EVERY:
            kind, rec["last_tick"] = "agent_tick", now
        elif event == "Stop":
            kind = "agent_end"
    write_file(path, json.dumps(rec) + "\n")

    if new_binding:
        unbind_others(tid, sid)
    f = ticket_file(tid)
    if f:
        set_session(f, sid)
    if kind:
        timelog(tid, kind, sid)


if __name__ == "__main__":
    try:
        main()
    except Exception:   # a hook must never break the session
        pass
    sys.exit(0)
