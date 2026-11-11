#!/usr/bin/env python3
"""Tests for Spec D: session add-on (install.py and hook.py)."""
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


def hook_cmd_count(settings_data, event_name):
    groups = settings_data.get("hooks", {}).get(event_name, [])
    count = 0
    for g in groups:
        for h in g.get("hooks", []):
            if "hook.py" in h.get("command", ""):
                count += 1
    return count


def run_hook(hook_py, vault, payload, env_extra):
    env = os.environ.copy()
    for k in ("TK_TICKET", "TK_HEADLESS", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID"):
        env.pop(k, None)
    env.update(env_extra)
    stdin_text = payload if isinstance(payload, str) else json.dumps(payload)
    r = subprocess.run(
        [sys.executable, "-I", hook_py],
        input=stdin_text,
        cwd=vault,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert r.returncode == 0, f"hook.py must always exit 0, got {r.returncode}: stderr={r.stderr}"
    assert r.stdout == "" and r.stderr == "", f"hook.py must never print, got stdout={r.stdout!r} stderr={r.stderr!r}"


def main():
    vault = sys.argv[1]
    ao_dir = os.path.join(vault, ".tarokaja")
    hook_py = os.path.join(ao_dir, "addons", "session", "hook.py")
    install_py = os.path.join(ao_dir, "addons", "session", "install.py")

    assert os.path.isfile(hook_py), f"Missing {hook_py}"
    assert os.path.isfile(install_py), f"Missing {install_py}"

    # 1. Test addons/session/install.py VAULT [--remove]
    claude_dir = os.path.join(vault, ".claude")
    settings_path = os.path.join(claude_dir, "settings.json")
    os.makedirs(claude_dir, exist_ok=True)
    # Remove any backup files from the initial install.sh call so we can test backup creation cleanly
    for name in os.listdir(claude_dir):
        if name != "settings.json":
            os.remove(os.path.join(claude_dir, name))

    initial_settings = {
        "env": {"KEEP_SETTING": "1"},
        "hooks": {
            "Stop": [
                {"hooks": [{"type": "command", "command": "echo existing-stop-hook"}]}
            ]
        },
    }
    write_text(settings_path, json.dumps(initial_settings, indent=2) + "\n")

    r1 = subprocess.run([sys.executable, "-I", install_py, vault], cwd=vault, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert r1.returncode == 0, f"install.py failed: {r1.stderr}"

    # Backup file created next to settings.json when it existed
    backups = [n for n in os.listdir(claude_dir) if n != "settings.json" and n.startswith("settings.json")]
    assert len(backups) >= 1, f"Expected backup file next to settings.json, found: {os.listdir(claude_dir)}"

    data1 = json.loads(read_text(settings_path))
    assert data1.get("env") == {"KEEP_SETTING": "1"}, f"Other settings lost: {data1}"
    for ev in ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"):
        assert hook_cmd_count(data1, ev) == 1, f"Expected 1 hook.py entry in {ev}, got {data1}"
    stop_cmds = [h.get("command", "") for g in data1["hooks"]["Stop"] for h in g.get("hooks", [])]
    assert "echo existing-stop-hook" in stop_cmds, f"Existing Stop hook lost: {stop_cmds}"

    # Running install.py twice adds no duplicate
    r2 = subprocess.run([sys.executable, "-I", install_py, vault], cwd=vault, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert r2.returncode == 0, f"Second install.py run failed: {r2.stderr}"
    data2 = json.loads(read_text(settings_path))
    for ev in ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"):
        assert hook_cmd_count(data2, ev) == 1, f"Duplicate hook added in {ev}: {data2}"

    # --remove takes only its own entries out
    r3 = subprocess.run([sys.executable, "-I", install_py, vault, "--remove"], cwd=vault, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert r3.returncode == 0, f"install.py --remove failed: {r3.stderr}"
    data3 = json.loads(read_text(settings_path))
    assert data3.get("env") == {"KEEP_SETTING": "1"}, f"Other settings lost on --remove: {data3}"
    for ev in ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"):
        assert hook_cmd_count(data3, ev) == 0, f"hook.py entry still present in {ev} after --remove: {data3}"
    stop_cmds_after = [h.get("command", "") for g in data3.get("hooks", {}).get("Stop", []) for h in g.get("hooks", [])]
    assert stop_cmds_after == ["echo existing-stop-hook"], f"Existing Stop hook not preserved after --remove: {data3}"

    # Re-install hook for the vault
    subprocess.run([sys.executable, "-I", install_py, vault], cwd=vault, check=True, stdout=subprocess.DEVNULL)

    # 2. Test hook.py behavior
    sessions_dir = os.path.join(ao_dir, "logs", "sessions")
    t1_path = os.path.join(vault, "Tickets", "T-001 Try Tarokaja.md")

    # Bad input -> exits 0, no output
    run_hook(hook_py, vault, "not-valid-json{{{", {"TK_TICKET": "T-001"})
    run_hook(hook_py, vault, "", {"TK_TICKET": "T-001"})

    # No TK_TICKET -> does nothing
    run_hook(hook_py, vault, {
        "session_id": "sess-no-ticket",
        "hook_event_name": "SessionStart",
        "cwd": vault,
        "transcript_path": "/tmp/sess-no-ticket.jsonl",
    }, {})
    assert not os.path.exists(os.path.join(sessions_dir, "sess-no-ticket.json")), "hook.py acted without TK_TICKET"

    # TK_HEADLESS set -> does nothing
    run_hook(hook_py, vault, {
        "session_id": "sess-headless",
        "hook_event_name": "UserPromptSubmit",
        "cwd": vault,
        "transcript_path": "/tmp/sess-headless.jsonl",
    }, {"TK_TICKET": "T-001", "TK_HEADLESS": "1"})
    assert not os.path.exists(os.path.join(sessions_dir, "sess-headless.json")), "hook.py acted when TK_HEADLESS=1"

    # Active session 1 with TK_TICKET=T-001 and timelog enabled
    env_s1 = {
        "TK_TICKET": "T-001",
        "CMUX_SURFACE_ID": "surface:1",
        "CMUX_WORKSPACE_ID": "workspace:2",
    }
    sid1 = "sess-0001-aaaa"
    run_hook(hook_py, vault, {
        "session_id": sid1,
        "hook_event_name": "UserPromptSubmit",
        "cwd": vault,
        "transcript_path": f"/tmp/{sid1}.jsonl",
    }, env_s1)

    s1_file = os.path.join(sessions_dir, f"{sid1}.json")
    assert os.path.isfile(s1_file), f"Missing session record {s1_file}"
    rec1 = json.loads(read_text(s1_file))
    assert rec1.get("session") == sid1, f"Expected session={sid1}, got {rec1}"
    assert rec1.get("ticket") == "T-001", f"Expected ticket=T-001, got {rec1}"
    assert rec1.get("surface") == "surface:1", f"Expected surface=surface:1, got {rec1}"
    assert rec1.get("workspace") == "workspace:2", f"Expected workspace=workspace:2, got {rec1}"
    assert isinstance(rec1.get("last_seen"), int), f"Expected int last_seen, got {rec1}"
    assert fm_value(t1_path, "session") == sid1, f"Expected ticket frontmatter session={sid1}, got {fm_value(t1_path, 'session')}"

    # PostToolUse twice within 60s -> at most one agent_tick
    run_hook(hook_py, vault, {
        "session_id": sid1,
        "hook_event_name": "PostToolUse",
        "cwd": vault,
        "transcript_path": f"/tmp/{sid1}.jsonl",
    }, env_s1)
    run_hook(hook_py, vault, {
        "session_id": sid1,
        "hook_event_name": "PostToolUse",
        "cwd": vault,
        "transcript_path": f"/tmp/{sid1}.jsonl",
    }, env_s1)

    # Stop -> agent_end
    run_hook(hook_py, vault, {
        "session_id": sid1,
        "hook_event_name": "Stop",
        "cwd": vault,
        "transcript_path": f"/tmp/{sid1}.jsonl",
    }, env_s1)

    t1_time_log = os.path.join(ao_dir, "logs", "time", "T-001.jsonl")
    assert os.path.isfile(t1_time_log), f"Expected timelog events in {t1_time_log}"
    with open(t1_time_log, encoding="utf-8") as fh:
        s1_events = [json.loads(line) for line in fh if line.strip()]
    s1_kinds = [(e["kind"], e["ref"]) for e in s1_events if e.get("ref") == sid1]
    assert s1_kinds == [
        ("agent_start", sid1),
        ("agent_tick", sid1),
        ("agent_end", sid1),
    ], f"Expected start, single throttled tick, end for {sid1}, got {s1_kinds}"

    # New session sid2 for T-001 -> updates frontmatter session: sid2 and clears ticket in sid1 record
    sid2 = "sess-0002-bbbb"
    run_hook(hook_py, vault, {
        "session_id": sid2,
        "hook_event_name": "SessionStart",
        "cwd": vault,
        "transcript_path": f"/tmp/{sid2}.jsonl",
    }, env_s1)

    assert fm_value(t1_path, "session") == sid2, f"Expected ticket frontmatter session={sid2}, got {fm_value(t1_path, 'session')}"
    rec1_after = json.loads(read_text(s1_file))
    assert not rec1_after.get("ticket"), f"Expected old session ticket to be cleared, got {rec1_after}"
    rec2 = json.loads(read_text(os.path.join(sessions_dir, f"{sid2}.json")))
    assert rec2.get("ticket") == "T-001", f"Expected new session ticket=T-001, got {rec2}"


if __name__ == "__main__":
    main()
