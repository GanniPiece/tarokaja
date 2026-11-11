#!/usr/bin/env python3
"""Unit tests for .tarokaja/tui.py loaded via importlib from the vault."""
import datetime as dt
import importlib.util
import os
import sys


def load_tui(vault):
    tui_path = os.path.join(vault, ".tarokaja", "tui.py")
    spec = importlib.util.spec_from_file_location("tui", tui_path)
    assert spec is not None and spec.loader is not None, "Failed to load spec for tui.py"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    vault = sys.argv[1]
    tui = load_tui(vault)

    t1_path = os.path.join(vault, "Tickets", "T-001 Try Tarokaja.md")
    t1 = tui.parse_ticket(t1_path)
    assert t1["id"] == "T-001", f"Expected T-001, got {t1['id']}"
    assert t1["status"] == "doing", f"Expected doing, got {t1['status']}"
    assert len(t1["subtasks"]) == 4, f"Expected 4 subtasks, got {len(t1['subtasks'])}"
    assert t1["subtasks"][0] == (True, "Install Tarokaja")
    assert t1["subtasks"][1][0] is False
    assert t1["subtasks"][1][1].endswith("(agent)")
    assert len(t1["crumbs"]) == 1, f"Expected 1 crumb, got {t1['crumbs']}"
    assert "Opened." in t1["crumbs"][0]
    assert t1["delegated"] is True

    # set_fields changes status and updated and puts a new breadcrumb first under Breadcrumbs
    tui.set_fields(t1_path, {"status": "waiting", "agent_state": "decide"}, "Status: doing -> waiting.")
    t1_after = tui.parse_ticket(t1_path)
    assert t1_after["status"] == "waiting", f"Expected waiting, got {t1_after['status']}"
    assert t1_after["fm"].get("updated") == dt.date.today().isoformat()
    assert len(t1_after["crumbs"]) == 2, f"Expected 2 crumbs, got {t1_after['crumbs']}"
    assert t1_after["crumbs"][0].endswith("· Status: doing -> waiting."), f"Unexpected first crumb: {t1_after['crumbs'][0]}"
    assert "Opened." in t1_after["crumbs"][1]

    # new_ticket makes T-002 with status inbox
    tid = tui.new_ticket("Second task", "Tarokaja")
    assert tid == "T-002", f"Expected T-002, got {tid}"
    t2_path = os.path.join(vault, "Tickets", "T-002 Second task.md")
    assert os.path.isfile(t2_path), "T-002 file not created"
    t2 = tui.parse_ticket(t2_path)
    assert t2["id"] == "T-002"
    assert t2["status"] == "inbox"
    assert t2["delegated"] is False

    # rows_for groups by status
    tickets = tui.load_tickets()
    rows = tui.rows_for(tickets, "open")
    heads = [item for kind, item in rows if kind == "head"]
    assert heads == ["waiting (1)", "inbox (1)"], f"Unexpected group headers: {heads}"
    ticket_ids = [item["id"] for kind, item in rows if kind == "t"]
    assert ticket_ids == ["T-001", "T-002"], f"Unexpected ticket order: {ticket_ids}"

    # places counts Needs me from agent_state
    pl = {k: (label, count) for k, label, count in tui.places(tickets)}
    assert pl["needs"] == ("Needs me", 1), f"Expected ('Needs me', 1), got {pl.get('needs')}"

    tui.set_fields(t1_path, {"agent_state": ""})
    pl_after = {k: (label, count) for k, label, count in tui.places(tui.load_tickets())}
    assert pl_after["needs"] == ("Needs me", 0), f"Expected ('Needs me', 0), got {pl_after.get('needs')}"


if __name__ == "__main__":
    main()
