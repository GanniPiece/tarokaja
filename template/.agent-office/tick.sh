#!/bin/bash
# tick.sh -- the office clock. launchd runs it every 5 minutes.
#   1. Any ticket with a meeting within REMIND_BEFORE_MIN, not reminded yet -> notification
#   2. Any ticket with a meeting within PREP_BEFORE_MIN, no agenda, not tried yet -> prep.sh
#   3. A delegated ticket with status doing, no agent_state, inside work hours, and the
#      last work session older than WORK_EVERY_HOURS -> work.sh
# Sessions start in the background, so one long session does not delay other tickets.
# Each script holds a per-ticket lock, so a ticket never runs twice at one time.
set -u
. "$(dirname "$0")/lib.sh"

WORK_EVERY_HOURS="$(cfg WORK_EVERY_HOURS 4)"
WORK_HOURS_FROM="$(cfg WORK_HOURS_FROM 9)"   # local hour, inclusive
WORK_HOURS_TO="$(cfg WORK_HOURS_TO 20)"      # local hour, exclusive
PREP_BEFORE_MIN="$(cfg PREP_BEFORE_MIN 60)"
REMIND_BEFORE_MIN="$(cfg REMIND_BEFORE_MIN 5)"

now="${AO_NOW:-$(date +%s)}"                 # AO_NOW and AO_HOUR: tests set the clock
hour="${AO_HOUR:-$(date +%H)}"; hour="${hour#0}"

start() { # start SCRIPT ID: run in the background, detached from this tick
  if [ "${AO_FOREGROUND:-}" = 1 ]; then /bin/bash "$AO_DIR/$1" "$2"; return; fi   # tests
  nohup /bin/bash "$AO_DIR/$1" "$2" >> "$LOG_DIR/tick-sessions.log" 2>&1 < /dev/null &
}

for f in "$TICKETS/"T-*.md; do
  [ -f "$f" ] || continue
  id="$(basename "$f" | cut -d' ' -f1)"
  status="$(fm "$f" status)"
  case "$status" in done|dropped) continue ;; esac

  meeting="$(fm "$f" meeting)"
  m=""
  [ -n "$meeting" ] && m="$(to_epoch "$meeting")"
  if [ -n "$m" ] && [ "$m" -gt "$now" ]; then
    stamp="$(echo "$meeting" | tr -d ':')"
    left=$((m - now))
    if [ "$left" -le $((REMIND_BEFORE_MIN * 60)) ] && [ ! -f "$LOG_DIR/$id.reminded-$stamp" ]; then
      : > "$LOG_DIR/$id.reminded-$stamp"
      log "remind $id $meeting"
      notify "Meeting soon: $id" "$meeting $(basename "$f" .md)"
    fi
    if [ "$left" -le $((PREP_BEFORE_MIN * 60)) ] && [ ! -f "$VAULT/$MEETINGS/$stamp $id.md" ] \
       && [ ! -f "$LOG_DIR/$id.prepped-$stamp" ] && ! session_running "$id"; then
      start prep.sh "$id"                    # prep.sh writes the prepped marker after it gets the lock
      continue
    fi
  fi

  delegated "$f" || continue
  [ "$status" = doing ] || continue
  [ -z "$(fm "$f" agent_state)" ] || continue
  [ "$hour" -ge "$WORK_HOURS_FROM" ] && [ "$hour" -lt "$WORK_HOURS_TO" ] || continue
  last=0
  [ -f "$LOG_DIR/$id.last-work" ] && last="$(cat "$LOG_DIR/$id.last-work")"
  [ $((now - last)) -ge $((WORK_EVERY_HOURS * 3600)) ] || continue
  session_running "$id" && continue
  start work.sh "$id"
done
