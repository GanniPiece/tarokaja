# Shared helpers for Agent Office scripts. Source this file. Do not run it.
# Compatible with bash 3.2 (macOS /bin/bash).

AO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$AO_DIR/.." && pwd)"
LOG_DIR="$AO_DIR/logs"
TICKETS="$VAULT/Tickets"
MEETINGS="Office/meetings"
mkdir -p "$LOG_DIR"

# Config: environment variables win, then .agent-office/config.
cfg() { # cfg KEY DEFAULT
  local v=""
  eval "v=\"\${$1:-}\""
  if [ -z "$v" ] && [ -f "$AO_DIR/config" ]; then
    v="$(sed -n "s/^$1=//p" "$AO_DIR/config" | tail -n 1)"
  fi
  echo "${v:-$2}"
}
AGENT_CLI="$(cfg AGENT_CLI claude)"

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

delegated() { # delegated FILE: true when owner is agent, or an open subtask ends with (agent)
  [ "$(fm "$1" owner)" = agent ] && return 0
  grep -qE '^[[:space:]]*- \[ \] .*\(agent\)[[:space:]]*$' "$1"
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
  command -v "$AGENT_CLI" >/dev/null 2>&1 || { log "$AGENT_CLI not found"; echo "Cannot find the $AGENT_CLI command. Install it or change AGENT_CLI in .agent-office/config." >&2; exit 1; }
}

# Claude Code: the tools a background session may use. Other agents rely on their own sandbox and on AGENTS.md.
CLAUDE_TOOLS="Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
CLAUDE_DIR_TOOLS="Bash(git:*),Bash(uv:*),Bash(python3:*),Bash(ls:*)"
# Edit rules cover all file-editing tools (Claude Code ignores Write(path) deny rules).
CLAUDE_DENIED="Read(./private/**),Edit(./private/**),Read(./.obsidian/**),Edit(./.obsidian/**),Read(./.trash/**),Edit(./.trash/**),Edit(./.agent-office/**)"

agent_headless() { # agent_headless PROMPT OUTFILE [AGENT_DIR]: one background session. Returns the agent exit status.
  local prompt="$1" out="$2" dir="${3:-}"
  case "$AGENT_CLI" in
    claude)
      local tools="$CLAUDE_TOOLS"
      if [ -n "$dir" ]; then tools="$tools,$CLAUDE_DIR_TOOLS"; set -- --add-dir "$dir"; else set --; fi
      claude -p "$prompt" "$@" --permission-mode acceptEdits \
        --allowedTools "$tools" --disallowedTools "$CLAUDE_DENIED" --max-turns 40 > "$out" 2>&1 ;;
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

agent_interactive() { # agent_interactive PROMPT: replace this shell with an interactive session
  case "$AGENT_CLI" in
    claude) exec claude "$1" --permission-mode acceptEdits --allowedTools "$CLAUDE_TOOLS" --disallowedTools "$CLAUDE_DENIED" ;;
    codex)  exec codex --sandbox workspace-write -C "$VAULT" "$1" ;;
    gemini) exec gemini -i "$1" --approval-mode auto_edit ;;
    agy)    exec agy -i "$1" --mode accept-edits ;;
  esac
}

run_bg_session() { # run_bg_session ID KIND PROMPT [AGENT_DIR]: run, keep a pid file while it runs
  local id="$1" kind="$2" prompt="$3" dir="${4:-}"
  local out="$LOG_DIR/$id-last-$kind.txt"
  echo "$$" > "$LOG_DIR/$id.pid"
  echo "$kind" > "$LOG_DIR/$id.kind"
  agent_headless "$prompt" "$out" "$dir"
  local rc=$?
  rm -f "$LOG_DIR/$id.pid" "$LOG_DIR/$id.kind"
  return $rc
}

with_lock() { # with_lock NAME CMD...: skip when the same ticket already runs
  AO_LOCK="$LOG_DIR/$1.lock"; shift
  if ! mkdir "$AO_LOCK" 2>/dev/null; then
    local owner age; owner="$(cat "$AO_LOCK/pid" 2>/dev/null)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      log "skip: $AO_LOCK is held by pid $owner"
      return 0
    fi
    age=$(( $(date +%s) - $(stat -f %m "$AO_LOCK" 2>/dev/null || date +%s) ))
    if [ -z "$owner" ] && [ "$age" -lt 60 ]; then   # another process made the lock and writes its pid now
      log "skip: $AO_LOCK is new"
      return 0
    fi
    log "remove stale lock $AO_LOCK (pid ${owner:-none})"   # left by a crash, kill, or reboot
    rm -rf "$AO_LOCK"
    mkdir "$AO_LOCK" 2>/dev/null || { log "skip: $AO_LOCK"; return 0; }
  fi
  echo "$$" > "$AO_LOCK/pid"
  trap 'rm -rf "$AO_LOCK"' EXIT
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
