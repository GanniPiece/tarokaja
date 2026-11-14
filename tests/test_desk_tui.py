#!/usr/bin/env python3
"""Unit tests for the front desk (T) in .tarokaja/tui.py."""
import importlib.util
import os
import sys


def load_tui(vault):
    tui_path = os.path.join(vault, ".tarokaja", "tui.py")
    spec = importlib.util.spec_from_file_location("tui_desk", tui_path)
    assert spec is not None and spec.loader is not None, "Failed to load spec for tui.py"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    vault = sys.argv[1]
    tui = load_tui(vault)

    # 1. HELP has a line that mentions T and front desk
    assert any("T" in ln and "front desk" in ln.lower() for ln in tui.HELP), (
        f"Expected a HELP line mentioning T and front desk, got: {tui.HELP!r}"
    )

    expected_cmd = [os.path.join(tui.TK_DIR, "desk.sh")]

    # 2. App.act(scr, 'T') when a ticket is selected
    app = tui.App()
    assert app.current() is not None, "Expected a selected ticket in default vault"
    calls = []
    app.interactive = lambda scr, args, what: calls.append((scr, args, what))
    res = app.act(None, "T")
    assert res is True, f"Expected act(None, 'T') to return True, got {res!r}"
    assert len(calls) == 1, f"Expected 1 interactive call, got {calls!r}"
    scr_arg, args_arg, label_arg = calls[0]
    assert scr_arg is None, f"Expected scr=None, got {scr_arg!r}"
    assert args_arg == expected_cmd, f"Expected {expected_cmd!r}, got {args_arg!r}"
    assert isinstance(label_arg, str) and label_arg.strip(), f"Expected non-empty label, got {label_arg!r}"

    # 3. App.act(scr, 'T') when Tickets/ has no tickets (current() is None)
    tickets_dir = os.path.join(vault, "Tickets")
    for name in os.listdir(tickets_dir):
        if name.endswith(".md"):
            os.remove(os.path.join(tickets_dir, name))

    app_empty = tui.App()
    assert app_empty.current() is None, f"Expected current() to be None with empty Tickets/, got {app_empty.current()!r}"
    calls_empty = []
    app_empty.interactive = lambda scr, args, what: calls_empty.append((scr, args, what))
    res_empty = app_empty.act(None, "T")
    assert res_empty is True, f"Expected act(None, 'T') to return True when current() is None, got {res_empty!r}"
    assert len(calls_empty) == 1, f"Expected 1 interactive call when current() is None, got {calls_empty!r}"
    scr_arg2, args_arg2, label_arg2 = calls_empty[0]
    assert scr_arg2 is None, f"Expected scr=None, got {scr_arg2!r}"
    assert args_arg2 == expected_cmd, f"Expected {expected_cmd!r}, got {args_arg2!r}"
    assert isinstance(label_arg2, str) and label_arg2.strip(), f"Expected non-empty label, got {label_arg2!r}"


if __name__ == "__main__":
    main()
