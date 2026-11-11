#!/usr/bin/env python3
"""Agent Office TUI: the manager's view of the office, in the terminal.

    python3 .agent-office/tui.py               interactive view
    python3 .agent-office/tui.py --print       print the board once and exit (no curses)

Three columns: places (left), tickets (middle), the selected ticket (right).
It reads Tickets/*.md directly. It writes only small frontmatter changes and
breadcrumbs. All agent work runs through the scripts next to this file.
Python 3.8+ standard library only.
"""
import curses
import datetime as dt
import os
import re
import shlex
import subprocess
import sys
import time
import unicodedata
import urllib.parse

AO_DIR = os.path.dirname(os.path.abspath(__file__))
VAULT = os.path.dirname(AO_DIR)
TICKETS = os.path.join(VAULT, "Tickets")
LOGS = os.path.join(AO_DIR, "logs")

STATUSES = ["inbox", "backlog", "todo", "doing", "waiting", "done", "dropped"]
OPEN_ORDER = ["doing", "waiting", "todo", "inbox", "backlog"]
CLOSED = ("done", "dropped")
DELEGATED_RE = re.compile(r"^\s*- \[ \] .*\(agent\)\s*$")
SUBTASK_RE = re.compile(r"^\s*- \[( |x|X)\] (.*)$")
POLL = 3.0

HELP = [
    "Move        up/down or j/k    Column  left/right, h/l, Tab",
    "Enter / t   talk to the agent about the ticket",
    "m           hold the meeting            M  set the meeting time",
    "w           start a work session now    p  write the meeting agenda now",
    "s           set the status              n  new ticket",
    "o           open the ticket in Obsidian r  reload       q  quit",
]


# ----------------------------------------------------------------- text width

def cwidth(c):
    if unicodedata.combining(c):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


def width(s):
    return sum(cwidth(c) for c in s)


def fit(s, w):
    """Cut or pad s to exactly w display cells."""
    out, n = [], 0
    for c in s:
        cw = cwidth(c)
        if n + cw > w:
            break
        out.append(c)
        n += cw
    return "".join(out) + " " * (w - n)


def wrap(s, w, indent=""):
    lines, cur, n = [], "", 0
    for c in s:
        cw = cwidth(c)
        if n + cw > w:
            lines.append(cur)
            cur, n = indent, width(indent)
        cur += c
        n += cw
    lines.append(cur)
    return lines


# ----------------------------------------------------------------- tickets

def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def parse_ticket(path):
    text = read_text(path)
    lines = text.split("\n")
    fm = {}
    body_start = 0
    if lines and lines[0] == "---":
        for i in range(1, len(lines)):
            if lines[i] == "---":
                body_start = i + 1
                break
            m = re.match(r"^([A-Za-z_]+):\s*(.*)$", lines[i])
            if m:
                fm[m.group(1)] = m.group(2).strip().strip('"')
    body = lines[body_start:]
    title = os.path.basename(path)[:-3]
    section = None
    subtasks, crumbs = [], []
    for ln in body:
        if ln.startswith("# "):
            title = ln[2:].strip()
        if ln.startswith("## "):
            section = ln[3:].strip().lower()
            continue
        m = SUBTASK_RE.match(ln)
        if section == "subtasks" and m:
            subtasks.append((m.group(1) != " ", m.group(2)))
        elif section == "breadcrumbs" and ln.startswith("- "):
            crumbs.append(ln[2:])
    tid = os.path.basename(path).split(" ")[0]   # the scripts find tickets by file name
    return {
        "path": path, "id": tid, "title": title, "fm": fm,
        "status": fm.get("status", "inbox"), "project": fm.get("project", "") or "Other",
        "subtasks": subtasks, "crumbs": crumbs,
        "delegated": fm.get("owner") == "agent" or any(DELEGATED_RE.match(ln) for ln in body),
    }


def load_tickets():
    out = []
    try:
        names = sorted(os.listdir(TICKETS))
    except OSError:
        return out
    for n in names:
        if re.match(r"^T-\d+ .*\.md$", n):
            out.append(parse_ticket(os.path.join(TICKETS, n)))
    return out


def tickets_mtime():
    try:
        return max([os.path.getmtime(TICKETS)] + [os.path.getmtime(os.path.join(TICKETS, n)) for n in os.listdir(TICKETS)])
    except (OSError, ValueError):
        return 0


def running_kind(tid):
    """'work' or 'prep' when a background session runs on the ticket, else ''."""
    for name, kind in ((".pid", None), (".meeting.pid", "meeting")):
        try:
            pid = int(read_text(os.path.join(LOGS, tid + name)).strip())
            os.kill(pid, 0)
        except (ValueError, OSError):
            continue
        return kind or read_text(os.path.join(LOGS, tid + ".kind")).strip() or "work"
    return ""


