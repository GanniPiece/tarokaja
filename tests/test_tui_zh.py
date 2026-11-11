#!/usr/bin/env python3
"""Unit tests for .agent-office/tui.py with AO_LANG=zh-TW."""
import datetime as dt
import importlib.util
import os
import sys


def load_tui(vault):
    tui_path = os.path.join(vault, ".agent-office", "tui.py")
    spec = importlib.util.spec_from_file_location("tui_zh", tui_path)
    assert spec is not None and spec.loader is not None, "Failed to load spec for tui.py"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    vault = sys.argv[1]

    t1_path = os.path.join(vault, "Tickets", "T-001 試用 Agent Office.md")
    with open(t1_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join([
            "---",
            "id: T-001",
            "status: doing",
            "project: Agent Office",
            "created: 2026-11-11",
            "updated: 2026-11-11",
            "due:",
            "waiting_on:",
            "owner:",
            "meeting:",
            "agent_state:",
            "links: []",
            "---",
            "# 試用 Agent Office",
            "",
            "## 完成條件",
            "",
            "完成第一次工作階段與會議。",
            "",
            "## 子任務",
            "",
            "- [x] 安裝 Agent Office",
            "- [ ] 撰寫說明筆記（agent）",
            "",
            "## Decisions",
            "",
            "## Breadcrumb",
            "",
            "- 2026-11-11 09:00 · 開卡。",
            "",
        ]))

    tui = load_tui(vault)

    # parse_ticket reads subtasks under ## 子任務, breadcrumbs under ## Breadcrumb, and delegated for （agent）
    t1 = tui.parse_ticket(t1_path)
    assert t1["id"] == "T-001", f"Expected T-001, got {t1['id']}"
    assert t1["status"] == "doing", f"Expected doing, got {t1['status']}"
    assert len(t1["subtasks"]) == 2, f"Expected 2 subtasks, got {len(t1['subtasks'])}"
    assert t1["subtasks"][0] == (True, "安裝 Agent Office"), f"Unexpected first subtask: {t1['subtasks'][0]}"
    assert t1["subtasks"][1] == (False, "撰寫說明筆記（agent）"), f"Unexpected second subtask: {t1['subtasks'][1]}"
    assert len(t1["crumbs"]) == 1, f"Expected 1 crumb, got {t1['crumbs']}"
    assert "開卡。" in t1["crumbs"][0], f"Expected 開卡。 in crumb, got {t1['crumbs'][0]}"
    assert t1["delegated"] is True, "Expected delegated True for （agent）"

    # set_fields puts the new breadcrumb first under ## Breadcrumb
    tui.set_fields(t1_path, {"status": "waiting", "agent_state": "decide"}, "狀態：doing -> waiting。")
    t1_after = tui.parse_ticket(t1_path)
    assert t1_after["status"] == "waiting", f"Expected waiting, got {t1_after['status']}"
    assert t1_after["fm"].get("updated") == dt.date.today().isoformat()
    assert len(t1_after["crumbs"]) == 2, f"Expected 2 crumbs, got {t1_after['crumbs']}"
    assert t1_after["crumbs"][0].endswith("· 狀態：doing -> waiting。"), f"Unexpected first crumb: {t1_after['crumbs'][0]}"
    assert "開卡。" in t1_after["crumbs"][1], f"Unexpected second crumb: {t1_after['crumbs'][1]}"

    # new_ticket writes the zh-TW headings and the breadcrumb text 開卡。
    tid = tui.new_ticket("第二個任務", "Agent Office")
    assert tid == "T-002", f"Expected T-002, got {tid}"
    t2_path = os.path.join(vault, "Tickets", "T-002 第二個任務.md")
    assert os.path.isfile(t2_path), "T-002 file not created"
    with open(t2_path, encoding="utf-8") as fh:
        raw_t2 = fh.read()
    assert "\n## 完成條件\n" in raw_t2, "Expected ## 完成條件 heading in new ticket"
    assert "\n## 子任務\n" in raw_t2, "Expected ## 子任務 heading in new ticket"
    assert "\n## Decisions\n" in raw_t2, "Expected ## Decisions heading in new ticket"
    assert "\n## Breadcrumb\n" in raw_t2, "Expected ## Breadcrumb heading in new ticket"

    t2 = tui.parse_ticket(t2_path)
    assert t2["id"] == "T-002"
    assert t2["status"] == "inbox"
    assert t2["delegated"] is False
    assert len(t2["crumbs"]) == 1, f"Expected 1 crumb in new ticket, got {t2['crumbs']}"
    assert t2["crumbs"][0].endswith("· 開卡。"), f"Expected new ticket crumb to end with '· 開卡。', got {t2['crumbs'][0]}"


if __name__ == "__main__":
    main()
