#!/usr/bin/env python3
"""Tarokaja TUI: the manager's view of the office, in the terminal.

    python3 .tarokaja/tui.py               interactive view
    python3 .tarokaja/tui.py --print       print the board once and exit (no curses)

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

TK_DIR = os.path.dirname(os.path.abspath(__file__))
VAULT = os.path.dirname(TK_DIR)
TICKETS = os.path.join(VAULT, "Tickets")
LOGS = os.path.join(TK_DIR, "logs")

def _conf(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                m = re.match(r"^([A-Z_]+)=(.*)$", ln.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2)
    except OSError:
        pass
    return out


def load_settings():
    """Settings in the same order as lib.sh: environment, config, profile, default."""
    config = _conf(os.path.join(TK_DIR, "config"))
    lang = os.environ.get("TK_LANG") or config.get("TK_LANG") or "en"
    if lang not in ("en", "zh-TW"):
        lang = "en"
    profile = _conf(os.path.join(TK_DIR, "profiles", lang + ".conf"))
    defaults = {"H_DONE": "## Done when", "H_SUBTASKS": "## Subtasks", "H_DECISIONS": "## Decisions",
                "H_CRUMBS": "## Breadcrumbs", "MARK": "(agent)", "CRUMB_OPENED": "Opened."}
    out = {"TK_LANG": lang}
    for k, v in defaults.items():
        out[k] = os.environ.get(k) or config.get(k) or profile.get(k) or v
    return out


S = load_settings()
LANG = S["TK_LANG"]

ZH = {
    "Places": "位置", "Needs me": "等我", "All open": "進行中", "Closed": "已關閉", "Other": "其他",
    "(no tickets)": "（沒有卡片）", "? for help": "? 看說明", "Reloaded": "已重新讀取",
    " ⚙ running  ? decide  ✓ review  · delegated ": " ⚙ 執行中  ? 等決定  ✓ 等驗收  · 已交辦 ",
    "Move        up/down or j/k    Column  left/right, h/l, Tab": "移動        上下或 j/k        切換欄  左右、h/l、Tab",
    "Enter / t   talk to the agent about the ticket": "Enter / t   跟 agent 談這張卡",
    "m           hold the meeting            M  set the meeting time": "m           開會                        M  設定會議時間",
    "w           start a work session now    p  write the meeting agenda now": "w           現在開始工作階段            p  現在寫會議議程",
    "s           set the status              n  new ticket": "s           改 status                   n  開新卡",
    "o           open the ticket in Obsidian r  reload       q  quit": "o           在 Obsidian 開啟卡片        r  重新讀取    q  離開",
    "R           this week's time (timelog add-on)": "R           本週時間（timelog add-on）",
    "Time log is off. Add timelog to ADDONS in .tarokaja/config.": "時間紀錄沒開。在 .tarokaja/config 的 ADDONS 加上 timelog。",
    "Make the window bigger (60x10 at least).": "請把視窗放大（至少 60x10）。",
    " Tarokaja   %s needs you   %s running": " Tarokaja   %s 張等你   %s 張執行中",
    "⚙ background %s session running": "⚙ 背景 %s session 執行中",
    "Agent waits for you: %s": "Agent 在等你：%s", "Waiting on: ": "等待：", "Next meeting: ": "下次會議：",
    "Subtasks %d/%d": "子任務 %d/%d", "Breadcrumbs": "Breadcrumb", "Last work session": "上次工作階段",
    "Status: i inbox  b backlog  t todo  d doing  w waiting  o done  x dropped > ":
        "Status：i inbox  b backlog  t todo  d doing  w waiting  o done  x dropped > ",
    "%s opened in a split on the right": "%s 已在右邊 split 開啟", "%s ended": "%s 已結束",
    "Talk with %s": "跟 %s 對話", "Meeting for %s": "%s 的會議",
    "New ticket title (%s): ": "新卡片標題（%s）：", "%s opened in inbox": "%s 已開卡（inbox）",
    "Title is empty": "標題是空的", "Cannot create the ticket: %s": "無法建立卡片：%s",
    "%s has no subtask marked (agent). Talk to the agent to delegate one.": "%s 沒有標（agent）的子任務。先跟 agent 談，交辦一個。",
    "%s is %s. Work sessions run only on doing tickets.": "%s 是 %s。只有 doing 的卡會跑工作階段。",
    "%s waits for you (%s). Hold a meeting first (m).": "%s 在等你（%s）。先開會（m）。",
    "%s already has a session running": "%s 已經有 session 在執行", "%s work session started": "%s 工作階段已開始",
    "Set the meeting time first (M)": "先設定會議時間（M）", "%s agenda is being written": "%s 議程撰寫中",
    "%s has a session running. Change it after the session ends.": "%s 有 session 在執行。結束後再改。",
    "Meeting time YYYY-MM-DD HH:MM (empty clears): ": "會議時間 YYYY-MM-DD HH:MM（空白＝清除）：",
    "%s meeting: %s": "%s 會議：%s", "cleared": "已清除", "Use the format YYYY-MM-DD HH:MM": "格式是 YYYY-MM-DD HH:MM",
    "%s is now %s": "%s 現在是 %s", "Opened %s in Obsidian": "已在 Obsidian 開啟 %s",
    "Status: %s → %s.": "status：%s → %s。", "due ": "期限 ",
}


def _(text):
    return ZH.get(text, text) if LANG == "zh-TW" else text


STATUSES = ["inbox", "backlog", "todo", "doing", "waiting", "done", "dropped"]
OPEN_ORDER = ["doing", "waiting", "todo", "inbox", "backlog"]
CLOSED = ("done", "dropped")
DELEGATED_RE = re.compile(r"^\s*- \[ \] .*(\(agent\)|（agent）)\s*$")
SUBTASK_RE = re.compile(r"^\s*- \[( |x|X)\] (.*)$")
POLL = 3.0

HELP = [_(x) for x in [
    "Move        up/down or j/k    Column  left/right, h/l, Tab",
    "Enter / t   talk to the agent about the ticket",
    "m           hold the meeting            M  set the meeting time",
    "w           start a work session now    p  write the meeting agenda now",
    "s           set the status              n  new ticket",
    "o           open the ticket in Obsidian r  reload       q  quit",
    "R           this week's time (timelog add-on)",
]]


def addon_on(name):
    """True when the add-on is in ADDONS (read now: the config can change while the TUI runs)."""
    val = os.environ.get("ADDONS") or _conf(os.path.join(TK_DIR, "config")).get("ADDONS", "")
    return name in [a.strip() for a in val.split(",")]


def week_report_lines():
    """This week's time per ticket from the timelog add-on, [] when it is off or fails."""
    script = os.path.join(TK_DIR, "addons", "timelog", "timelog.py")
    if not addon_on("timelog") or not os.path.isfile(script):
        return []
    try:
        r = subprocess.run([sys.executable, "-I", script, "week"], cwd=VAULT, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return []
    return r.stdout.splitlines() if r.returncode == 0 else []


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
    h_sub = {S["H_SUBTASKS"].lower(), "## subtasks"}
    h_crumb = {S["H_CRUMBS"].lower(), "## breadcrumbs", "## breadcrumb"}
    subtasks, crumbs = [], []
    for ln in body:
        if ln.startswith("# "):
            title = ln[2:].strip()
        if ln.startswith("## "):
            head = ln.strip().lower()
            section = "subtasks" if head in h_sub else "breadcrumbs" if head in h_crumb else head
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
            heads = {S["H_CRUMBS"].lower(), "## breadcrumbs", "## breadcrumb"}
            i = next(i for i, ln in enumerate(lines) if ln.strip().lower() in heads)
            j = i + 1
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            lines[j:j] = [entry]
            if lines[i + 1].strip() != "":
                lines.insert(i + 1, "")
        except StopIteration:
            lines += ["", S["H_CRUMBS"], "", entry]
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
        S["H_DONE"], "", S["H_SUBTASKS"], "", S["H_DECISIONS"], "",
        S["H_CRUMBS"], "", "- %s · %s" % (now_min(), S["CRUMB_OPENED"]), "",
    ])
    with open(path, "x", encoding="utf-8") as fh:
        fh.write(text)
    return tid


