#!/usr/bin/env python3
"""Tarokaja add-on "session": add or remove its Claude Code hooks.

    install.py VAULT            add the hooks to VAULT/.claude/settings.json
    install.py VAULT --remove   remove only these hooks

The hooks go into the vault's project settings, never into ~/.claude, so they run only in this vault.
Other settings and hooks stay. A changed file is backed up first (settings.json.bak-<time>).
"""
import json
import os
import shlex
import shutil
import sys
import time

EVENTS = ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop")
MARK = "/.tarokaja/addons/session/hook.py"
OLD_MARKS = ("/.agent-office/addons/session/hook.py",)   # the hook path before the rename to Tarokaja


def strip(hooks):
    """Remove this add-on's commands from a settings "hooks" object."""
    out = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            out[event] = groups
            continue
        kept = []
        for g in groups:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                inner = [h for h in g["hooks"] if not (isinstance(h, dict) and any(m in str(h.get("command", "")) for m in (MARK,) + OLD_MARKS))]
                if not inner:
                    continue
                g = dict(g, hooks=inner)
            kept.append(g)
        if kept:
            out[event] = kept
    return out


def main(argv):
    args = [a for a in argv if a != "--remove"]
    if len(args) != 1:
        sys.stderr.write(__doc__)
        return 2
    vault = os.path.abspath(args[0])
    path = os.path.join(vault, ".claude", "settings.json")
    data = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except ValueError as e:
            sys.stderr.write("Cannot read %s: %s. Fix it, then run again.\n" % (path, e))
            return 1
        if not isinstance(data, dict):
            sys.stderr.write("%s is not a JSON object.\n" % path)
            return 1
    new = dict(data)
    hooks = strip(data.get("hooks") or {})
    if "--remove" not in argv:
        cmd = "python3 -I " + shlex.quote(vault + MARK)
        for event in EVENTS:
            hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
    if hooks:
        new["hooks"] = hooks
    else:
        new.pop("hooks", None)
    if new == data and os.path.exists(path):
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(new, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
