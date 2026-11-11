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
echo "$$" > "$LOG_DIR/$id.meeting.pid"   # exec (or this shell) keeps this pid, so tick.sh and the TUI see the meeting

if [ "${2:-}" = --talk ]; then
  what=talk
  prompt="Follow \"$(cfg SEC_TALK 'Talking with the manager')\" in $RULES. You are the team member for $id. Ticket: $ticket. The time now is $(now_min).$running $(lang_note) Read the ticket, then wait for what the manager says."
else
  what=meeting
  meeting="$(fm "$f" meeting)"
  if [ -n "$meeting" ]; then
    agenda="$MEETINGS/$(echo "$meeting" | tr -d ':') $id.md"
    if [ -f "$agenda" ]; then ctx="The agenda is \"$agenda\"."
    else ctx="There is no agenda. Write one to \"$agenda\" first, as \"$(cfg SEC_PREP 'Meeting prep')\" in $RULES says."; fi
  else
    ctx="The ticket has no meeting time and no agenda. Report from the ticket."
  fi
  prompt="Follow \"$(cfg SEC_MEETING 'During the meeting')\" in $RULES and hold the meeting for $id. Ticket: $ticket. $ctx The time now is $(now_min).$running $(lang_note) Report progress first. Then ask the manager for one decision at a time."
fi
log "$what start $id"

[ -n "$ADDONS" ] || agent_interactive "$prompt"   # no add-on: exec, this shell is gone

# With add-ons this shell stays, so they get an event when the session ends.
set --
if addon_on session && [ "$AGENT_CLI" = claude ]; then
  export AO_TICKET="$id"   # the session add-on hook binds this Claude session to the ticket
  sid="$(fm "$f" session)"
  case "$sid" in ""|*[!A-Za-z0-9-]*) sid="" ;; esac
  if [ -n "$sid" ] && ls "$HOME/.claude/projects/"*/"$sid.jsonl" >/dev/null 2>&1; then
    set -- --resume "$sid"   # continue the ticket's last session
  fi
fi
finish() {
  stop_ticker
  [ "$(cat "$LOG_DIR/$id.meeting.pid" 2>/dev/null)" = "$$" ] && rm -f "$LOG_DIR/$id.meeting.pid"
  emit meeting_end "$id" "$$"
}
trap finish EXIT
trap 'exit 129' HUP      # the cmux split closed
trap 'exit 143' TERM
trap : INT               # Ctrl-C belongs to the agent, not to this shell
emit meeting_start "$id" "$$"
start_ticker meeting_tick "$id" "$$"   # timelog: an open meeting counts up to now
agent_interactive "$prompt" --wait "$@"
