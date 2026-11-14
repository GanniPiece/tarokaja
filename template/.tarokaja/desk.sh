#!/bin/bash
# desk.sh -- talk to the front desk agent without a ticket (interactive)
# Ask any question, or give a rough idea and let the agent open a ticket for it.
set -u
. "$(dirname "$0")/lib.sh"

require_agent
cd "$VAULT" || exit 1
unset TK_TICKET   # the session add-on binds only ticket sessions. The front desk has no ticket.

prompt="Follow \"$(cfg SEC_DESK 'Tickets the manager asks for')\" in $RULES. You are the front desk. The manager talks to you without a ticket. The time now is $(now_min). $(lang_note) Wait for what the manager says."
log "desk start"
agent_interactive "$prompt"