def id_num(tid):
    m = re.match(r"T-(\d+)", tid)
    return int(m.group(1)) if m else 0


def now_min():
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M")


def set_fields(path, changes, crumb=None):
    """Set frontmatter scalars and add a manager breadcrumb at the top of ## Breadcrumbs."""
    lines = read_text(path).split("\n")
    changes = dict(changes)
    changes["updated"] = dt.date.today().isoformat()
    if lines and lines[0] == "---":
        end = next((i for i in range(1, len(lines)) if lines[i] == "---"), None)
        if end is not None:
            seen = set()
            for i in range(1, end):
                m = re.match(r"^([A-Za-z_]+):", lines[i])
                if m and m.group(1) in changes:
                    lines[i] = "%s: %s" % (m.group(1), changes[m.group(1)])
                    seen.add(m.group(1))
            missing = ["%s: %s" % (k, v) for k, v in changes.items() if k not in seen]
            lines[end:end] = missing
    if crumb:
        entry = "- %s · %s" % (now_min(), crumb)
        try:
            i = next(i for i, ln in enumerate(lines) if ln.strip().lower() == "## breadcrumbs")
            j = i + 1
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            lines[j:j] = [entry]
            if lines[i + 1].strip() != "":
                lines.insert(i + 1, "")
        except StopIteration:
            lines += ["", "## Breadcrumbs", "", entry]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, path)


def new_ticket(title, project):
    title = re.sub(r'[\\/:*?"<>|#^\[\]]', " ", title).strip()
    if not title:
        return None
    nums = [id_num(t["id"]) for t in load_tickets()]
    tid = "T-%03d" % (max(nums + [0]) + 1)
    today = dt.date.today().isoformat()
    path = os.path.join(TICKETS, "%s %s.md" % (tid, title))
    text = "\n".join([
        "---", "id: " + tid, "status: inbox", "project: " + project,
        "created: " + today, "updated: " + today, "due:", "waiting_on:", "owner:",
        "meeting:", "agent_state:", "links: []", "---", "# " + title, "",
        "## Done when", "", "## Subtasks", "", "## Decisions", "",
        "## Breadcrumbs", "", "- %s · Opened." % now_min(), "",
    ])
    with open(path, "x", encoding="utf-8") as fh:
        fh.write(text)
    return tid


# ----------------------------------------------------------------- model

def places(tickets):
    """Left column: (key, label, count)."""
    open_t = [t for t in tickets if t["status"] not in CLOSED]
    out = [("needs", "Needs me", sum(1 for t in tickets if t["fm"].get("agent_state"))),
           ("open", "All open", len(open_t))]
    for p in sorted({t["project"] for t in open_t}):
        out.append(("p:" + p, p, sum(1 for t in open_t if t["project"] == p)))
    out.append(("closed", "Closed", sum(1 for t in tickets if t["status"] in CLOSED)))
    return out


def in_place(t, key):
    if key == "needs":
        return bool(t["fm"].get("agent_state"))
    if key == "closed":
        return t["status"] in CLOSED
    if t["status"] in CLOSED:
        return False
    return key == "open" or key == "p:" + t["project"]


def rows_for(tickets, key):
    """Middle column: list of ('head', text) and ('t', ticket), grouped by status."""
    sel = [t for t in tickets if in_place(t, key)]
    order = list(CLOSED) if key == "closed" else OPEN_ORDER
    rows = []
    for st in order:
        group = sorted((t for t in sel if t["status"] == st), key=lambda t: id_num(t["id"]))
        if group:
            rows.append(("head", "%s (%d)" % (st, len(group))))
            rows += [("t", t) for t in group]
    return rows


def marker(t):
    kind = running_kind(t["id"])
    if kind:
        return "⚙"
    state = t["fm"].get("agent_state")
    if state == "decide":
        return "?"
    if state == "review":
        return "✓"
    return "·" if t["delegated"] else " "


