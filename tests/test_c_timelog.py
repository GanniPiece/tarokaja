#!/usr/bin/env python3
"""Tests for Spec C: timelog add-on (add, sync, week, on_event, status history, Daily tables)."""
import datetime as dt
import json
import os
import re
import subprocess
import sys


def read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def fm_value(path, key):
    text = read_text(path)
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None
    for ln in lines[1:]:
        if ln == "---":
            break
        m = re.match(r"^" + re.escape(key) + r":\s*(.*)$", ln)
        if m:
            return m.group(1).strip()
    return None


def daily_zh_ok(path):
    return read_text(path).startswith("# 2026-11-11\n")


def run_cmd(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert r.returncode == 0, f"Command failed ({r.returncode}): {cmd}\nstdout: {r.stdout}\nstderr: {r.stderr}"
    return r.stdout


def main():
    vault = sys.argv[1]
    ao_dir = os.path.join(vault, ".agent-office")
    timelog_py = os.path.join(ao_dir, "addons", "timelog", "timelog.py")
    on_event = os.path.join(ao_dir, "addons", "timelog", "on_event")

    assert os.path.isfile(timelog_py), f"Missing {timelog_py}"
    assert os.path.isfile(on_event) and os.access(on_event, os.X_OK), f"Missing or non-executable {on_event}"

    # Wednesday 2026-11-11 in local time (so Monday..Wednesday is in the same week)
    day_str = "2026-11-11"
    t0 = int(dt.datetime(2026, 11, 11, 10, 0, 0).timestamp())
    now = int(dt.datetime(2026, 11, 11, 14, 0, 0).timestamp())

    t1_path = os.path.join(vault, "Tickets", "T-001 Try Agent Office.md")
    assert os.path.isfile(t1_path), "Missing T-001 ticket"

    # 1. Write events on T-001 with --at:
    #    Two overlapping seats: [t0, t0+600] (10m) and [t0+300, t0+900] (10m) -> merged 15 min (no double count)
    #    Closed agent interval: [t0, t0+1200] (20m), with a tick at t0+600 (no gap over 15 min)
    #    Open agent interval within 900s of now: [now-300, ...] -> ends at now (5m), total agent = 25 min
    for args in [
        ["add", "T-001", "seat_start", "s1", "--at", str(t0)],
        ["add", "T-001", "seat_end", "s1", "--at", str(t0 + 600)],
        ["add", "T-001", "seat_start", "s2", "--at", str(t0 + 300)],
        ["add", "T-001", "seat_end", "s2", "--at", str(t0 + 900)],
        ["add", "T-001", "agent_start", "bg", "--at", str(t0)],
        ["add", "T-001", "agent_tick", "bg", "--at", str(t0 + 600)],
        ["add", "T-001", "agent_end", "bg", "--at", str(t0 + 1200)],
        ["add", "T-001", "agent_start", "s_open", "--at", str(now - 300)],
    ]:
        run_cmd([sys.executable, "-I", timelog_py] + args, cwd=vault)

    t1_log = os.path.join(ao_dir, "logs", "time", "T-001.jsonl")
    assert os.path.isfile(t1_log), f"Expected event file {t1_log}"
    with open(t1_log, encoding="utf-8") as fh:
        ev_lines = [json.loads(line) for line in fh if line.strip()]
    assert len(ev_lines) == 8, f"Expected 8 events in T-001.jsonl, got {len(ev_lines)}"
    for ev in ev_lines:
        assert set(ev.keys()) >= {"at", "kind", "ref"} and isinstance(ev["at"], int), f"Bad event: {ev}"

    # 2. Old system event file (same path and format) is read as-is
    t2_path = os.path.join(vault, "Tickets", "T-002 Old system task.md")
    write_text(t2_path, "\n".join([
        "---",
        "id: T-002",
        "status: doing",
        "project: Core",
        "created: 2026-11-11",
        "updated: 2026-11-11",
        "---",
        "# Old system task",
        "",
    ]))
    t2_log = os.path.join(ao_dir, "logs", "time", "T-002.jsonl")
    old_events = [
        {"at": t0, "kind": "seat_start", "ref": "old-seat"},
        {"at": t0 + 120, "kind": "ping", "ref": "old-seat"},
        {"at": t0 + 480, "kind": "seat_end", "ref": "old-seat"},
        {"at": t0, "kind": "agent_start", "ref": "old-sess"},
        {"at": t0 + 180, "kind": "agent_tick", "ref": "old-sess"},
        {"at": t0 + 720, "kind": "agent_end", "ref": "old-sess"},
    ]
    write_text(t2_log, "\n".join(json.dumps(e) for e in old_events) + "\n")

    # 3. sync skips a ticket while a meeting pid file holds a live pid
    meeting_pid_file = os.path.join(ao_dir, "logs", "T-001.meeting.pid")
    write_text(meeting_pid_file, f"{os.getpid()}\n")

    daily_path = os.path.join(vault, "Daily", f"{day_str}.md")
    write_text(daily_path, "\n".join([
        "# 2026-11-11",
        "",
        "Morning notes.",
        "",
        "## Time",
        "",
        "| Ticket | Me (min) | Agent (min) |",
        "|---|---|---|",
        "| [[T-001 Try Agent Office]] | 1 | 1 |",
        "| Total | 1 | 1 |",
        "",
        "## Evening",
        "",
        "Footer notes.",
        "",
    ]))

    run_cmd([sys.executable, "-I", timelog_py, "sync", "--now", str(now)], cwd=vault)
    assert fm_value(t1_path, "time_me") is None, "T-001 frontmatter must not be updated while meeting pid is alive"
    assert fm_value(t1_path, "time_agent") is None, "T-001 frontmatter must not be updated while meeting pid is alive"
    assert fm_value(t2_path, "time_me") == "8", f"Expected T-002 time_me=8, got {fm_value(t2_path, 'time_me')}"
    assert fm_value(t2_path, "time_agent") == "12", f"Expected T-002 time_agent=12, got {fm_value(t2_path, 'time_agent')}"

    # Remove live meeting pid and sync again -> T-001 frontmatter is updated
    os.remove(meeting_pid_file)
    run_cmd([sys.executable, "-I", timelog_py, "sync", "--now", str(now)], cwd=vault)
    assert fm_value(t1_path, "time_me") == "15", f"Expected T-001 time_me=15, got {fm_value(t1_path, 'time_me')}"
    assert fm_value(t1_path, "time_agent") == "25", f"Expected T-001 time_agent=25, got {fm_value(t1_path, 'time_agent')}"

    # 4. Check Daily note (en): ## Time replaced, other content kept
    daily_en = read_text(daily_path)
    assert "## Time" in daily_en, f"Missing ## Time in {daily_en}"
    assert "| Ticket | Me (min) | Agent (min) |" in daily_en, f"Missing en table header in {daily_en}"
    assert "| [[T-001 Try Agent Office]] | 15 | 25 |" in daily_en, f"Missing T-001 row in {daily_en}"
    assert "| [[T-002 Old system task]] | 8 | 12 |" in daily_en, f"Missing T-002 row in {daily_en}"
    assert "| Total | 23 | 37 |" in daily_en, f"Missing Total row in {daily_en}"
    assert "| 1 | 1 |" not in daily_en, f"Old section was not replaced in {daily_en}"
    assert "Morning notes." in daily_en and "Footer notes." in daily_en, f"Other note content lost in {daily_en}"

    # A missing Daily note is not created (Obsidian or the user creates it, with its template)
    os.remove(daily_path)
    run_cmd([sys.executable, "-I", timelog_py, "sync", "--now", str(now)], cwd=vault)
    assert not os.path.exists(daily_path), "sync must not create a missing Daily note"

    # Check Daily note (zh-TW) on an existing note
    write_text(daily_path, "# 2026-11-11\n")
    cfg_path = os.path.join(ao_dir, "config")
    cfg_orig = read_text(cfg_path)
    write_text(cfg_path, re.sub(r"^AO_LANG=.*$", "AO_LANG=zh-TW", cfg_orig, flags=re.M))
    try:
        run_cmd([sys.executable, "-I", timelog_py, "sync", "--now", str(now)], cwd=vault)
        assert daily_zh_ok(daily_path), "Daily note lost its first line"
        daily_zh = read_text(daily_path)
        assert "## 時間" in daily_zh, f"Missing ## 時間 in {daily_zh}"
        assert "| 卡片 | 我（分） | agent（分） |" in daily_zh, f"Missing zh-TW table header in {daily_zh}"
        assert "| [[T-001 Try Agent Office]] | 15 | 25 |" in daily_zh, f"Missing T-001 row in {daily_zh}"
        assert "| [[T-002 Old system task]] | 8 | 12 |" in daily_zh, f"Missing T-002 row in {daily_zh}"
        assert "| 合計 | 23 | 37 |" in daily_zh, f"Missing 合計 row in {daily_zh}"
    finally:
        write_text(cfg_path, cfg_orig)

    # 5. week [--now EPOCH] output contains ticket ids, minutes, and total line
    week_out = run_cmd([sys.executable, "-I", timelog_py, "week", "--now", str(now)], cwd=vault)
    week_lines = week_out.splitlines()
    t1_lines = [ln for ln in week_lines if "T-001" in ln]
    assert t1_lines and any("15" in ln and "25" in ln for ln in t1_lines), f"Bad T-001 line in week output:\n{week_out}"
    t2_lines = [ln for ln in week_lines if "T-002" in ln]
    assert t2_lines and any("8" in ln and "12" in ln for ln in t2_lines), f"Bad T-002 line in week output:\n{week_out}"
    tot_lines = [ln for ln in week_lines if "total" in ln.lower() or "合計" in ln]
    assert tot_lines and any("23" in ln and "37" in ln for ln in tot_lines), f"Bad Total line in week output:\n{week_out}"

    # 5b. A gap of more than 15 min between two events of one interval cuts the interval
    t4_path = os.path.join(vault, "Tickets", "T-004 Gap.md")
    write_text(t4_path, "---\nid: T-004\nstatus: doing\n---\n# Gap\n")
    for args in [
        ["add", "T-004", "seat_start", "p1", "--at", str(t0)],
        ["add", "T-004", "seat_end", "p1", "--at", str(t0 + 3600)],      # 60 min, no event between -> 0
        ["add", "T-004", "agent_start", "bg", "--at", str(t0)],
        ["add", "T-004", "agent_tick", "bg", "--at", str(t0 + 300)],      # 5 min
        ["add", "T-004", "agent_tick", "bg", "--at", str(t0 + 2100)],     # 30 min gap: cut, new interval starts here
        ["add", "T-004", "agent_end", "bg", "--at", str(t0 + 2280)],      # 3 min
    ]:
        run_cmd([sys.executable, "-I", timelog_py] + args, cwd=vault)
    run_cmd([sys.executable, "-I", timelog_py, "sync", "--now", str(now)], cwd=vault)
    assert fm_value(t4_path, "time_me") == "0", f"Expected T-004 time_me=0, got {fm_value(t4_path, 'time_me')}"
    assert fm_value(t4_path, "time_agent") == "8", f"Expected T-004 time_agent=8, got {fm_value(t4_path, 'time_agent')}"

    # 6. on_event mapping, sync trigger, and status history on tick
    t3_path = os.path.join(vault, "Tickets", "T-003 Event map.md")
    write_text(t3_path, "---\nid: T-003\nstatus: doing\n---\n# Event map\n")
    run_cmd([sys.executable, "-I", timelog_py, "add", "T-003", "agent_start", "s0", "--at", str(t0)], cwd=vault)
    run_cmd([sys.executable, "-I", timelog_py, "add", "T-003", "agent_end", "s0", "--at", str(t0 + 600)], cwd=vault)
    assert fm_value(t3_path, "time_agent") is None, "T-003 should not have time_agent before sync"

    for ev_args in [
        ["session_start", "T-003", "bg"],
        ["session_tick", "T-003", "bg"],
        ["session_end", "T-003", "bg"],
        ["meeting_start", "T-003", "43210"],
        ["meeting_end", "T-003", "43210"],
    ]:
        run_cmd([on_event] + ev_args, cwd=vault)

    # session_end / meeting_end ran sync, updating T-003 frontmatter
    assert fm_value(t3_path, "time_agent") == "10", f"Expected on_event to sync T-003 time_agent=10, got {fm_value(t3_path, 'time_agent')}"

    t3_log = os.path.join(ao_dir, "logs", "time", "T-003.jsonl")
    assert os.path.isfile(t3_log), "on_event did not create T-003.jsonl"
    with open(t3_log, encoding="utf-8") as fh:
        t3_events = [(e["kind"], e["ref"]) for e in (json.loads(line) for line in fh if line.strip())]
    expected_t3 = [
        ("agent_start", "s0"),
        ("agent_end", "s0"),
        ("agent_start", "bg"),
        ("agent_tick", "bg"),
        ("agent_end", "bg"),
        ("seat_start", "43210"),
        ("seat_end", "43210"),
    ]
    assert t3_events == expected_t3, f"Expected {expected_t3}, got {t3_events}"

    # Status history: tick records {"at", "status"} only when status differs from last line
    status_file = os.path.join(ao_dir, "logs", "status", "T-001.jsonl")
    if os.path.exists(status_file):
        os.remove(status_file)
    run_cmd([on_event, "tick", "-", "-"], cwd=vault)
    assert os.path.isfile(status_file), f"Missing status history file {status_file}"
    with open(status_file, encoding="utf-8") as fh:
        hist1 = [json.loads(line) for line in fh if line.strip()]
    assert len(hist1) == 1 and hist1[0].get("status") == "doing" and isinstance(hist1[0].get("at"), int), f"Unexpected hist1: {hist1}"

    # Second tick with unchanged status -> no new line
    run_cmd([on_event, "tick", "-", "-"], cwd=vault)
    with open(status_file, encoding="utf-8") as fh:
        hist2 = [json.loads(line) for line in fh if line.strip()]
    assert len(hist2) == 1, f"Expected 1 line when status unchanged, got {len(hist2)}: {hist2}"

    # Change T-001 status to waiting -> next tick adds a new line
    t1_text = read_text(t1_path)
    write_text(t1_path, re.sub(r"^status:\s*doing$", "status: waiting", t1_text, flags=re.M))
    run_cmd([on_event, "tick", "-", "-"], cwd=vault)
    with open(status_file, encoding="utf-8") as fh:
        hist3 = [json.loads(line) for line in fh if line.strip()]
    assert len(hist3) == 2 and hist3[1].get("status") == "waiting" and isinstance(hist3[1].get("at"), int), f"Unexpected hist3: {hist3}"


if __name__ == "__main__":
    main()
