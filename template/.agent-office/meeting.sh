#!/bin/bash
# meeting.sh T-001         -- hold the ticket's meeting with the agent (interactive)
# meeting.sh T-001 --talk  -- talk to the agent about the ticket without an agenda
set -u
. "$(dirname "$0")/lib.sh"

id="${1:?Usage: meeting.sh T-001 [--talk]}"
f="$(ticket_file "$id")" || { echo "Cannot find ticket $id" >&2; exit 1; }
require_agent
cd "$VAULT" || exit 1
ticket="Tickets/$(basename "$f")"
running=""
session_running "$id" && running=" A background $(cat "$LOG_DIR/$id.kind" 2>/dev/null) session runs on this ticket now. Do not edit the ticket body until it ends."
echo "$$" > "$LOG_DIR/$id.meeting.pid"   # exec keeps this pid, so tick.sh and the TUI see the meeting

if [ "${2:-}" = --talk ]; then
  log "talk start $id"
  agent_interactive "Follow \"$(cfg SEC_TALK 'Talking with the manager')\" in $RULES. You are the team member for $id. Ticket: $ticket. The time now is $(now_min).$running $(lang_note) Read the ticket, then wait for what the manager says."
fi

meeting="$(fm "$f" meeting)"
if [ -n "$meeting" ]; then
  agenda="$MEETINGS/$(echo "$meeting" | tr -d ':') $id.md"
  if [ -f "$agenda" ]; then ctx="The agenda is \"$agenda\"."
  else ctx="There is no agenda. Write one to \"$agenda\" first, as \"$(cfg SEC_PREP 'Meeting prep')\" in $RULES says."; fi
else
  ctx="The ticket has no meeting time and no agenda. Report from the ticket."
fi
log "meeting start $id"
agent_interactive "Follow \"$(cfg SEC_MEETING 'During the meeting')\" in $RULES and hold the meeting for $id. Ticket: $ticket. $ctx The time now is $(now_min).$running $(lang_note) Report progress first. Then ask the manager for one decision at a time."
