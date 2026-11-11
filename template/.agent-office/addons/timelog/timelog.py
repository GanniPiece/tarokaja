#!/usr/bin/env python3
"""Agent Office add-on "timelog": time per ticket for the manager ("me") and the agent.

    timelog.py add ID KIND REF [--at EPOCH]   append one event
    timelog.py sync [--now EPOCH]             write time_me / time_agent and the Daily note tables
    timelog.py week [--now EPOCH]             print this week's time per ticket
    timelog.py status                         record status changes (logs/status/ID.jsonl)

Events: .agent-office/logs/time/ID.jsonl, one JSON object per line {"at": int, "kind": str, "ref": str}.
Kinds: seat_start / seat_end (the manager is in a meeting or talk, ref = its pid),
agent_start / agent_tick / agent_end (the agent works, ref = "bg" or a session id), ping (activity).
Python 3.8+, standard library only.
"""
import datetime as dt
import json
import os
import re
import sys
import time

AO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # keep symlinks: no realpath
VAULT = os.path.dirname(AO_DIR)
LOGS = os.path.join(AO_DIR, "logs")
TIME_DIR = os.path.join(LOGS, "time")
STATUS_DIR = os.path.join(LOGS, "status")
TICKETS = os.path.join(VAULT, "Tickets")
IDLE = 900            # more than this many seconds between two events of an interval cuts it (sleep, a lost end)
DAILY_DAYS = 7        # Daily notes older than this are left alone
KINDS = ("seat_start", "seat_end", "agent_start", "agent_tick", "agent_end", "ping")
ID_RE = re.compile(r"^T-\d+$")

LABELS = {
    "en": {"heading": "## Time", "head": "| Ticket | Me (min) | Agent (min) |", "total": "Total",
           "week": "Week from %s", "none": "No time this week."},
    "zh-TW": {"heading": "## 時間", "head": "| 卡片 | 我（分） | agent（分） |", "total": "合計",
              "week": "%s 起的這一週", "none": "這週沒有時間紀錄。"},
}


# ---------------------------------------------------------------- settings

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


def setting(key, default):
    """Environment, then config, then the language profile, then default (same order as lib.sh)."""
    config = _conf(os.path.join(AO_DIR, "config"))
    lang = os.environ.get("AO_LANG") or config.get("AO_LANG") or "en"
    if key == "AO_LANG":
        return lang if lang in LABELS else "en"
    profile = _conf(os.path.join(AO_DIR, "profiles", lang + ".conf"))
    return os.environ.get(key) or config.get(key) or profile.get(key) or default


# ---------------------------------------------------------------- events

