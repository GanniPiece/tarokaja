#!/bin/bash
# prep.sh T-001 -- write the agenda for the ticket's next meeting
set -u
. "$(dirname "$0")/lib.sh"

id="${1:?Usage: prep.sh T-001}"
f="$(ticket_file "$id")" || { echo "Cannot find ticket $id" >&2; exit 1; }
meeting="$(fm "$f" meeting)"
[ -n "$meeting" ] || { echo "$id has no meeting time" >&2; exit 1; }
require_agent

agenda="$MEETINGS/$(echo "$meeting" | tr -d ':') $id.md"   # Office/meetings/2026-11-04 1500 T-001.md

run() {
  : > "$LOG_DIR/$id.prepped-$(echo "$meeting" | tr -d ':')"   # one try per meeting, also when the agent fails
  cd "$VAULT" || exit 1
  log "prep start $id -> $agenda"
  run_bg_session "$id" prep "Follow \"$(cfg SEC_PREP 'Meeting prep')\" in $RULES. Write the agenda for the $id meeting at $meeting to \"$agenda\". Ticket: Tickets/$(basename "$f"). The time now is $(now_min). Write only the agenda. Do not make progress on the work. $(lang_note)"
  log "prep end $id rc=$?"
  [ -f "$VAULT/$agenda" ] && notify "$id agenda is ready" "Meeting at $meeting: $agenda"
  return 0
}
with_lock "$id" run
