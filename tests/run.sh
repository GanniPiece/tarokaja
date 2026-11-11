#!/bin/bash
# Automated test suite for Agent Office (compatible with macOS bash 3.2).
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

chmod +x "$TESTS_DIR/run.sh" "$TESTS_DIR/bin/"* 2>/dev/null || true

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1"
  local fn="$2"
  local test_tmp
  test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ao-test.XXXXXX")"

  (
    set -e
    export HOME="$test_tmp/home"
    mkdir -p "$HOME/.local/bin"
    cp "$TESTS_DIR/bin/claude" "$TESTS_DIR/bin/codex" "$TESTS_DIR/bin/cmux" "$TESTS_DIR/bin/osascript" "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/"*
    export PATH="$HOME/.local/bin:$TESTS_DIR/bin:$PATH"

    export STUB_AGENT_LOG="$test_tmp/agent.log"
    export STUB_NOTIFY_LOG="$test_tmp/notify.log"
    : > "$STUB_AGENT_LOG"
    : > "$STUB_NOTIFY_LOG"

    unset AGENT_CLI WORK_EVERY_HOURS WORK_HOURS_FROM WORK_HOURS_TO PREP_BEFORE_MIN REMIND_BEFORE_MIN AO_NOW AO_HOUR

    VAULT="$test_tmp/vault"
    export VAULT
    export AO_FOREGROUND=1   # tick.sh runs sessions in the foreground, so tests can check them at once
    /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
    "$fn"
  )
  local rc=$?
  rm -rf "$test_tmp"

  if [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# 1. install.sh tests
# ---------------------------------------------------------------------------

test_install_layout_and_dates() {
  [ -f "$VAULT/AGENTS.md" ]
  [ -f "$VAULT/CLAUDE.md" ]
  [ -f "$VAULT/GEMINI.md" ]
  [ -f "$VAULT/Tickets/Board.base" ]
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  [ -f "$t1" ]
  [ -f "$VAULT/.agent-office/lib.sh" ]
  [ -f "$VAULT/.agent-office/config" ]
  [ -x "$VAULT/.agent-office/work.sh" ]
  [ -x "$VAULT/.agent-office/prep.sh" ]
  [ -x "$VAULT/.agent-office/meeting.sh" ]
  [ -x "$VAULT/.agent-office/tick.sh" ]
  [ -x "$VAULT/.agent-office/tui.py" ]

  local today
  today="$(date +%F)"
  if grep -q '2026-01-01' "$t1"; then return 1; fi
  grep -q "^created: $today$" "$t1"
  grep -q "^updated: $today$" "$t1"
  grep -q "^- $today " "$t1"
}

test_install_agent_flag_and_invalid() {
  local v2
  v2="$(mktemp -d "${TMPDIR:-/tmp}/ao-v2.XXXXXX")"
  /bin/bash "$REPO_DIR/install.sh" "$v2" --agent codex >/dev/null
  grep -q '^AGENT_CLI=codex$' "$v2/.agent-office/config"
  rm -rf "$v2"

  local v3
  v3="$(mktemp -d "${TMPDIR:-/tmp}/ao-v3.XXXXXX")"
  if /bin/bash "$REPO_DIR/install.sh" "$v3" --agent foo >/dev/null 2>&1; then
    rm -rf "$v3"
    return 1
  fi
  rm -rf "$v3"
}

test_install_second_run_does_not_overwrite() {
  echo "custom-marker-line" >> "$VAULT/AGENTS.md"
  echo "custom-ticket-line" >> "$VAULT/Tickets/T-001 Try Agent Office.md"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
  grep -q '^custom-marker-line$' "$VAULT/AGENTS.md"
  grep -q '^custom-ticket-line$' "$VAULT/Tickets/T-001 Try Agent Office.md"
}

# ---------------------------------------------------------------------------
# 2. lib.sh tests
# ---------------------------------------------------------------------------

test_lib_fm_and_cfg() {
  . "$VAULT/.agent-office/lib.sh"

  local sample="$VAULT/Tickets/sample.md"
  cat > "$sample" <<'EOF'
---
id: T-099
title: "Quoted Title Value"
empty_val:
---
# Sample
EOF

  [ "$(fm "$sample" id)" = "T-099" ]
  [ "$(fm "$sample" title)" = "Quoted Title Value" ]
  [ -z "$(fm "$sample" empty_val)" ]
  [ -z "$(fm "$sample" missing_key)" ]

  # cfg reads from config file and prefers environment over config file
  [ "$(cfg AGENT_CLI fallback)" = "claude" ]
  [ "$(AGENT_CLI=gemini cfg AGENT_CLI fallback)" = "gemini" ]
  [ "$(WORK_EVERY_HOURS=9 cfg WORK_EVERY_HOURS 4)" = "9" ]
}

test_lib_delegated_ticket_file_to_epoch() {
  . "$VAULT/.agent-office/lib.sh"

  local f1="$VAULT/Tickets/T-010 Owner Agent.md"
  cat > "$f1" <<'EOF'
---
id: T-010
owner: agent
---
## Subtasks
- [ ] Normal subtask
EOF
  delegated "$f1"

  local f2="$VAULT/Tickets/T-011 Subtask Agent.md"
  cat > "$f2" <<'EOF'
---
id: T-011
owner:
---
## Subtasks
- [ ] Delegated subtask (agent)
EOF
  delegated "$f2"

  local f3="$VAULT/Tickets/T-012 Checked Only.md"
  cat > "$f3" <<'EOF'
---
id: T-012
owner:
---
## Subtasks
- [x] Finished subtask (agent)
- [ ] Manager subtask
EOF
  if delegated "$f3"; then
    return 1
  fi

  local found
  found="$(ticket_file T-001)"
  [ "$found" = "$VAULT/Tickets/T-001 Try Agent Office.md" ]
  if ticket_file T-999 >/dev/null 2>&1; then
    return 1
  fi

  local ep
  ep="$(to_epoch "2026-11-11 10:00")"
  [ -n "$ep" ]
  case "$ep" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -z "$(to_epoch "not-a-valid-date")" ]
}