def add(tid, kind, ref, at=None):
    if not ID_RE.match(tid) or kind not in KINDS:
        raise ValueError("bad event: %s %s" % (tid, kind))
    os.makedirs(TIME_DIR, exist_ok=True)
    ev = {"at": int(time.time()) if at is None else int(at), "kind": kind, "ref": str(ref or "")}
    with open(os.path.join(TIME_DIR, tid + ".jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(ev) + "\n")


def events(tid):
    out = []
    try:
        with open(os.path.join(TIME_DIR, tid + ".jsonl"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                at = ev.get("at") if isinstance(ev, dict) else None
                if isinstance(at, (int, float)) and not isinstance(at, bool) and ev.get("kind") in KINDS:
                    out.append((int(at), ev["kind"], str(ev.get("ref") or "")))
    except OSError:
        pass
    return sorted(out)


def agent_intervals(evs, now):
    return merge(_agent_by_ref(evs, now))


def _agent_by_ref(evs, now, prefix="agent"):
    """[(start, end)] of agent time, per ref, not merged.

    A gap of more than IDLE seconds between two events cuts the interval at the earlier event.
    An interval without an end event ends at now when its last event is IDLE seconds old or less, else at that event.
    """
    out, open_ = [], {}          # ref -> [start, last event]
    for at, kind, ref in evs:
        if kind == prefix + "_start":
            if ref in open_:
                s, last = open_.pop(ref)
                out.append((s, last))
            open_[ref] = [at, at]
        elif kind == prefix + "_tick" and ref in open_:
            s, last = open_[ref]
            if at - last > IDLE:
                out.append((s, last))
                open_[ref] = [at, at]
            else:
                open_[ref][1] = max(last, at)
        elif kind == prefix + "_end" and ref in open_:
            s, last = open_.pop(ref)
            out.append((s, at if at - last <= IDLE else last))
    for s, last in open_.values():
        out.append((s, now if 0 <= now - last <= IDLE else last))
    return [x for x in out if x[1] > x[0]]


def merge(spans, gap=0):
    """Join spans that overlap or are at most gap seconds apart."""
    out = []
    for s, e in sorted(spans):
        if out and s - out[-1][1] <= gap:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def me_intervals(evs, now):
    """[(start, end)] of the manager's time: activity inside a seat (a meeting or talk is open).

    Activity is every event that is not from a background session (ref "bg"): seat events, pings, and the
    events and intervals of interactive agent sessions. Activity less than IDLE seconds apart is joined.
    A gap of more than IDLE seconds does not count, such as a laptop that sleeps during a meeting.
    A seat without seat_end lasts while its activity continues.
    """
    fg = [(at, kind, ref) for at, kind, ref in evs if ref != "bg"]
    agent = [(s, e) for s, e in _agent_by_ref([x for x in evs if x[2] != "bg"], now)]
    windows = []
    for i, (start, kind, ref) in enumerate(fg):
        if kind != "seat_start":
            continue
        end = next((at for at, k, r in fg[i + 1:] if k == "seat_end" and r == ref), None)
        if end is None:
            nxt = next((at for at, k, _r in fg[i + 1:] if k == "seat_start"), None)
            inside = lambda t: t >= start and (nxt is None or t < nxt)
            spans = [(at, at) for at, _k, _r in fg if inside(at)] + [(s, e) for s, e in agent if inside(s)]
            last = merge([(start, start)] + spans, IDLE)[0][1]
            end = now if nxt is None and 0 <= now - last <= IDLE else last
        windows.append((start, end))
    out = []
    for ws, we in windows:
        spans = [(ws, ws), (we, we)] + [(at, at) for at, _k, _r in fg if ws <= at <= we]
        spans += [(max(s, ws), min(e, we)) for s, e in agent if s < we and e > ws]
        out += merge(spans, IDLE)
    return [x for x in merge(out) if x[1] > x[0]]


def by_day(spans):
    """{"YYYY-MM-DD": seconds} with each span split at local midnight."""
    out = {}
    for s, e in spans:
        while s < e:
            day = dt.datetime.fromtimestamp(s).date()
            nxt = int(dt.datetime.combine(day + dt.timedelta(days=1), dt.time()).timestamp())
            end = min(e, nxt)
            out[day.isoformat()] = out.get(day.isoformat(), 0) + end - s
            s = end
    return out


def minutes(seconds):
    return int(round(seconds / 60.0))


# ---------------------------------------------------------------- tickets

def ticket_files():
    out = {}
    try:
        for name in sorted(os.listdir(TICKETS)):
            m = re.match(r"^(T-\d+) .*\.md$", name)
            if m:
                out[m.group(1)] = os.path.join(TICKETS, name)
    except OSError:
        pass
    return out


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return {}
    out = {}
    for ln in lines[1:]:
        if ln == "---":
            break
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", ln)
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"')
    return out


def set_frontmatter(text, fields):
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return text
    end = next((i for i in range(1, len(lines)) if lines[i] == "---"), None)
    if end is None:
        return text
    seen = set()
    for i in range(1, end):
        m = re.match(r"^([A-Za-z_]+):", lines[i])
        if m and m.group(1) in fields:
            lines[i] = "%s: %s" % (m.group(1), fields[m.group(1)])
            seen.add(m.group(1))
    lines[end:end] = ["%s: %s" % (k, v) for k, v in fields.items() if k not in seen]
    return "\n".join(lines)


def busy(tid):
    """True while a background session or a meeting runs on the ticket: do not rewrite its file then."""
    for name in (tid + ".pid", tid + ".meeting.pid"):
        try:
            pid = int(read(os.path.join(LOGS, name)).strip())
            os.kill(pid, 0)
            return True
        except (ValueError, OSError):
            continue
    return False


def upsert_section(text, heading, body):
    """Replace the section under heading (up to the next "## " heading), or add it at the end."""
    lines = text.split("\n")
    start = next((i for i, ln in enumerate(lines) if ln.strip() == heading), None)
    block = [heading, ""] + body.rstrip("\n").split("\n") + [""]
    if start is None:
        while lines and lines[-1] == "":
            lines.pop()
        return "\n".join(lines + ([""] if lines else []) + block)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[:start] + block + lines[end:])


# ---------------------------------------------------------------- commands

def totals(now):
    """{tid: {"me": {day: s}, "agent": {day: s}}} for every ticket with events."""
    out = {}
    try:
        names = os.listdir(TIME_DIR)
    except OSError:
        return out
    for name in names:
        tid = name[:-6]
        if not name.endswith(".jsonl") or not ID_RE.match(tid):
            continue
        evs = events(tid)
        out[tid] = {"me": by_day(me_intervals(evs, now)), "agent": by_day(agent_intervals(evs, now))}
    return out


def sync(now=None):
    now = int(time.time()) if now is None else now
    data = totals(now)
    files = ticket_files()
    for tid, t in data.items():
        path = files.get(tid)
        if not path or busy(tid):
            continue
        text = read(path)
        new = set_frontmatter(text, {"time_me": minutes(sum(t["me"].values())),
                                     "time_agent": minutes(sum(t["agent"].values()))})
        if new != text:
            write(path, new)
    lang = setting("AO_LANG", "en")
    lab = LABELS[lang]
    heading = setting("H_TIME", lab["heading"])   # a vault copied before H_TIME existed has no profile key
    today = dt.datetime.fromtimestamp(now).date()
    for back in range(DAILY_DAYS):
        day = (today - dt.timedelta(days=back)).isoformat()
        rows = []
        for tid in sorted(data, key=lambda x: int(x[2:])):
            me, ag = minutes(data[tid]["me"].get(day, 0)), minutes(data[tid]["agent"].get(day, 0))
            if me or ag:
                name = os.path.basename(files[tid])[:-3] if tid in files else tid
                rows.append((name, me, ag))
        if not rows:
            continue
        body = [lab["head"], "|---|---|---|"] + ["| [[%s]] | %d | %d |" % r for r in rows]
        body.append("| %s | %d | %d |" % (lab["total"], sum(r[1] for r in rows), sum(r[2] for r in rows)))
        note = os.path.join(VAULT, "Daily", day + ".md")
        if not os.path.isfile(note):
            continue   # never create a Daily note: Obsidian or the user makes it, with its template
        text = read(note)
        new = upsert_section(text, heading, "\n".join(body))
        if new != text:
            write(note, new if new.endswith("\n") else new + "\n")


def week(now=None):
    now = int(time.time()) if now is None else now
    lab = LABELS[setting("AO_LANG", "en")]
    today = dt.datetime.fromtimestamp(now).date()
    monday = today - dt.timedelta(days=today.weekday())
    days = {(monday + dt.timedelta(days=i)).isoformat() for i in range((today - monday).days + 1)}
    files = ticket_files()
    data = totals(now)
    lines = [lab["week"] % monday.isoformat()]
    tot_me = tot_ag = 0
    for tid in sorted(data, key=lambda x: int(x[2:])):
        me = minutes(sum(v for d, v in data[tid]["me"].items() if d in days))
        ag = minutes(sum(v for d, v in data[tid]["agent"].items() if d in days))
        if me or ag:
            title = os.path.basename(files[tid])[:-3] if tid in files else tid
            lines.append("%-40s %5d %5d" % (title[:40], me, ag))
            tot_me, tot_ag = tot_me + me, tot_ag + ag
    if len(lines) == 1:
        lines.append(lab["none"])
    lines.append("%-40s %5d %5d" % (lab["total"], tot_me, tot_ag))
    return lines


def record_status(now=None):
    now = int(time.time()) if now is None else now
    os.makedirs(STATUS_DIR, exist_ok=True)
    for tid, path in ticket_files().items():
        status = frontmatter(read(path)).get("status", "")
        log = os.path.join(STATUS_DIR, tid + ".jsonl")
        last = ""
        for line in read(log).splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                last = rec.get("status", last)
        if status and status != last:
            with open(log, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"at": now, "status": status}) + "\n")


def _opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return int(argv[i + 1])
    return None


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "add" and len(argv) >= 4:
        add(argv[1], argv[2], argv[3], _opt(argv, "--at"))
    elif cmd == "sync":
        sync(_opt(argv, "--now"))
    elif cmd == "week":
        print("\n".join(week(_opt(argv, "--now"))))
    elif cmd == "status":
        record_status()
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
