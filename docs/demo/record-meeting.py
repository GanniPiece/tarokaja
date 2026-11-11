#!/usr/bin/env python3
"""Record the meeting demo: a REAL Claude Code meeting on T-002 in the demo vault.

Usage (from the repo root):
  python3 docs/demo/record-meeting.py              # writes docs/demo/meeting.cast
  agg --theme 1e1e2e,cdd6f4,45475a,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,bac2de,585b70,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,a6adc8 \\
      --font-family "Menlo,Apple Symbols" --font-size 15 --idle-time-limit 3 --last-frame-duration 4 docs/demo/meeting.cast docs/demo/meeting.gif

The script types the keys in a pseudo-terminal and waits for each Claude reply, so a slow API
only makes the wait longer. It uses your Claude login and a few tokens. Needs `pip install pyte`.
Before the first run, start `claude` once in ~/tarokaja-demo and answer "Yes, I trust this folder".
"""
import atexit
import codecs
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import fcntl
import time

import pyte   # pip install pyte: a terminal screen model, to see when Claude is idle

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VAULT = os.path.expanduser("~/tarokaja-demo")
OUT = os.path.join(ROOT, "docs", "demo", "meeting.cast")
COLS, ROWS = 140, 36
BUSY = re.compile(r"\u2026|Waiting for API")   # a spinner or tool line ("Whisking…", "Reading 2 files…")

events, start = [], None
end_at = [None]   # the number of events to save; None saves all
fd = None
screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
decoder = codecs.getincrementaldecoder("utf-8")("replace")   # a character can span two reads


def pump(timeout):
    """Read the terminal output for up to TIMEOUT seconds, record it, and update the screen model."""
    end = time.time() + timeout
    while True:
        left = end - time.time()
        if left <= 0:
            return True
        r, _, _ = select.select([fd], [], [], min(left, 0.1))
        if not r:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            return False   # the program ended
        if not data:
            return False
        events.append([round(time.time() - start, 4), "o", decoder.decode(data)])
        stream.feed(data)


def text():
    return "\n".join(line.rstrip() for line in screen.display)


def save():
    if not events:
        return
    with open(OUT, "w") as f:
        f.write(json.dumps({"version": 2, "width": COLS, "height": ROWS, "timestamp": int(start),
                            "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"}}) + "\n")
        for e in events[:end_at[0]]:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    print("Wrote %s (%d events, %.0fs)" % (OUT, len(events), events[-1][0]))


def wait_for(pattern, timeout, what):
    """Wait until the screen shows PATTERN."""
    rx = re.compile(pattern)
    end = time.time() + timeout
    while not rx.search(text()):
        if time.time() > end or not pump(0.3):
            sys.exit("Stopped while waiting for %s. Screen:\n%s" % (what, text()))


def wait_reply(timeout, what):
    """Wait until Claude has started to work and then stays idle (no spinner) for 3 seconds."""
    end = time.time() + timeout
    while not BUSY.search(text()):
        if time.time() > end or not pump(0.3):
            sys.exit("Claude did not start on %s. Screen:\n%s" % (what, text()))
    idle = None
    while True:
        if time.time() > end or not pump(0.3):
            sys.exit("Stopped while waiting for %s. Screen:\n%s" % (what, text()))
        if "trust this folder" in text():
            sys.exit("Claude Code does not trust %s yet. Run claude there once and answer Yes." % VAULT)
        if BUSY.search(text()):
            idle = None
        elif idle is None:
            idle = time.time()
        elif time.time() - idle >= 3:
            return


def send(keys, delay=0.045):
    for ch in keys:
        os.write(fd, ch.encode())
        pump(delay)


def main():
    global fd, start
    subprocess.run([os.path.join(ROOT, "docs", "demo", "make-vault.sh"), VAULT],
                   check=True, stdout=subprocess.DEVNULL)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_", "CLAUDE"))}
    env.update(PATH=os.path.join(ROOT, "docs", "demo", "bin-meeting") + ":" + env["PATH"],
               TERM="xterm-256color", PS1="> ", COLUMNS=str(COLS), LINES=str(ROWS))
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(VAULT)
        os.execvpe("bash", ["bash", "--norc", "--noprofile", "-i"], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    start = time.time()
    atexit.register(save)

    pump(1.5)
    events.clear()                      # drop the shell start-up noise
    start = time.time()
    os.write(fd, b"clear\r")
    pump(1)
    send("python3 .tarokaja/tui.py")
    pump(0.3)
    send("\r")
    wait_for(r"Places", 10, "the board")
    pump(2)
    send("j")                           # T-002 waits for a decision
    pump(2.5)
    send("m")                           # hold the meeting
    wait_reply(300, "the D1 question")
    pump(3)
    send("A, the lake house. 9 of 12 people asked for a day outside.")
    pump(0.5)
    send("\r")
    wait_reply(300, "the reply to the decision")
    pump(4)
    send("No next meeting for now. Thanks!")
    pump(0.5)
    send("\r")
    wait_reply(300, "the closing reply")
    pump(5)
    send("/exit")
    pump(0.8)
    send("\r")
    wait_for(r"ended", 30, "the board after the meeting")
    pump(5)                             # T-002 is doing again, still selected
    end_at[0] = len(events)             # the GIF ends on the board: quitting is not saved
    send("q")
    pump(1)
    send("exit\r")
    pump(2)


if __name__ == "__main__":
    main()
