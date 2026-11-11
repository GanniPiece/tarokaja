# Shared helpers for Tarokaja scripts. Source this file. Do not run it.
# Compatible with bash 3.2 (macOS /bin/bash).

TK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$TK_DIR/.." && pwd)"
LOG_DIR="$TK_DIR/logs"
TICKETS="$VAULT/Tickets"
mkdir -p "$LOG_DIR"

# Settings come from, in this order: the environment, .tarokaja/config,
# the language profile (.tarokaja/profiles/<TK_LANG>.conf), then the default.
_conf() { # _conf FILE KEY -> the last value of KEY in FILE
  [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1
}
cfg() { # cfg KEY DEFAULT
  local v=""
  eval "v=\"\${$1:-}\""
  [ -n "$v" ] || v="$(_conf "$TK_DIR/config" "$1")"
  [ -n "$v" ] || [ "$1" = TK_LANG ] || v="$(_conf "$TK_DIR/profiles/$TK_LANG.conf" "$1")"
  echo "${v:-$2}"
}
TK_LANG="$(cfg TK_LANG en)"
case "$TK_LANG" in en|zh-TW|ja) ;; *) TK_LANG=en ;; esac
AGENT_CLI="$(cfg AGENT_CLI claude)"
MEETINGS="$(cfg MEETINGS_DIR Office/meetings)"
OUTPUTS="$(cfg OUTPUTS_DIR Office/outputs)"
RULES="$(cfg RULES_FILE AGENTS.md)"
WRITE_LANG="$(cfg WRITE_LANG English)"
ADDONS="$(cfg ADDONS "")"      # enabled add-ons, such as timelog,session (folders in addons/)

# launchd starts jobs with a minimal PATH. Add the usual install folders at the end, so the user's PATH wins.
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin"

log() { echo "$(date '+%F %T') $*" >> "$LOG_DIR/agent.log"; }
now_min() { date '+%Y-%m-%d %H:%M'; }

ticket_file() { # ticket_file T-001 -> path of "Tickets/T-001 *.md"
  local f
  for f in "$TICKETS/$1 "*.md; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

fm() { # fm FILE KEY -> frontmatter scalar value, "" when missing
  awk -v k="$2" '
    NR==1 { if ($0=="---") { f=1; next } else exit }
    f && $0=="---" { exit }
    f && index($0, k ":")==1 { v=substr($0, length(k)+2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); gsub(/^"|"$/, "", v); print v; exit }
  ' "$1"
}

delegated() { # delegated FILE: true when owner is agent, or an open subtask ends with (agent) or （agent）
  [ "$(fm "$1" owner)" = agent ] && return 0
  grep -qE '^[[:space:]]*- \[ \] .*(\(agent\)|（agent）)[[:space:]]*$' "$1"
}

emit() { # emit EVENT ID REF: run addons/<name>/on_event for each enabled add-on. A failing add-on never stops the caller.
  [ -n "$ADDONS" ] || return 0
  local a IFS=,
  for a in $ADDONS; do
    case "$a" in ""|*[!A-Za-z0-9_-]*) continue ;; esac
    [ -x "$TK_DIR/addons/$a/on_event" ] || continue
    "$TK_DIR/addons/$a/on_event" "$@" > /dev/null 2>&1 < /dev/null || true
  done
  return 0
}

start_ticker() { # start_ticker EVENT ID REF: emit EVENT every 60 s in the background. Sets TICKER to its pid.
  # It also stops by itself when this script is gone, such as after a kill.
  TICKER=""
  [ -n "$ADDONS" ] || return 0
  ( s=""; trap 'kill $s 2>/dev/null; exit 0' TERM
    while :; do
      sleep 60 & s=$!; wait $s
      kill -0 $$ 2>/dev/null || exit 0   # $$ is the parent script, also in this subshell
      emit "$@"
    done ) > /dev/null 2>&1 < /dev/null &
  TICKER=$!
}

stop_ticker() { [ -n "${TICKER:-}" ] && { kill "$TICKER"; wait "$TICKER"; } 2>/dev/null; TICKER=""; }