def detail_lines(t, w):
    fm = t["fm"]
    out = [("title", t["id"] + " " + t["title"])]
    meta = [t["status"], t["project"]]
    if fm.get("due"):
        meta.append("due " + fm["due"])
    out.append(("dim", " · ".join(meta)))
    kind = running_kind(t["id"])
    if kind:
        out.append(("warn", "⚙ background %s session running" % kind))
    if fm.get("agent_state"):
        out.append(("warn", "Agent waits for you: %s" % fm["agent_state"]))
    if fm.get("waiting_on"):
        out.append(("", "Waiting on: " + fm["waiting_on"]))
    if fm.get("meeting"):
        out.append(("", "Next meeting: " + fm["meeting"]))
    if fm.get("agent_dir"):
        out.append(("dim", "agent_dir: " + fm["agent_dir"]))
    if t["subtasks"]:
        done = sum(1 for d, _ in t["subtasks"] if d)
        out.append(("", ""))
        out.append(("head", "Subtasks %d/%d" % (done, len(t["subtasks"]))))
        for d, text in t["subtasks"]:
            out.append(("dim" if d else "", ("☑ " if d else "☐ ") + text))
    if t["crumbs"]:
        out.append(("", ""))
        out.append(("head", "Breadcrumbs"))
        for c in t["crumbs"][:4]:
            out.append(("", c))
    last = os.path.join(LOGS, t["id"] + "-last-work.txt")
    if os.path.exists(last):
        tail = [ln for ln in read_text(last).strip().split("\n") if ln.strip()][-3:]
        if tail:
            out.append(("", ""))
            out.append(("head", "Last work session"))
            out += [("dim", ln) for ln in tail]
    wrapped = []
    for style, text in out:
        for ln in wrap(text, max(w, 10), "  "):
            wrapped.append((style, ln))
    return wrapped


# ----------------------------------------------------------------- actions

def in_cmux():
    return bool(os.environ.get("CMUX_WORKSPACE_ID")) and subprocess.call(
        ["sh", "-c", "command -v cmux"], stdout=subprocess.DEVNULL) == 0