# ----------------------------------------------------------------- model

def places(tickets):
    """Left column: (key, label, count)."""
    open_t = [t for t in tickets if t["status"] not in CLOSED]
    out = [("needs", _("Needs me"), sum(1 for t in tickets if t["fm"].get("agent_state"))),
           ("open", _("All open"), len(open_t))]
    for p in sorted({t["project"] for t in open_t}):
        out.append(("p:" + p, _(p) if p == "Other" else p, sum(1 for t in open_t if t["project"] == p)))
    out.append(("closed", _("Closed"), sum(1 for t in tickets if t["status"] in CLOSED)))
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
        meta.append(_("due ") + fm["due"])
    out.append(("dim", " · ".join(meta)))
    kind = running_kind(t["id"])
    if kind:
        out.append(("warn", _("⚙ background %s session running") % kind))
    if fm.get("agent_state"):
        out.append(("warn", _("Agent waits for you: %s") % fm["agent_state"]))
    if fm.get("waiting_on"):
        out.append(("", _("Waiting on: ") + fm["waiting_on"]))
    if fm.get("meeting"):
        out.append(("", _("Next meeting: ") + fm["meeting"]))
    if fm.get("agent_dir"):
        out.append(("dim", "agent_dir: " + fm["agent_dir"]))
    if t["subtasks"]:
        done = sum(1 for d, _ in t["subtasks"] if d)
        out.append(("", ""))
        out.append(("head", _("Subtasks %d/%d") % (done, len(t["subtasks"]))))
        for d, text in t["subtasks"]:
            out.append(("dim" if d else "", ("☑ " if d else "☐ ") + text))
    if t["crumbs"]:
        out.append(("", ""))
        out.append(("head", _("Breadcrumbs")))
        for c in t["crumbs"][:4]:
            out.append(("", c))
    last = os.path.join(LOGS, t["id"] + "-last-work.txt")
    if os.path.exists(last):
        tail = [ln for ln in read_text(last).strip().split("\n") if ln.strip()][-3:]
        if tail:
            out.append(("", ""))
            out.append(("head", _("Last work session")))
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
        subprocess.Popen(["/bin/bash", os.path.join(TK_DIR, script), tid], cwd=VAULT,
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
        self.msg = _("? for help")
        self.help = False
        self.report = []
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
            scr.addstr(0, 0, fit(_("Make the window bigger (60x10 at least)."), w - 1))
            scr.refresh()
            return
        cur = self.current()
        need = sum(1 for t in self.tickets if t["fm"].get("agent_state"))
        run = sum(1 for t in self.tickets if running_kind(t["id"]))
        head = _(" Tarokaja   %s needs you   %s running") % (need, run)
        scr.addstr(0, 0, fit(head, w - 1 - 6) + time.strftime("%H:%M"), curses.A_REVERSE)
        lw, mw = 18, max(30, (w - 18) // 2 - 4)
        rw = w - lw - mw - 3
        top = 2
        body_h = h - top - 2
        # column titles
        scr.addstr(1, 0, fit(" " + _("Places"), lw), self.title_attr(0))
        scr.addstr(1, lw + 1, fit(" " + self.places[self.place][1], mw), self.title_attr(1))
        scr.addstr(1, lw + mw + 2, fit(" " + (cur["id"] if cur else ""), rw), curses.A_BOLD)
        # left
        for i, (_key, label, n) in enumerate(self.places[:body_h]):
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
            scr.addstr(top, lw + 1, fit(" " + _("(no tickets)"), mw), curses.A_DIM)
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
        overlay = HELP if self.help else self.report[-(h - 3):]
        for i, ln in enumerate(overlay):
            scr.addstr(h - 2 - len(overlay) + i, lw + 1, fit(" " + ln, w - lw - 2), curses.A_REVERSE)
        legend = _(" ⚙ running  ? decide  ✓ review  · delegated ")
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
        a = self.ask(scr, _("Status: i inbox  b backlog  t todo  d doing  w waiting  o done  x dropped > "))
        return choices.get((a or "").strip()[:1])

    def interactive(self, scr, args, what):
        if open_split(["/bin/bash"] + args):
            self.msg = _("%s opened in a split on the right") % what
            return
        curses.endwin()
        subprocess.call(["/bin/bash"] + args, cwd=VAULT)
        scr.refresh()
        self.msg = _("%s ended") % what

    def act(self, scr, key):
        cur = self.current()
        if key in ("q", "Q"):
            return False
        if key == "?":
            self.help, self.report = not self.help, []
        elif key == "R":
            self.help = False
            self.report = [] if self.report else week_report_lines()
            if not self.report and not addon_on("timelog"):
                self.msg = _("Time log is off. Add timelog to ADDONS in .tarokaja/config.")
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
            self.msg = _("Reloaded")
        elif key == "n":
            p = self.places[self.place][0]
            project = p[2:] if p.startswith("p:") else "Other"
            title = self.ask(scr, _("New ticket title (%s): ") % project)
            if title:
                try:
                    tid = new_ticket(title[:120], project)
                    self.msg = (_("%s opened in inbox") % tid) if tid else _("Title is empty")
                except OSError as e:
                    self.msg = _("Cannot create the ticket: %s") % e.strerror
                self.reload()
        elif cur is None:
            pass
        elif key in ("\n", "\r", "t", curses.KEY_ENTER):
            self.interactive(scr, [os.path.join(TK_DIR, "meeting.sh"), cur["id"], "--talk"], _("Talk with %s") % cur["id"])
        elif key == "m":
            self.interactive(scr, [os.path.join(TK_DIR, "meeting.sh"), cur["id"]], _("Meeting for %s") % cur["id"])
        elif key == "w":
            if not cur["delegated"]:
                self.msg = _("%s has no subtask marked (agent). Talk to the agent to delegate one.") % cur["id"]
            elif cur["status"] != "doing":
                self.msg = _("%s is %s. Work sessions run only on doing tickets.") % (cur["id"], cur["status"])
            elif cur["fm"].get("agent_state"):
                self.msg = _("%s waits for you (%s). Hold a meeting first (m).") % (cur["id"], cur["fm"]["agent_state"])
            elif running_kind(cur["id"]):
                self.msg = _("%s already has a session running") % cur["id"]
            else:
                start_bg("work.sh", cur["id"])
                self.msg = _("%s work session started") % cur["id"]
        elif key == "p":
            if not cur["fm"].get("meeting"):
                self.msg = _("Set the meeting time first (M)")
            elif running_kind(cur["id"]):
                self.msg = _("%s already has a session running") % cur["id"]
            else:
                start_bg("prep.sh", cur["id"])
                self.msg = _("%s agenda is being written") % cur["id"]
        elif key in ("M", "s") and running_kind(cur["id"]):
            self.msg = _("%s has a session running. Change it after the session ends.") % cur["id"]
        elif key == "M":
            v = self.ask(scr, _("Meeting time YYYY-MM-DD HH:MM (empty clears): "), cur["fm"].get("meeting", ""))
            if v is not None:
                v = v.strip()
                try:
                    if v:
                        dt.datetime.strptime(v, "%Y-%m-%d %H:%M")
                    set_fields(cur["path"], {"meeting": v})
                    self.msg = _("%s meeting: %s") % (cur["id"], v or _("cleared"))
                except ValueError:
                    self.msg = _("Use the format YYYY-MM-DD HH:MM")
                self.reload()
        elif key == "s":
            st = self.pick_status(scr)
            if st and st != cur["status"]:
                changes = {"status": st}
                if st != "waiting":
                    changes.update({"waiting_on": "", "agent_state": ""})
                set_fields(cur["path"], changes, _("Status: %s → %s.") % (cur["status"], st))
                self.reload()
                self.msg = _("%s is now %s") % (cur["id"], st)
        elif key == "o":
            open_in_obsidian(cur["path"])
            self.msg = _("Opened %s in Obsidian") % cur["id"]
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
        sys.stderr.write("Cannot find %s. Run the TUI from an Tarokaja vault.\n" % TICKETS)
        return 1
    if "--print" in argv:
        print_board()
        return 0
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(main_loop)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