# ---------------------------------------------------------------------------
# 3. work.sh tests
# ---------------------------------------------------------------------------

test_work_guards() {
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"

  # Status not doing -> exits 0 without calling agent
  sed -i '' 's/^status: doing$/status: waiting/' "$t1"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001 >/dev/null 2>&1
  [ ! -s "$STUB_AGENT_LOG" ]

  # agent_state set -> exits 0 without calling agent
  sed -i '' 's/^status: waiting$/status: doing/' "$t1"
  sed -i '' 's/^agent_state:$/agent_state: decide/' "$t1"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001 >/dev/null 2>&1
  [ ! -s "$STUB_AGENT_LOG" ]

  # No (agent) subtask -> exits non-zero
  sed -i '' 's/^agent_state: decide$/agent_state:/' "$t1"
  sed -i '' 's/^- \[ \] \(.* (agent)\)$/- [x] \1/' "$t1"
  if /bin/bash "$VAULT/.agent-office/work.sh" T-001 >/dev/null 2>&1; then
    return 1
  fi
  [ ! -s "$STUB_AGENT_LOG" ]
}

test_work_valid_claude_session() {
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001

  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^ARG: -p$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS.md'
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tickets/T-001 Try Agent Office.md'

  [ -f "$VAULT/.agent-office/logs/T-001-last-work.txt" ]
  grep -q 'stub done' "$VAULT/.agent-office/logs/T-001-last-work.txt"
  [ -s "$VAULT/.agent-office/logs/T-001.last-work" ]
  [ ! -e "$VAULT/.agent-office/logs/T-001.pid" ]
  grep -q '^- 2026-01-01 10:00 · \[agent\] Stopped: stub\. Next: stub\.$' "$t1"
}

test_work_codex_and_agent_dir() {
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"

  # AGENT_CLI=codex calls codex with exec
  AGENT_CLI=codex /bin/bash "$VAULT/.agent-office/work.sh" T-001
  grep -q '^CMD: codex$' "$STUB_AGENT_LOG"
  grep -q '^ARG: exec$' "$STUB_AGENT_LOG"

  # Relative agent_dir -> exits non-zero
  : > "$STUB_AGENT_LOG"
  sed -i '' 's/^links: \[\]$/agent_dir: relative\/path/' "$t1"
  if /bin/bash "$VAULT/.agent-office/work.sh" T-001 >/dev/null 2>&1; then
    return 1
  fi
  [ ! -s "$STUB_AGENT_LOG" ]

  # Absolute existing folder outside AGENT_DIR_ROOTS -> refused, agent not called
  local ext_dir="$VAULT/../ext_work_dir"
  mkdir -p "$ext_dir"
  ext_dir="$(cd "$ext_dir" && pwd)"
  sed -i '' "s|^agent_dir: .*|agent_dir: $ext_dir|" "$t1"
  : > "$STUB_AGENT_LOG"
  if /bin/bash "$VAULT/.agent-office/work.sh" T-001 2>/dev/null; then return 1; fi
  [ ! -s "$STUB_AGENT_LOG" ]

  # Inside AGENT_DIR_ROOTS -> claude stub gets --add-dir
  sed -i '' "s|^AGENT_DIR_ROOTS=.*|AGENT_DIR_ROOTS=$(dirname "$ext_dir")|" "$VAULT/.agent-office/config"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --add-dir$' "$STUB_AGENT_LOG"
  # work.sh gives the agent the resolved path (no symlinks), as agent_dir_allowed checked it
  grep -q "^ARG: $(cd "$ext_dir" && pwd -P)$" "$STUB_AGENT_LOG"
}