def open_split(cmd):
    """Run an interactive command in a cmux split on the right. Return False when not in cmux."""
    if not in_cmux():
        return False
    line = "cd %s && %s" % (shlex.quote(VAULT), " ".join(shlex.quote(c) for c in cmd))
    r = subprocess.run(["cmux", "new-split", "right", "--command", line],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def start_bg(script, tid):
    os.makedirs(LOGS, exist_ok=True)
    with open(os.path.join(LOGS, "tui-bg.log"), "a") as err:
        subprocess.Popen(["/bin/bash", os.path.join(AO_DIR, script), tid], cwd=VAULT,
                         stdout=err, stderr=err, stdin=subprocess.DEVNULL, start_new_session=True)


def open_in_obsidian(path):
    rel = os.path.relpath(path, VAULT)
    url = "obsidian://open?vault=%s&file=%s" % (
        urllib.parse.quote(os.path.basename(VAULT)), urllib.parse.quote(rel[:-3]))
    subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ----------------------------------------------------------------- app

class App:
    def __init__(self):
        self.col = 1
        self.place = 1
        self.row = 0
        self.msg = "? for help"
        self.help = False
        self.reload()

    def reload(self):
        self.tickets = load_tickets()
        self.mtime = tickets_mtime()
        self.places = places(self.tickets)
        self.place = min(self.place, len(self.places) - 1)
        self.rows = rows_for(self.tickets, self.places[self.place][0])
        self.fix_row()

    def fix_row(self, step=1):
        if not self.rows:
            self.row = 0
            return
        self.row = max(0, min(self.row, len(self.rows) - 1))
        n = 0
        while self.rows[self.row][0] != "t" and n < len(self.rows):
            self.row = (self.row + step) % len(self.rows)
            n += 1

    def current(self):
        if self.rows and self.rows[self.row][0] == "t":
            return self.rows[self.row][1]
        return None

    def move(self, d):
        if self.col == 0:
            self.place = max(0, min(self.place + d, len(self.places) - 1))
            self.row = 0
            self.rows = rows_for(self.tickets, self.places[self.place][0])
            self.fix_row()
        elif self.rows:
            r = self.row
            while True:
                r += d
                if r < 0 or r >= len(self.rows):
                    return
                if self.rows[r][0] == "t":
                    self.row = r
                    return

    # ---- drawing

    def draw(self, scr):
        try:
            self._draw(scr)
        except curses.error:
            # A resize during drawing, or a terminal that draws ambiguous-width
            # characters as 2 cells, can push text past the last cell. Skip this frame.
            pass

    def _draw(self, scr):
        scr.erase()
        h, w = scr.getmaxyx()
        if h < 10 or w < 60:
            scr.addstr(0, 0, fit("Make the window bigger (60x10 at least).", w - 1))
            scr.refresh()
            return
        cur = self.current()
        need = sum(1 for t in self.tickets if t["fm"].get("agent_state"))
        run = sum(1 for t in self.tickets if running_kind(t["id"]))
        head = " Agent Office   %s needs you   %s running" % (need, run)
        scr.addstr(0, 0, fit(head, w - 1 - 6) + time.strftime("%H:%M"), curses.A_REVERSE)
        lw, mw = 18, max(30, (w - 18) // 2 - 4)
        rw = w - lw - mw - 3
        top = 2
        body_h = h - top - 2
        # column titles
        scr.addstr(1, 0, fit(" Places", lw), self.title_attr(0))
        scr.addstr(1, lw + 1, fit(" " + self.places[self.place][1], mw), self.title_attr(1))
        scr.addstr(1, lw + mw + 2, fit(" " + (cur["id"] if cur else ""), rw), curses.A_BOLD)
        # left
        for i, (_, label, n) in enumerate(self.places[:body_h]):
            text = " %s%s" % (fit(label, lw - 5), str(n).rjust(3))
            attr = curses.A_REVERSE if i == self.place and self.col == 0 else (curses.A_BOLD if i == self.place else 0)
            scr.addstr(top + i, 0, fit(text, lw), attr)
        # middle
        first = max(0, self.row - body_h + 1)
        for i, (kind, item) in enumerate(self.rows[first:first + body_h]):
            y = top + i
            if kind == "head":
                scr.addstr(y, lw + 1, fit(" " + item, mw), curses.A_DIM | curses.A_UNDERLINE)
                continue
            text = " %s %s %s" % (marker(item), item["id"], item["title"])
            attr = curses.A_REVERSE if first + i == self.row and self.col == 1 else 0
            scr.addstr(y, lw + 1, fit(text, mw), attr)
        if not self.rows:
            scr.addstr(top, lw + 1, fit(" (no tickets)", mw), curses.A_DIM)
        # right
        if cur:
            styles = {"title": curses.A_BOLD, "head": curses.A_UNDERLINE, "dim": curses.A_DIM,
                      "warn": curses.A_BOLD | self.color(1), "": 0}
            for i, (style, ln) in enumerate(detail_lines(cur, rw - 2)[:body_h]):
                scr.addstr(top + i, lw + mw + 2, fit(" " + ln, rw - 1), styles.get(style, 0))
        # separators
        for y in range(1, h - 1):
            scr.addstr(y, lw, "│", curses.A_DIM)
            scr.addstr(y, lw + mw + 1, "│", curses.A_DIM)
        if self.help:
            for i, ln in enumerate(HELP):
                scr.addstr(h - 2 - len(HELP) + i, lw + 1, fit(" " + ln, w - lw - 2), curses.A_REVERSE)
        legend = " ⚙ running  ? decide  ✓ review  · delegated "
        scr.addstr(h - 1, 0, fit(" " + self.msg, w - 1 - width(legend)) + legend, curses.A_DIM)
        scr.refresh()

    def title_attr(self, col):
        return curses.A_BOLD | (curses.A_UNDERLINE if self.col == col else 0)

    @staticmethod
    def color(n):
        return curses.color_pair(n) if curses.has_colors() else 0

    # ---- input

    def ask(self, scr, prompt, default=""):
        h, w = scr.getmaxyx()
        curses.curs_set(1)
        text = default
        while True:
            scr.addstr(h - 1, 0, fit(" " + prompt + text, w - 1), curses.A_REVERSE)
            scr.refresh()
            try:
                ch = scr.get_wch()
            except curses.error:
                continue
            if ch in ("\n", "\r", curses.KEY_ENTER):
                break
            if ch == "\x1b":
                text = None
                break
            if ch in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                text = text[:-1]
            elif isinstance(ch, str) and ch.isprintable():
                text += ch
        curses.curs_set(0)
        return text

    def pick_status(self, scr):
        choices = {"i": "inbox", "b": "backlog", "t": "todo", "d": "doing", "w": "waiting", "o": "done", "x": "dropped"}
        a = self.ask(scr, "Status: i inbox  b backlog  t todo  d doing  w waiting  o done  x dropped > ")
        return choices.get((a or "").strip()[:1])

    def interactive(self, scr, args, what):
        if open_split(["/bin/bash"] + args):
            self.msg = what + " opened in a split on the right"
            return
        curses.endwin()
        subprocess.call(["/bin/bash"] + args, cwd=VAULT)
        scr.refresh()
        self.msg = what + " ended"

    def act(self, scr, key):
        cur = self.current()
        if key in ("q", "Q"):
            return False
        if key == "?":
            self.help = not self.help
        elif key in ("j", curses.KEY_DOWN):
            self.move(1)
        elif key in ("k", curses.KEY_UP):
            self.move(-1)
        elif key in ("h", curses.KEY_LEFT):
            self.col = 0
        elif key in ("l", curses.KEY_RIGHT):
            self.col = 1
        elif key == "\t":
            self.col = 1 - self.col
        elif key == "r":
            self.reload()
            self.msg = "Reloaded"
        elif key == "n":
            p = self.places[self.place][0]
            project = p[2:] if p.startswith("p:") else "Other"
            title = self.ask(scr, "New ticket title (%s): " % project)
            if title:
                try:
                    tid = new_ticket(title[:120], project)
                    self.msg = ("%s opened in inbox" % tid) if tid else "Title is empty"
                except OSError as e:
                    self.msg = "Cannot create the ticket: %s" % e.strerror
                self.reload()
        elif cur is None:
            pass
        elif key in ("\n", "\r", "t", curses.KEY_ENTER):
            self.interactive(scr, [os.path.join(AO_DIR, "meeting.sh"), cur["id"], "--talk"], "Talk with %s" % cur["id"])
        elif key == "m":
            self.interactive(scr, [os.path.join(AO_DIR, "meeting.sh"), cur["id"]], "Meeting for %s" % cur["id"])
        elif key == "w":
            if not cur["delegated"]:
                self.msg = "%s has no subtask marked (agent). Talk to the agent to delegate one." % cur["id"]
            elif cur["status"] != "doing":
                self.msg = "%s is %s. Work sessions run only on doing tickets." % (cur["id"], cur["status"])
            elif cur["fm"].get("agent_state"):
                self.msg = "%s waits for you (%s). Hold a meeting first (m)." % (cur["id"], cur["fm"]["agent_state"])
            elif running_kind(cur["id"]):
                self.msg = "%s already has a session running" % cur["id"]
            else:
                start_bg("work.sh", cur["id"])
                self.msg = "%s work session started" % cur["id"]
        elif key == "p":
            if not cur["fm"].get("meeting"):
                self.msg = "Set the meeting time first (M)"
            elif running_kind(cur["id"]):
                self.msg = "%s already has a session running" % cur["id"]
            else:
                start_bg("prep.sh", cur["id"])
                self.msg = "%s agenda is being written" % cur["id"]
        elif key in ("M", "s") and running_kind(cur["id"]):
            self.msg = "%s has a session running. Change it after the session ends." % cur["id"]
        elif key == "M":
            v = self.ask(scr, "Meeting time YYYY-MM-DD HH:MM (empty clears): ", cur["fm"].get("meeting", ""))
            if v is not None:
                v = v.strip()
                try:
                    if v:
                        dt.datetime.strptime(v, "%Y-%m-%d %H:%M")
                    set_fields(cur["path"], {"meeting": v})
                    self.msg = "%s meeting: %s" % (cur["id"], v or "cleared")
                except ValueError:
                    self.msg = "Use the format YYYY-MM-DD HH:MM"
                self.reload()
        elif key == "s":
            st = self.pick_status(scr)
            if st and st != cur["status"]:
                changes = {"status": st}
                if st != "waiting":
                    changes.update({"waiting_on": "", "agent_state": ""})
                set_fields(cur["path"], changes, "Status: %s → %s." % (cur["status"], st))
                self.reload()
                self.msg = "%s is now %s" % (cur["id"], st)
        elif key == "o":
            open_in_obsidian(cur["path"])
            self.msg = "Opened %s in Obsidian" % cur["id"]
        return True


def main_loop(scr):
    curses.curs_set(0)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_YELLOW, -1)
    scr.timeout(int(POLL * 1000))
    app = App()
    while True:
        app.draw(scr)
        try:
            key = scr.get_wch()
        except curses.error:
            key = None
        if key is None or key == curses.KEY_RESIZE:
            if tickets_mtime() != app.mtime:
                app.reload()
            continue
        if not app.act(scr, key):
            return


def print_board():
    tickets = load_tickets()
    for key, label, n in places(tickets):
        if key.startswith("p:") or key == "closed":
            continue
        print("%s (%d)" % (label, n))
        for kind, item in rows_for(tickets, key):
            if kind == "head":
                print("  " + item)
            else:
                state = item["fm"].get("agent_state")
                print("    %s %s %s%s" % (marker(item), item["id"], item["title"], "  [%s]" % state if state else ""))


def main(argv):
    if not os.path.isdir(TICKETS):
        sys.stderr.write("Cannot find %s. Run the TUI from an Agent Office vault.\n" % TICKETS)
        return 1
    if "--print" in argv:
        print_board()
        return 0
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(main_loop)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
