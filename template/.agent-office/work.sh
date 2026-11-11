#!/bin/bash
# work.sh T-001 -- one background work session on the subtasks delegated to the agent
set -u
. "$(dirname "$0")/lib.sh"

id="${1:?Usage: work.sh T-001}"
f="$(ticket_file "$id")" || { echo "Cannot find ticket $id" >&2; exit 1; }
delegated "$f" || { echo "$id has no open subtask marked (agent)" >&2; exit 1; }
[ "$(fm "$f" status)" = doing ] || { echo "$id status is $(fm "$f" status). Only doing tickets get work sessions." >&2; exit 0; }
[ -z "$(fm "$f" agent_state)" ] || { echo "$id waits for the manager ($(fm "$f" agent_state)). Hold a meeting first." >&2; exit 0; }
p="$(cat "$LOG_DIR/$id.meeting.pid" 2>/dev/null)"
[ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$id is in a meeting now" >&2; exit 0; }

dir="$(agent_dir_of "$f")"
if [ -n "$dir" ]; then
  case "$dir" in /*) ;; *) echo "$id agent_dir is not an absolute path: $dir" >&2; exit 1 ;; esac
  [ -d "$dir" ] || { echo "$id agent_dir is not a folder: $dir" >&2; exit 1; }
  agent_dir_allowed "$dir" || { echo "$id agent_dir is not inside AGENT_DIR_ROOTS in .agent-office/config: $dir" >&2; log "work refuse $id: agent_dir $dir"; exit 1; }
  dir="$(cd "$dir" && pwd -P)"   # give the agent the checked path, not a symlink
fi
require_agent

run() {
  cd "$VAULT" || exit 1
  log "work start $id ($AGENT_CLI)"
  local prompt="Follow \"$(cfg SEC_WORK 'Work session')\" in $RULES and run one work session on $id. Ticket: Tickets/$(basename "$f"). The time now is $(now_min). Use this time for breadcrumbs. Work only on open subtasks marked $(cfg MARK '(agent)'), unless the ticket has owner: agent. Write outputs under $OUTPUTS/$id/. $(lang_note) Before you stop, report in three lines or fewer what you did and where you stopped."
  [ -n "$dir" ] && prompt="$prompt Work folder (agent_dir): $dir."
  run_bg_session "$id" work "$prompt" "$dir"
  local rc=$?
  date +%s > "$LOG_DIR/$id.last-work"
  log "work end $id rc=$rc status=$(fm "$f" status) agent_state=$(fm "$f" agent_state)"
  case "$(fm "$f" agent_state)" in
    decide) notify "$id needs your decision" "$(fm "$f" waiting_on)" ;;
    review) notify "$id is ready for review" "$(fm "$f" waiting_on)" ;;
    *)      notify "$id work session ended" "$(tail -n 3 "$LOG_DIR/$id-last-work.txt" | tr '\n' ' ' | cut -c1-120)" ;;
  esac
  return $rc
}
with_lock "$id" run