# ---------------------------------------------------------------------------
# 4. tick.sh tests
# ---------------------------------------------------------------------------

test_tick_work_hours_and_throttling() {
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  local now=1700000000

  # Skips outside work hours
  AO_NOW="$now" AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]
  AO_NOW="$now" AO_HOUR=08 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]

  # Skips when ticket has agent_state
  sed -i '' 's/^agent_state:$/agent_state: decide/' "$t1"
  AO_NOW="$now" AO_HOUR=10 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]
  sed -i '' 's/^agent_state: decide$/agent_state:/' "$t1"

  # Skips when logs/<id>.last-work is newer than WORK_EVERY_HOURS (4h)
  mkdir -p "$VAULT/.agent-office/logs"
  echo "$((now - 3600))" > "$VAULT/.agent-office/logs/T-001.last-work"
  AO_NOW="$now" AO_HOUR=10 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]

  # Runs work inside work hours when last-work is older than WORK_EVERY_HOURS
  echo "$((now - 5 * 3600))" > "$VAULT/.agent-office/logs/T-001.last-work"
  AO_NOW="$now" AO_HOUR=10 /bin/bash "$VAULT/.agent-office/tick.sh"
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'run one work session on T-001'
}

test_tick_prep_and_reminder() {
  . "$VAULT/.agent-office/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  local m_str="2026-11-11 15:00"
  local m_epoch
  m_epoch="$(to_epoch "$m_str")"

  sed -i '' "s/^meeting:$/meeting: $m_str/" "$t1"

  # Within PREP_BEFORE_MIN (30 min before) -> calls prep with agenda path under Office/meetings
  : > "$STUB_AGENT_LOG"
  : > "$STUB_NOTIFY_LOG"
  AO_NOW="$((m_epoch - 30 * 60))" AO_HOUR=14 /bin/bash "$VAULT/.agent-office/tick.sh"
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/meetings/2026-11-11 1500 T-001.md'
  [ ! -s "$STUB_NOTIFY_LOG" ]

  # Within REMIND_BEFORE_MIN (3 min before) -> sends one reminder notification and not a second time on next tick
  : > "$STUB_AGENT_LOG"
  : > "$STUB_NOTIFY_LOG"
  AO_NOW="$((m_epoch - 3 * 60))" AO_HOUR=14 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ "$(grep -c 'Meeting soon: T-001' "$STUB_NOTIFY_LOG")" -eq 1 ]

  AO_NOW="$((m_epoch - 2 * 60))" AO_HOUR=14 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ "$(grep -c 'Meeting soon: T-001' "$STUB_NOTIFY_LOG")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 5. tui.py tests
# ---------------------------------------------------------------------------

test_tui_module_and_print() {
  python3 -I "$TESTS_DIR/test_tui.py" "$VAULT"

  local out
  out="$(cd "$VAULT" && python3 -I .agent-office/tui.py --print)"
  printf '%s\n' "$out" | grep -q 'T-001'
}

# ---------------------------------------------------------------------------
# Run suite
# ---------------------------------------------------------------------------

test_install_keeps_config_and_bad_args() {
  # A reinstall without --agent keeps the user's AGENT_CLI
  sed -i '' 's/^AGENT_CLI=.*/AGENT_CLI=codex/' "$VAULT/.agent-office/config"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
  grep -q '^AGENT_CLI=codex$' "$VAULT/.agent-office/config"
  # A reinstall with --agent changes it
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --agent agy >/dev/null
  grep -q '^AGENT_CLI=agy$' "$VAULT/.agent-office/config"
  # --agent as the last argument exits with an error and does not hang
  local rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --agent >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_lock_and_denied_paths() {
  . "$VAULT/.agent-office/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  # A stale lock (dead pid) is removed and the session runs
  mkdir -p "$LOG_DIR/T-001.lock"
  echo 999999 > "$LOG_DIR/T-001.lock/pid"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  [ ! -e "$LOG_DIR/T-001.lock" ]
  # A live lock (this shell's pid) skips the session
  : > "$STUB_AGENT_LOG"
  rm -f "$LOG_DIR/T-001.last-work"
  mkdir -p "$LOG_DIR/T-001.lock"
  echo $$ > "$LOG_DIR/T-001.lock/pid"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  [ ! -s "$STUB_AGENT_LOG" ]
  rm -rf "$LOG_DIR/T-001.lock"
  # Claude Code gets deny rules for private/, .obsidian/, .trash/, and .agent-office/
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  local denied
  denied="$(grep -A1 '^ARG: --disallowedTools$' "$STUB_AGENT_LOG" | tail -n 1)"
  case "$denied" in *'Read(./private/**)'*) ;; *) return 1 ;; esac
  case "$denied" in *'Edit(./.obsidian/**)'*) ;; *) return 1 ;; esac
  case "$denied" in *'Read(./.trash/**)'*) ;; *) return 1 ;; esac
  case "$denied" in *'Edit(./.agent-office/**)'*) ;; *) return 1 ;; esac
}

