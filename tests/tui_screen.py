#!/usr/bin/env python3
"""Run the TUI in a pseudo-terminal, press keys, quit, and check the screen text.

    tui_screen.py VAULT LANG     exit 0 when the TUI drew the expected words and quit cleanly
"""
import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

EXPECT = {
    "en": ["Tarokaja", "Places", "Needs me", "T-001", "Subtasks", "talk to the agent"],
    "zh-TW": ["Tarokaja", "位置", "等我", "T-001", "子任務", "跟 agent 談這張卡"],
}


def main():
    vault, lang = sys.argv[1], sys.argv[2]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(vault)
        os.environ["TERM"] = "xterm-256color"
        os.environ.pop("CMUX_WORKSPACE_ID", None)
        os.execvp("python3", ["python3", ".tarokaja/tui.py"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    out = b""

    def pump(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    return

    pump(1.0)
    for key in (b"j", b"k", b"h", b"j", b"l", b"?", b"q"):
        try:
            os.write(fd, key)
        except OSError:
            break                       # the TUI exited early
        pump(0.4)
    _, status = os.waitpid(pid, 0)
    text = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b" ", out).decode("utf-8", "replace")
    missing = [w for w in EXPECT[lang] if w not in text]
    if status != 0 or missing or "Traceback" in text:
        sys.stderr.write("lang=%s exit=%s missing=%s\n%s\n" % (lang, status, missing, text[-800:]))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
