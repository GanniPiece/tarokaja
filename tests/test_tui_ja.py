#!/usr/bin/env python3
"""Unit tests for .tarokaja/tui.py with TK_LANG=ja."""
import datetime as dt
import importlib.util
import os
import sys


def load_tui(vault):
    tui_path = os.path.join(vault, ".tarokaja", "tui.py")
    spec = importlib.util.spec_from_file_location("tui_ja", tui_path)
    assert spec is not None and spec.loader is not None, "Failed to load spec for tui.py"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    vault = sys.argv[1]

    t1_path = os.path.join(vault, "Tickets", "T-001 Tarokaja を試す.md")
    with open(t1_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join([
            "---",
            "id: T-001",
            "status: doing",
            "project: Tarokaja",
            "created: 2026-11-11",
            "updated: 2026-11-11",
            "due:",
            "waiting_on:",
            "owner:",
            "meeting:",
            "agent_state:",
            "links: []",
            "---",
            "# Tarokaja を試す",
            "",
            "## 完了条件",
            "",
            "最初の作業セッションと会議を完了する。",
            "",
            "## サブタスク",
            "",
            "- [x] Tarokaja をインストールする",
            "- [ ] 説明ノートを書く（agent）",
            "",
            "## Decisions",
            "",
            "## 経過",
            "",
            "- 2026-11-11 09:00 · 起票。",
            "",
        ]))

    tui = load_tui(vault)

    # parse_ticket reads subtasks under ## サブタスク, breadcrumbs under ## 経過, and delegated for （agent）
    t1 = tui.parse_ticket(t1_path)
    assert t1["id"] == "T-001", f"Expected T-001, got {t1['id']}"
    assert t1["status"] == "doing", f"Expected doing, got {t1['status']}"
    assert len(t1["subtasks"]) == 2, f"Expected 2 subtasks, got {len(t1['subtasks'])}"
    assert t1["subtasks"][0] == (True, "Tarokaja をインストールする"), f"Unexpected first subtask: {t1['subtasks'][0]}"
    assert t1["subtasks"][1] == (False, "説明ノートを書く（agent）"), f"Unexpected second subtask: {t1['subtasks'][1]}"
    assert len(t1["crumbs"]) == 1, f"Expected 1 crumb, got {t1['crumbs']}"
    assert "起票。" in t1["crumbs"][0], f"Expected 起票。 in crumb, got {t1['crumbs'][0]}"
    assert t1["delegated"] is True, "Expected delegated True for （agent）"

    # set_fields puts the new breadcrumb first under ## 経過
    tui.set_fields(t1_path, {"status": "waiting", "agent_state": "decide"}, "status：doing -> waiting。")
    t1_after = tui.parse_ticket(t1_path)
    assert t1_after["status"] == "waiting", f"Expected waiting, got {t1_after['status']}"
    assert t1_after["fm"].get("updated") == dt.date.today().isoformat()
    assert len(t1_after["crumbs"]) == 2, f"Expected 2 crumbs, got {t1_after['crumbs']}"
    assert t1_after["crumbs"][0].endswith("· status：doing -> waiting。"), f"Unexpected first crumb: {t1_after['crumbs'][0]}"
    assert "起票。" in t1_after["crumbs"][1], f"Unexpected second crumb: {t1_after['crumbs'][1]}"

    # new_ticket writes the ja headings and the breadcrumb text 起票。
    tid = tui.new_ticket("二番目のタスク", "Tarokaja")
    assert tid == "T-002", f"Expected T-002, got {tid}"
    t2_path = os.path.join(vault, "Tickets", "T-002 二番目のタスク.md")
    assert os.path.isfile(t2_path), "T-002 file not created"
    with open(t2_path, encoding="utf-8") as fh:
        raw_t2 = fh.read()
    assert "\n## 完了条件\n" in raw_t2, "Expected ## 完了条件 heading in new ticket"
    assert "\n## サブタスク\n" in raw_t2, "Expected ## サブタスク heading in new ticket"
    assert "\n## Decisions\n" in raw_t2, "Expected ## Decisions heading in new ticket"
    assert "\n## 経過\n" in raw_t2, "Expected ## 経過 heading in new ticket"

    t2 = tui.parse_ticket(t2_path)
    assert t2["id"] == "T-002"
    assert t2["status"] == "inbox"
    assert t2["delegated"] is False
    assert len(t2["crumbs"]) == 1, f"Expected 1 crumb in new ticket, got {t2['crumbs']}"
    assert t2["crumbs"][0].endswith("· 起票。"), f"Expected new ticket crumb to end with '· 起票。', got {t2['crumbs'][0]}"

    # places labels in ja
    pl = {k: (label, count) for k, label, count in tui.places(tui.load_tickets())}
    assert pl["needs"] == ("要対応", 1), f"Expected ('要対応', 1), got {pl.get('needs')}"
    assert pl["open"] == ("未完了", 2), f"Expected ('未完了', 2), got {pl.get('open')}"


if __name__ == "__main__":
    main()