addon_on() { # addon_on NAME: true when the add-on is in ADDONS
  case ",$ADDONS," in *",$1,"*) return 0 ;; esac
  return 1
}

lang_note() { # the sentence that every prompt ends with
  echo "Rules file: $RULES. Write ticket text and your final report in $WRITE_LANG. Ticket headings, the delegation marker, and breadcrumb words follow the rules file."
}

to_epoch() { # to_epoch "YYYY-MM-DD HH:MM" -> seconds, "" when the value is not valid
  date -j -f '%Y-%m-%d %H:%M' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || true
}

agent_dir_of() { # agent_dir_of FILE -> agent_dir with a leading ~/ expanded, "" when not set
  local d; d="$(fm "$1" agent_dir)"
  case "$d" in "~") d="$HOME" ;; "~/"*) d="$HOME/${d#\~/}" ;; esac
  echo "$d"
}

agent_dir_allowed() { # agent_dir_allowed DIR: true when DIR is inside one of the AGENT_DIR_ROOTS folders
  # The ticket file is writable by the agent, so the allowlist lives in config, which the agent may not edit.
  local d roots root
  d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  roots="$(cfg AGENT_DIR_ROOTS "")"
  [ -n "$roots" ] || return 1
  local IFS=:
  for root in $roots; do
    case "$root" in "~") root="$HOME" ;; "~/"*) root="$HOME/${root#\~/}" ;; esac
    root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
    case "$d/" in "$root"/*) return 0 ;; esac
  done
  return 1
}

notify() { # notify TITLE BODY: cmux notification, else a macOS notification
  if command -v cmux >/dev/null 2>&1 && cmux notify --title "$1" --body "$2" >/dev/null 2>&1; then
    return 0
  fi
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
}

require_agent() {
  case "$AGENT_CLI" in
    claude|codex|gemini|agy) ;;
    *) echo "AGENT_CLI must be claude, codex, gemini, or agy (now: $AGENT_CLI)" >&2; exit 1 ;;
  esac
  command -v "$AGENT_CLI" >/dev/null 2>&1 || { log "$AGENT_CLI not found"; echo "Cannot find the $AGENT_CLI command. Install it or change AGENT_CLI in .tarokaja/config." >&2; exit 1; }
}

# Claude Code: the tools a background session may use. Other agents rely on their own sandbox and on AGENTS.md.
CLAUDE_TOOLS="Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
CLAUDE_DIR_TOOLS="Bash(git:*),Bash(uv:*),Bash(python3:*),Bash(ls:*)"
# Edit rules cover all file-editing tools (Claude Code ignores Write(path) deny rules).
CLAUDE_DENIED="Read(./private/**),Edit(./private/**),Read(./.obsidian/**),Edit(./.obsidian/**),Read(./.trash/**),Edit(./.trash/**),Edit(./.tarokaja/**)"

stream_result() { # stream_result STREAM: the result text of the last "result" event in a stream-json log
  python3 -I -c 'import json,sys
res = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: ev = json.loads(line)
    except ValueError: continue
    if isinstance(ev, dict) and ev.get("type") == "result":
        res = ev.get("result")
        if not res:   # an error result can have no text, such as subtype error_max_turns
            res = "Session ended without a result: %s" % (ev.get("subtype") or "unknown")
            errs = ev.get("errors")
            if errs: res += " (%s)" % "; ".join(str(e) for e in errs)
if res is None: sys.exit(1)
sys.stdout.write(str(res))' "$1" 2>/dev/null
}

agent_headless() { # agent_headless PROMPT OUTFILE [AGENT_DIR] [STREAM]: one background session. Returns the agent exit status.
  local prompt="$1" out="$2" dir="${3:-}" stream="${4:-$2.jsonl}"
  case "$AGENT_CLI" in
    claude)
      # stream-json keeps a live log (the TUI and other tools read it). OUTFILE gets the final answer.
      local tools="$CLAUDE_TOOLS" rc
      if [ -n "$dir" ]; then tools="$tools,$CLAUDE_DIR_TOOLS"; set -- --add-dir "$dir"; else set --; fi
      claude -p "$prompt" "$@" --output-format stream-json --verbose --permission-mode acceptEdits \
        --allowedTools "$tools" --disallowedTools "$CLAUDE_DENIED" --max-turns 40 > "$stream" 2> "$out.err"
      rc=$?
      if ! stream_result "$stream" > "$out"; then
        tail -n 20 "$out.err" > "$out"   # no result event: keep the error text for the manager
      fi
      rm -f "$out.err"
      return $rc ;;
    codex)
      if [ -n "$dir" ]; then set -- --add-dir "$dir"; else set --; fi
      codex exec --skip-git-repo-check --sandbox workspace-write -C "$VAULT" "$@" "$prompt" > "$out" 2>&1 ;;
    gemini)
      if [ -n "$dir" ]; then set -- --include-directories "$dir"; else set --; fi
      gemini -p "$prompt" "$@" --approval-mode auto_edit --skip-trust > "$out" 2>&1 ;;
    agy)
      if [ -n "$dir" ]; then set -- --add-dir "$dir"; else set --; fi
      agy -p "$prompt" "$@" --mode accept-edits --print-timeout 1800s > "$out" 2>&1 ;;
  esac
}

agent_interactive() { # agent_interactive PROMPT [--wait] [CLAUDE ARGS...]: replace this shell with an interactive session.
  # With --wait, run the session and return its exit status instead (add-ons need an event after the session).
  local prompt="$1" x=exec; shift
  if [ "${1:-}" = --wait ]; then x=; shift; fi
  case "$AGENT_CLI" in
    claude) $x claude "$prompt" "$@" --permission-mode acceptEdits --allowedTools "$CLAUDE_TOOLS" --disallowedTools "$CLAUDE_DENIED" ;;
    codex)  $x codex --sandbox workspace-write -C "$VAULT" "$prompt" ;;
    gemini) $x gemini -i "$prompt" --approval-mode auto_edit ;;
    agy)    $x agy -i "$prompt" --mode accept-edits ;;
  esac
}

run_bg_session() { # run_bg_session ID KIND PROMPT [AGENT_DIR]: run, keep a pid file while it runs
  local id="$1" kind="$2" prompt="$3" dir="${4:-}"
  local out="$LOG_DIR/$id-last-$kind.txt"
  local rc
  echo "$$" > "$LOG_DIR/$id.pid"
  echo "$kind" > "$LOG_DIR/$id.kind"
  export TK_HEADLESS=1   # add-on hooks inside the agent see a background session, not the manager
  emit session_start "$id" bg
  start_ticker session_tick "$id" bg
  agent_headless "$prompt" "$out" "$dir" "$LOG_DIR/$id-stream.jsonl"
  rc=$?
  stop_ticker
  rm -f "$LOG_DIR/$id.pid" "$LOG_DIR/$id.kind"
  emit session_end "$id" bg
  return $rc
}

with_lock() { # with_lock NAME CMD...: skip when the same ticket already runs
  TK_LOCK="$LOG_DIR/$1.lock"; shift
  if ! mkdir "$TK_LOCK" 2>/dev/null; then
    local owner age; owner="$(cat "$TK_LOCK/pid" 2>/dev/null)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      log "skip: $TK_LOCK is held by pid $owner"
      return 0
    fi
    age=$(( $(date +%s) - $(stat -f %m "$TK_LOCK" 2>/dev/null || date +%s) ))
    if [ -z "$owner" ] && [ "$age" -lt 60 ]; then   # another process made the lock and writes its pid now
      log "skip: $TK_LOCK is new"
      return 0
    fi
    log "remove stale lock $TK_LOCK (pid ${owner:-none})"   # left by a crash, kill, or reboot
    rm -rf "$TK_LOCK"
    mkdir "$TK_LOCK" 2>/dev/null || { log "skip: $TK_LOCK"; return 0; }
  fi
  echo "$$" > "$TK_LOCK/pid"
  trap 'rm -rf "$TK_LOCK"' EXIT
  "$@"
}

session_running() { # session_running ID: true when a live background session or meeting uses the ticket
  local p f
  for f in "$LOG_DIR/$1.pid" "$LOG_DIR/$1.meeting.pid"; do
    p="$(cat "$f" 2>/dev/null)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}
