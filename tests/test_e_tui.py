#!/usr/bin/env python3
"""Tests for Spec E: tui.py week_report_lines() with timelog off and on."""
import datetime as dt
import importlib.util
import os
import re
import subprocess
import sys
import time


def load_tui(vault):
    tui_path = os.path.join(vault, ".tarokaja", "tui.py")
    spec = importlib.util.spec_from_file_location("tui_e", tui_path)
    assert spec is not None and spec.loader is not None, "Failed to load spec for tui.py"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def set_addons(vault, addons_val):
    cfg_path = os.path.join(vault, ".tarokaja", "config")
    with open(cfg_path, encoding="utf-8") as fh:
        text = fh.read()
    if re.search(r"^ADDONS=", text, flags=re.M):
        text = re.sub(r"^ADDONS=.*$", f"ADDONS={addons_val}", text, flags=re.M)
    else:
        text = text.rstrip("\n") + f"\nADDONS={addons_val}\n"
    with open(cfg_path, "w", encoding="utf-8") as fh:
        fh.write(text)


def main():
    vault = sys.argv[1]
    timelog_py = os.path.join(vault, ".tarokaja", "addons", "timelog", "timelog.py")
    assert os.path.isfile(timelog_py), f"Missing {timelog_py}"

    # 1. When timelog is off, week_report_lines() returns []
    set_addons(vault, "")
    tui_off = load_tui(vault)
    assert hasattr(tui_off, "week_report_lines"), "tui.py is missing week_report_lines()"
    lines_off = tui_off.week_report_lines()
    assert lines_off == [], f"Expected [] when timelog is off, got {lines_off!r}"

    # 2. When timelog is enabled, week_report_lines() returns the lines of timelog.py week
    set_addons(vault, "timelog")
    now = int(time.time())
    today = dt.date.fromtimestamp(now)
    monday = today - dt.timedelta(days=today.weekday())
    monday_start = int(dt.datetime.combine(monday, dt.time(0, 0)).timestamp())
    start = max(monday_start + 60, now - 1800)

    for args in [
        ["add", "T-001", "seat_start", "s1", "--at", str(start)],
        ["add", "T-001", "seat_end", "s1", "--at", str(start + 720)],     # 12 min
        ["add", "T-001", "agent_start", "bg", "--at", str(start)],
        ["add", "T-001", "agent_tick", "bg", "--at", str(start + 540)],
        ["add", "T-001", "agent_end", "bg", "--at", str(start + 1080)],   # 18 min
    ]:
        subprocess.run([sys.executable, "-I", timelog_py] + args, cwd=vault, check=True)

    tui_on = load_tui(vault)
    lines_on = tui_on.week_report_lines()
    assert isinstance(lines_on, list) and len(lines_on) > 0, f"Expected non-empty lines when timelog is on, got {lines_on!r}"
    assert any("T-001" in ln and "12" in ln and "18" in ln for ln in lines_on), f"Expected T-001 with 12 and 18 min in {lines_on!r}"
    assert any("total" in ln.lower() or "合計" in ln for ln in lines_on), f"Expected Total line in {lines_on!r}"


if __name__ == "__main__":
    main()