test_no_personal_data() {
  if grep -rIlE 'popo|Po-Chun|@gmail|/Users/' "$REPO_DIR/install.sh" "$REPO_DIR/template" "$REPO_DIR/launchd"; then return 1; fi
}

test_meeting_blocks_work_and_prep_once() {
  . "$VAULT/.agent-office/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  # A live meeting (this shell's pid) blocks tick and work.sh
  echo $$ > "$LOG_DIR/T-001.meeting.pid"
  AO_HOUR=10 /bin/bash "$VAULT/.agent-office/tick.sh"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001 2>/dev/null
  [ ! -s "$STUB_AGENT_LOG" ]
  # A dead meeting pid does not block
  echo 999999 > "$LOG_DIR/T-001.meeting.pid"
  AO_HOUR=10 /bin/bash "$VAULT/.agent-office/tick.sh"
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"

  # Prep: one try per meeting, also when no agenda is written
  local m="2030-01-01 15:00"
  sed -i '' "s/^meeting:.*/meeting: $m/" "$t1"
  local m_epoch; m_epoch="$(to_epoch "$m")"
  printf '#!/bin/bash\necho "no agenda"\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
  : > "$STUB_AGENT_LOG"
  AO_NOW="$((m_epoch - 30 * 60))" AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ -f "$LOG_DIR/T-001.prepped-2030-01-01 1500" ]
  grep -q 'prep start T-001' "$LOG_DIR/agent.log"
  local n1; n1="$(grep -c 'prep start T-001' "$LOG_DIR/agent.log")"
  AO_NOW="$((m_epoch - 25 * 60))" AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ "$(grep -c 'prep start T-001' "$LOG_DIR/agent.log")" -eq "$n1" ]
}

test_plist_keeps_sessions_and_escapes_path() {
  grep -q '<key>AbandonProcessGroup</key>' "$REPO_DIR/launchd/tick.plist"
  local vault='/tmp/a&b|c<d>' out="$test_tmp/t.plist"
  # Same escaping as install.sh
  local xml esc
  xml="$(printf '%s' "$vault" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  esc="$(printf '%s' "$xml" | sed -e 's/[\\&|]/\\&/g')"
  sed -e "s|__VAULT__|$esc|g" -e "s|__LABEL__|x|g" "$REPO_DIR/launchd/tick.plist" > "$out"
  plutil -lint "$out" >/dev/null
  [ "$(plutil -extract ProgramArguments.1 raw "$out")" = "$vault/.agent-office/tick.sh" ]
  grep -qF "$(sed -n '/Escape the path for XML/,/plutil -lint/p' "$REPO_DIR/install.sh" | grep 'xml=')" "$REPO_DIR/install.sh"
}

run_test "meeting blocks work, prep tried once per meeting" test_meeting_blocks_work_and_prep_once
run_test "launchd plist keeps sessions and escapes the vault path" test_plist_keeps_sessions_and_escapes_path
run_test "install.sh keeps config on reinstall and rejects bad args" test_install_keeps_config_and_bad_args
run_test "lib.sh stale lock, live lock, and denied paths" test_lock_and_denied_paths
run_test "no personal data in shipped files" test_no_personal_data
run_test "install.sh layout and date replacement" test_install_layout_and_dates
run_test "install.sh --agent flag and invalid --agent" test_install_agent_flag_and_invalid
run_test "install.sh does not overwrite modified files" test_install_second_run_does_not_overwrite
run_test "lib.sh fm and cfg" test_lib_fm_and_cfg
run_test "lib.sh delegated, ticket_file, and to_epoch" test_lib_delegated_ticket_file_to_epoch
run_test "work.sh guards (non-doing, agent_state, non-delegated)" test_work_guards
run_test "work.sh runs claude stub and writes logs/breadcrumbs" test_work_valid_claude_session
run_test "work.sh codex exec and agent_dir validation" test_work_codex_and_agent_dir
run_test "tick.sh work hours, agent_state, and WORK_EVERY_HOURS" test_tick_work_hours_and_throttling
run_test "tick.sh prep and single reminder notification" test_tick_prep_and_reminder
run_test "tui.py module functions and --print" test_tui_module_and_print

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
