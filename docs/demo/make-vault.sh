#!/bin/bash
# make-vault.sh DIR -- build the demo vault for docs/demo/demo.tape (English, with sample tickets and time).
# The tickets are examples. They are not output of a real agent session.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
dir="${1:?Usage: make-vault.sh DIR}"
if [ -e "$dir" ] && [ ! -f "$dir/.tarokaja-demo" ]; then
  echo "$dir exists and is not a demo vault. Give a new folder." >&2; exit 1
fi
rm -rf "$dir"
bash "$here/../../install.sh" "$dir" --lang en --addons timelog >/dev/null
rm -f "$dir/Tickets/"T-001*.md
: > "$dir/.tarokaja-demo"   # marks the folder as a demo vault, so the next run may replace it
python3 -I - "$dir" <<'PY'
import datetime as dt, json, os, sys, time
v = sys.argv[1]
today = dt.date.today()
d = lambda n: (today + dt.timedelta(days=n)).isoformat()
now = int(time.time())

def ticket(tid, title, status, project, body, **fm):
    keys = ["id", "status", "project", "created", "updated", "due", "waiting_on", "owner", "meeting", "agent_state"]
    vals = dict(id=tid, status=status, project=project, created=d(-6), updated=d(0))
    vals.update(fm)
    lines = ["---"] + ["%s: %s" % (k, vals.get(k, "")) for k in keys] + ["links: []", "---", "# " + title, ""] + body
    with open(os.path.join(v, "Tickets", "%s %s.md" % (tid, title)), "w", encoding="utf-8") as f:
        f.write("\n".join(lines).replace(": \n", ":\n") + "\n")

t = lambda h, m: "%s %02d:%02d" % (d(0), h, m)
ticket("T-001", "Compare three NAS models", "doing", "Home", [
    "## Done when", "", "One note recommends one model, with price, noise, and power for all three.", "",
    "## Subtasks", "", "- [x] List my needs", "- [x] Collect specs for the three models (agent)",
    "- [ ] Find the power draw of model C (agent)", "- [ ] Order the NAS", "",
    "## Decisions", "", "## Breadcrumbs", "",
    "- %s · [agent] Stopped: specs for models A and B in [[Office/outputs/T-001/specs]]. Next: find the power draw of model C." % (d(-1) + " 17:40"),
    "- %s · Opened." % (d(-6) + " 10:05")])
ticket("T-002", "Plan the team offsite", "waiting", "Work", [
    "## Done when", "", "The venue, date, and agenda are fixed and shared with the team.", "",
    "## Subtasks", "", "- [x] Collect three venues near the office (agent)", "- [ ] Draft the agenda (agent)", "- [ ] Send the invite", "",
    "## Decisions", "", "### D1 Which venue?",
    "- Option A: the lake house. Cost: 2 hours by train.", "- Option B: the city loft. Cost: no outdoor space.",
    "- Recommendation: A, because the team asked for a day outside.", "- Decision:", "",
    "## Breadcrumbs", "",
    "- %s · [agent] Stopped: three venues compared in [[Office/outputs/T-002/venues]]. Next: wait for D1." % t(11, 20),
    "- %s · Opened." % (d(-5) + " 09:00")],
    agent_state="decide", waiting_on="Manager: decide D1 Which venue?", meeting=d(1) + " 10:00")
ticket("T-003", "Write the release notes", "waiting", "Work", [
    "## Done when", "", "Release notes for v1.2 are ready to post.", "",
    "## Subtasks", "", "- [x] Collect the merged changes (agent)", "- [x] Draft the notes (agent)", "",
    "## Decisions", "", "## Breadcrumbs", "",
    "- %s · [agent] Stopped: draft in [[Office/outputs/T-003/release-notes]]. Next: manager review." % t(9, 50)],
    agent_state="review", waiting_on="Manager: review the release notes draft")
ticket("T-004", "Renew the domain", "todo", "Home", ["## Done when", "", "The domain is renewed for two years.", "", "## Subtasks", "", "- [ ] Renew at the registrar", "", "## Decisions", "", "## Breadcrumbs", ""], due=d(2))
ticket("T-005", "Move old photos to the NAS", "inbox", "Home", ["## Done when", "", "", "## Subtasks", "", "## Decisions", "", "## Breadcrumbs", ""])
ticket("T-006", "Learn the basics of Rust", "backlog", "Learning", ["## Done when", "", "", "## Subtasks", "", "## Decisions", "", "## Breadcrumbs", ""])
ticket("T-007", "Fix the office printer", "done", "Work", ["## Done when", "", "The printer prints.", "", "## Subtasks", "", "## Decisions", "", "## Breadcrumbs", ""])

logs = os.path.join(v, ".tarokaja", "logs")
os.makedirs(logs, exist_ok=True)
with open(os.path.join(logs, "T-001-last-work.txt"), "w") as f:
    f.write("Collected specs for models A and B.\nModel C has no published power data yet.\nStopped before the power draw of model C.\n")
os.makedirs(os.path.join(logs, "time"), exist_ok=True)
def ev(tid, rows):
    with open(os.path.join(logs, "time", tid + ".jsonl"), "w") as f:
        for at, kind, ref in rows:
            f.write(json.dumps({"at": at, "kind": kind, "ref": ref}) + "\n")
h = 3600
ev("T-001", [(now - 5*h, "seat_start", "m1"), (now - 5*h + 600, "ping", "m1"), (now - 5*h + 1080, "seat_end", "m1"),
             (now - 4*h, "agent_start", "bg")] + [(now - 4*h + i*540, "agent_tick", "bg") for i in range(1, 6)] + [(now - 4*h + 2820, "agent_end", "bg")])
ev("T-002", [(now - 3*h, "seat_start", "m2"), (now - 3*h + 720, "seat_end", "m2"),
             (now - 2*h, "agent_start", "bg")] + [(now - 2*h + i*480, "agent_tick", "bg") for i in range(1, 4)] + [(now - 2*h + 1500, "agent_end", "bg")])
PY
echo "Demo vault: $dir"
