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

    unset AGENT_CLI WORK_EVERY_HOURS WORK_HOURS_FROM WORK_HOURS_TO PREP_BEFORE_MIN REMIND_BEFORE_MIN AO_NOW AO_HOUR ADDONS AO_TICKET AO_HEADLESS
    # Profile keys: a developer's shell must not change the results
    unset AO_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS H_TIME MARK CRUMB_STOP CRUMB_NEXT CRUMB_OPENED \
      MEETINGS_DIR OUTPUTS_DIR RULES_FILE SEC_WORK SEC_PREP SEC_MEETING SEC_TALK WRITE_LANG AGENT_DIR_ROOTS AO_LANG MEETINGS_DIR OUTPUTS_DIR RULES_FILE

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
  grep -q 'stub result text' "$VAULT/.agent-office/logs/T-001-last-work.txt"
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
  if grep -rIlE 'popo|Po-Chun|@gmail|/Users/' "$REPO_DIR/install.sh" "$REPO_DIR/template" "$REPO_DIR/locale" "$REPO_DIR/launchd"; then return 1; fi
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

test_profiles_and_cfg_precedence() {
  [ -f "$REPO_DIR/template/.agent-office/profiles/en.conf" ]
  [ -f "$REPO_DIR/template/.agent-office/profiles/zh-TW.conf" ]
  [ -f "$VAULT/.agent-office/profiles/en.conf" ]
  [ -f "$VAULT/.agent-office/profiles/zh-TW.conf" ]

  unset AO_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS MARK CRUMB_STOP CRUMB_NEXT MEETINGS_DIR OUTPUTS_DIR RULES_FILE
  . "$VAULT/.agent-office/lib.sh"

  # Default profile (AO_LANG=en)
  [ "$(cfg H_DONE fallback)" = "## Done when" ]
  [ "$(cfg H_SUBTASKS fallback)" = "## Subtasks" ]
  [ "$(cfg H_DECISIONS fallback)" = "## Decisions" ]
  [ "$(cfg H_CRUMBS fallback)" = "## Breadcrumbs" ]
  [ "$(cfg MARK fallback)" = "(agent)" ]
  [ "$(cfg CRUMB_STOP fallback)" = "Stopped:" ]
  [ "$(cfg CRUMB_NEXT fallback)" = "Next:" ]
  [ "$(cfg MEETINGS_DIR fallback)" = "Office/meetings" ]
  [ "$(cfg OUTPUTS_DIR fallback)" = "Office/outputs" ]
  [ "$(cfg RULES_FILE fallback)" = "AGENTS.md" ]

  # AO_LANG=zh-TW in config selects zh-TW profile
  if grep -q '^AO_LANG=' "$VAULT/.agent-office/config"; then
    sed -i '' 's/^AO_LANG=.*/AO_LANG=zh-TW/' "$VAULT/.agent-office/config"
  else
    echo "AO_LANG=zh-TW" >> "$VAULT/.agent-office/config"
  fi
  unset AO_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS MARK CRUMB_STOP CRUMB_NEXT MEETINGS_DIR OUTPUTS_DIR RULES_FILE
  . "$VAULT/.agent-office/lib.sh"

  [ "$(cfg H_DONE fallback)" = "## 完成條件" ]
  [ "$(cfg H_SUBTASKS fallback)" = "## 子任務" ]
  [ "$(cfg H_DECISIONS fallback)" = "## Decisions" ]
  [ "$(cfg H_CRUMBS fallback)" = "## Breadcrumb" ]
  [ "$(cfg MARK fallback)" = "（agent）" ]
  [ "$(cfg CRUMB_STOP fallback)" = "停在：" ]
  [ "$(cfg CRUMB_NEXT fallback)" = "下一步：" ]
  [ "$(cfg MEETINGS_DIR fallback)" = "Office/會議" ]
  [ "$(cfg OUTPUTS_DIR fallback)" = "Office/產出" ]
  [ "$(cfg RULES_FILE fallback)" = "AGENTS.md" ]

  # Precedence: env > .agent-office/config > selected profile > DEFAULT
  [ "$(cfg UNSET_KEY_XYZ my_default)" = "my_default" ]
  unset OUTPUTS_DIR
  [ "$(cfg OUTPUTS_DIR my_default)" = "Office/產出" ]
  echo "OUTPUTS_DIR=Custom/outputs" >> "$VAULT/.agent-office/config"
  unset OUTPUTS_DIR
  . "$VAULT/.agent-office/lib.sh"
  [ "$(cfg OUTPUTS_DIR my_default)" = "Custom/outputs" ]
  [ "$(OUTPUTS_DIR=Env/outputs cfg OUTPUTS_DIR my_default)" = "Env/outputs" ]
}

test_lib_delegated_fullwidth_any_profile() {
  local f_fw="$VAULT/Tickets/T-020 Fullwidth Agent.md"
  cat > "$f_fw" <<'EOF'
---
id: T-020
owner:
---
## 子任務
- [ ] 撰寫說明（agent）
EOF

  local f_hw="$VAULT/Tickets/T-021 Halfwidth Agent.md"
  cat > "$f_hw" <<'EOF'
---
id: T-021
owner:
---
## Subtasks
- [ ] Write note (agent)
EOF

  local f_done="$VAULT/Tickets/T-022 Done Fullwidth.md"
  cat > "$f_done" <<'EOF'
---
id: T-022
owner:
---
## 子任務
- [x] 撰寫說明（agent）
- [ ] 一般子任務
EOF

  # en profile accepts both (agent) and （agent）
  unset AO_LANG
  . "$VAULT/.agent-office/lib.sh"
  delegated "$f_fw"
  delegated "$f_hw"
  if delegated "$f_done"; then return 1; fi

  # zh-TW profile accepts both (agent) and （agent）
  if grep -q '^AO_LANG=' "$VAULT/.agent-office/config"; then
    sed -i '' 's/^AO_LANG=.*/AO_LANG=zh-TW/' "$VAULT/.agent-office/config"
  else
    echo "AO_LANG=zh-TW" >> "$VAULT/.agent-office/config"
  fi
  unset AO_LANG
  . "$VAULT/.agent-office/lib.sh"
  delegated "$f_fw"
  delegated "$f_hw"
  if delegated "$f_done"; then return 1; fi
}

test_meetings_dir_profile_and_override() {
  . "$VAULT/.agent-office/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  local m_str="2026-11-11 15:00"
  local m_epoch
  m_epoch="$(to_epoch "$m_str")"
  sed -i '' "s/^meeting:$/meeting: $m_str/" "$t1"

  if grep -q '^AO_LANG=' "$VAULT/.agent-office/config"; then
    sed -i '' 's/^AO_LANG=.*/AO_LANG=zh-TW/' "$VAULT/.agent-office/config"
  else
    echo "AO_LANG=zh-TW" >> "$VAULT/.agent-office/config"
  fi

  # prep.sh with AO_LANG=zh-TW writes agenda path under Office/會議
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/prep.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/會議/2026-11-11 1500 T-001.md'

  # tick.sh looks for agenda under Office/會議 (skips prep when agenda exists there)
  rm -f "$VAULT/.agent-office/logs/T-001.prepped-2026-11-11 1500"
  mkdir -p "$VAULT/Office/會議"
  : > "$VAULT/Office/會議/2026-11-11 1500 T-001.md"
  : > "$STUB_AGENT_LOG"
  AO_NOW="$((m_epoch - 30 * 60))" AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]

  # tick.sh runs prep when agenda under Office/會議 is missing
  rm -f "$VAULT/Office/會議/2026-11-11 1500 T-001.md"
  AO_NOW="$((m_epoch - 30 * 60))" AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/會議/2026-11-11 1500 T-001.md'

  # Config line MEETINGS_DIR=Agent Office/會議 overrides the profile
  echo "MEETINGS_DIR=Agent Office/會議" >> "$VAULT/.agent-office/config"
  rm -f "$VAULT/.agent-office/logs/T-001.prepped-2026-11-11 1500"
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/prep.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Agent Office/會議/2026-11-11 1500 T-001.md'

  # tick.sh respects MEETINGS_DIR=Agent Office/會議 override
  rm -f "$VAULT/.agent-office/logs/T-001.prepped-2026-11-11 1500"
  mkdir -p "$VAULT/Agent Office/會議"
  : > "$VAULT/Agent Office/會議/2026-11-11 1500 T-001.md"
  : > "$STUB_AGENT_LOG"
  AO_NOW="$((m_epoch - 30 * 60))" AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]
}

test_rules_file_in_prompts() {
  local t1="$VAULT/Tickets/T-001 Try Agent Office.md"
  sed -i '' 's/^meeting:$/meeting: 2026-11-11 15:00/' "$t1"
  echo "RULES_FILE=Agent Office/AGENT.md" >> "$VAULT/.agent-office/config"

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Agent Office/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/prep.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Agent Office/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/meeting.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Agent Office/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/meeting.sh" T-001 --talk
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Agent Office/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi
}

test_install_lang_flag() {
  # Default en install must NOT create Office/會議
  if [ -e "$VAULT/Office/會議" ]; then return 1; fi

  local v_zh="$VAULT-zh"
  /bin/bash "$REPO_DIR/install.sh" "$v_zh" --lang zh-TW >/dev/null
  grep -q '^AO_LANG=zh-TW$' "$v_zh/.agent-office/config"
  [ -f "$v_zh/AGENTS.md" ]
  grep -q '完成條件' "$v_zh/AGENTS.md"

  local t1="" f
  for f in "$v_zh/Tickets/T-001 "*.md; do
    [ -f "$f" ] && t1="$f"
  done
  [ -n "$t1" ]
  grep -q '^## 完成條件$' "$t1"
  grep -q '^## 子任務$' "$t1"
  grep -q '^## Breadcrumb$' "$t1"
  grep -qE '^[[:space:]]*- \[ \] .*（agent）[[:space:]]*$' "$t1"

  [ -d "$v_zh/Office/會議" ]
  [ -d "$v_zh/Office/產出" ]
  if [ -e "$v_zh/Office/meetings" ]; then return 1; fi
  if [ -e "$v_zh/Office/outputs" ]; then return 1; fi

  # Reinstall without --lang keeps AO_LANG
  /bin/bash "$REPO_DIR/install.sh" "$v_zh" >/dev/null
  grep -q '^AO_LANG=zh-TW$' "$v_zh/.agent-office/config"

  # --lang with a bad value exits 2
  local rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-bad1" --lang invalid >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]

  # --lang as the last argument exits 2
  rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-bad2" --lang >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_install_link_flag() {
  echo "# pre-link-marker" >> "$VAULT/.agent-office/work.sh"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --link >/dev/null

  local item target
  for item in lib.sh work.sh prep.sh meeting.sh tick.sh tui.py profiles; do
    [ -L "$VAULT/.agent-office/$item" ]
    target="$(readlink "$VAULT/.agent-office/$item")"
    case "$target" in
      *"template/.agent-office/$item") ;;
      *) return 1 ;;
    esac
  done

  # .agent-office/config is a regular file, not a symlink
  [ -f "$VAULT/.agent-office/config" ]
  if [ -L "$VAULT/.agent-office/config" ]; then return 1; fi

  # A script that differs from the repo is kept as <name>.bak (spec revised in Code stage:
  # a script that is the same as the repo needs no backup, so a fresh --link install has no .bak noise)
  [ -f "$VAULT/.agent-office/work.sh.bak" ]
  if [ -L "$VAULT/.agent-office/work.sh.bak" ]; then return 1; fi
  grep -q '^# pre-link-marker$' "$VAULT/.agent-office/work.sh.bak"
  for item in lib.sh prep.sh meeting.sh tick.sh tui.py profiles; do
    if [ -e "$VAULT/.agent-office/$item.bak" ]; then return 1; fi
  done

  # work.sh run through the symlink still finds the vault (logs in VAULT/.agent-office/logs, not repo)
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  [ -f "$VAULT/.agent-office/logs/T-001-last-work.txt" ]
  [ -f "$VAULT/.agent-office/logs/agent.log" ]
  if [ -e "$REPO_DIR/template/.agent-office/logs" ]; then return 1; fi
}

test_work_claude_stream_json() {
  /bin/bash "$VAULT/.agent-office/work.sh" T-001

  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --output-format$' "$STUB_AGENT_LOG"
  grep -q '^ARG: stream-json$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --verbose$' "$STUB_AGENT_LOG"

  local stream="$VAULT/.agent-office/logs/T-001-stream.jsonl"
  [ -f "$stream" ]
  grep -q '{"type":"assistant"' "$stream"
  grep -q '{"type":"result","result":"stub result text"}' "$stream"

  local last_work="$VAULT/.agent-office/logs/T-001-last-work.txt"
  [ -f "$last_work" ]
  [ "$(cat "$last_work")" = "stub result text" ]
}

test_tui_zh_profile() {
  # en behavior and --print
  python3 -I "$TESTS_DIR/test_tui.py" "$VAULT"
  local out_en
  out_en="$(cd "$VAULT" && python3 -I .agent-office/tui.py --print)"
  printf '%s\n' "$out_en" | grep -q 'T-001'

  # zh-TW behavior and --print
  if grep -q '^AO_LANG=' "$VAULT/.agent-office/config"; then
    sed -i '' 's/^AO_LANG=.*/AO_LANG=zh-TW/' "$VAULT/.agent-office/config"
  else
    echo "AO_LANG=zh-TW" >> "$VAULT/.agent-office/config"
  fi
  rm -f "$VAULT/Tickets/T-001 Try Agent Office.md" "$VAULT/Tickets/T-002 Second task.md"
  python3 -I "$TESTS_DIR/test_tui_zh.py" "$VAULT"

  local out_zh
  out_zh="$(cd "$VAULT" && python3 -I .agent-office/tui.py --print)"
  printf '%s\n' "$out_zh" | grep -q 'T-001'
  printf '%s\n' "$out_zh" | grep -q 'T-002'
}

test_tui_screen_both_languages() {
  # Draw the real curses screen in a pseudo-terminal, press keys, and quit, in en and zh-TW.
  local lang
  for lang in en zh-TW; do
    sed -i '' "s/^AO_LANG=.*/AO_LANG=$lang/" "$VAULT/.agent-office/config"
    python3 -I "$TESTS_DIR/tui_screen.py" "$VAULT" "$lang"
  done
}

test_lang_on_old_config_and_relink() {
  # A config from v0.1 has no AO_LANG line: --lang must add it
  sed -i '' '/^AO_LANG=/d' "$VAULT/.agent-office/config"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --lang zh-TW >/dev/null
  grep -q '^AO_LANG=zh-TW$' "$VAULT/.agent-office/config"
  ( . "$VAULT/.agent-office/lib.sh"; [ "$AO_LANG" = zh-TW ] && [ "$MEETINGS" = "Office/會議" ] )
  # --link twice: still links, no .bak of a link, and the repo's file modes do not change
  # Work on a copy of the repo, so the test never changes the real repo's files.
  local repo="$test_tmp/repo-copy" mode
  mkdir -p "$repo" && cp -R "$REPO_DIR/install.sh" "$REPO_DIR/template" "$REPO_DIR/locale" "$REPO_DIR/launchd" "$repo/"
  chmod a-x "$repo/template/.agent-office/prep.sh"
  mode="$(stat -f '%Lp' "$repo/template/.agent-office/prep.sh")"
  /bin/bash "$repo/install.sh" "$VAULT" --link >/dev/null
  /bin/bash "$repo/install.sh" "$VAULT" --link >/dev/null
  [ "$(stat -f '%Lp' "$repo/template/.agent-office/prep.sh")" = "$mode" ]
  [ -L "$VAULT/.agent-office/work.sh" ]
  if [ -e "$VAULT/.agent-office/work.sh.bak" ]; then return 1; fi
}

test_stream_error_result() {
  # A result event without text (an error such as error_max_turns) still gives the manager a reason
  printf '#!/bin/bash\necho '"'"'{"type":"result","subtype":"error_max_turns","is_error":true}'"'"'\n' > "$HOME/.local/bin/claude"
  chmod +x "$HOME/.local/bin/claude"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  grep -q 'error_max_turns' "$VAULT/.agent-office/logs/T-001-last-work.txt"
  # No result event at all: the stderr tail is kept
  printf '#!/bin/bash\necho "auth failed" >&2\nexit 1\n' > "$HOME/.local/bin/claude"
  rm -f "$VAULT/.agent-office/logs/T-001.last-work"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001 || true
  grep -q 'auth failed' "$VAULT/.agent-office/logs/T-001-last-work.txt"
}

# ---------------------------------------------------------------------------
# 6. Add-on tests (Specs A-E)
# ---------------------------------------------------------------------------

test_a_addon_mechanism() {
  grep -q '^ADDONS=$' "$VAULT/.agent-office/config"
  ( . "$VAULT/.agent-office/lib.sh"; type emit >/dev/null 2>&1 )

  local fake_log="$VAULT/.agent-office/logs/fake-events.log"
  mkdir -p "$VAULT/.agent-office/addons/fake"
  cat > "$VAULT/.agent-office/addons/fake/on_event" <<EOF
#!/bin/bash
echo "\$1 \$2 \$3" >> "$fake_log"
EOF
  chmod +x "$VAULT/.agent-office/addons/fake/on_event"

  # With ADDONS empty nothing is called
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  if [ -s "$fake_log" ]; then return 1; fi

  # With ADDONS=fake: work.sh emits session_start T-001 bg then session_end T-001 bg
  sed -i '' 's/^ADDONS=.*/ADDONS=fake/' "$VAULT/.agent-office/config"
  : > "$fake_log"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  [ "$(sed -n '1p' "$fake_log")" = "session_start T-001 bg" ]
  [ "$(tail -n 1 "$fake_log")" = "session_end T-001 bg" ]

  # tick.sh (AO_HOUR=22 so no work starts) emits tick - -
  : > "$fake_log"
  AO_HOUR=22 /bin/bash "$VAULT/.agent-office/tick.sh"
  [ "$(cat "$fake_log")" = "tick - -" ]

  # meeting.sh emits meeting_start ID <pid> before the agent and meeting_end ID <pid> after it exits
  : > "$fake_log"
  /bin/bash "$VAULT/.agent-office/meeting.sh" T-001
  local m_start m_end m_pid
  m_start="$(sed -n '1p' "$fake_log")"
  m_end="$(sed -n '2p' "$fake_log")"
  m_pid="${m_start#meeting_start T-001 }"
  [ -n "$m_pid" ]
  case "$m_pid" in *[!0-9]*) return 1 ;; esac
  [ "$m_start" = "meeting_start T-001 $m_pid" ]
  [ "$m_end" = "meeting_end T-001 $m_pid" ]

  # An on_event that exits 1 (or a missing add-on) does not make work.sh fail
  sed -i '' 's/^ADDONS=.*/ADDONS=missing,fake/' "$VAULT/.agent-office/config"
  printf '#!/bin/bash\nexit 1\n' > "$VAULT/.agent-office/addons/fake/on_event"
  chmod +x "$VAULT/.agent-office/addons/fake/on_event"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
}

test_b_install_addons() {
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog,session >/dev/null
  grep -q '^ADDONS=timelog,session$' "$VAULT/.agent-office/config"

  [ -d "$VAULT/.agent-office/addons/timelog" ]
  [ -x "$VAULT/.agent-office/addons/timelog/on_event" ]
  [ -f "$VAULT/.agent-office/addons/timelog/timelog.py" ]
  [ -d "$VAULT/.agent-office/addons/session" ]
  [ -f "$VAULT/.agent-office/addons/session/hook.py" ]
  [ -f "$VAULT/.agent-office/addons/session/install.py" ]

  # session install.py adds hook to VAULT/.claude/settings.json (never ~/.claude)
  [ -f "$VAULT/.claude/settings.json" ]
  grep -q 'hook.py' "$VAULT/.claude/settings.json"
  if [ -e "$HOME/.claude/settings.json" ]; then return 1; fi

  # Reinstall without --addons keeps ADDONS
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
  grep -q '^ADDONS=timelog,session$' "$VAULT/.agent-office/config"

  # With --link, the addons folder is a symlink into the repo
  local v_link="$VAULT-link"
  /bin/bash "$REPO_DIR/install.sh" "$v_link" --link --addons timelog,session >/dev/null
  [ -L "$v_link/.agent-office/addons" ]
  case "$(readlink "$v_link/.agent-office/addons")" in
    *"template/.agent-office/addons") ;;
    *) return 1 ;;
  esac

  # An unknown add-on name (or missing --addons value) exits 2
  local rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-bad1" --addons unknown >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-bad2" --addons timelog,unknown >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-bad3" --addons >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_c_timelog() {
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog >/dev/null
  ( unset AO_LANG H_TIME; . "$VAULT/.agent-office/lib.sh"; [ "$(cfg H_TIME fallback)" = "## Time" ] )
  ( unset H_TIME; AO_LANG=zh-TW; . "$VAULT/.agent-office/lib.sh"; [ "$(cfg H_TIME fallback)" = "## 時間" ] )

  python3 -I "$TESTS_DIR/test_c_timelog.py" "$VAULT"
}

test_d_session() {
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog,session >/dev/null
  python3 -I "$TESTS_DIR/test_d_session.py" "$VAULT"

  # T-001 has session: sess-0002-bbbb from test_d_session.py, but no transcript file yet -> no --resume
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/meeting.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^AO_TICKET: T-001$' "$STUB_AGENT_LOG"
  if grep -q '^ARG: --resume$' "$STUB_AGENT_LOG"; then return 1; fi

  # When ~/.claude/projects/*/<sid>.jsonl exists -> meeting.sh calls claude with --resume <sid>
  mkdir -p "$HOME/.claude/projects/vault-proj"
  : > "$HOME/.claude/projects/vault-proj/sess-0002-bbbb.jsonl"
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/meeting.sh" T-001
  grep -q '^AO_TICKET: T-001$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --resume$' "$STUB_AGENT_LOG"
  grep -q '^ARG: sess-0002-bbbb$' "$STUB_AGENT_LOG"

  # When ticket has no session -> no --resume even if transcript files exist
  sed -i '' 's/^session: .*/session:/' "$VAULT/Tickets/T-001 Try Agent Office.md"
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/meeting.sh" T-001
  grep -q '^AO_TICKET: T-001$' "$STUB_AGENT_LOG"
  if grep -q '^ARG: --resume$' "$STUB_AGENT_LOG"; then return 1; fi

  # Background sessions export AO_HEADLESS=1
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.agent-office/work.sh" T-001
  grep -q '^AO_HEADLESS: 1$' "$STUB_AGENT_LOG"
}

test_e_tui_week_report() {
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog >/dev/null
  python3 -I "$TESTS_DIR/test_e_tui.py" "$VAULT"
}

test_install_existing_tickets() {
  # A vault that has tickets already does not get the example ticket (two T-001 files would clash)
  local v="$VAULT-existing"
  mkdir -p "$v/Tickets"
  printf -- '---\nid: T-001\nstatus: doing\ncreated: 2026-01-01\n---\n# Mine\n' > "$v/Tickets/T-001 Mine.md"
  local before; before="$(cat "$v/Tickets/T-001 Mine.md")"
  /bin/bash "$REPO_DIR/install.sh" "$v" --lang zh-TW >/dev/null
  [ ! -e "$v/Tickets/T-001 試用 Agent Office.md" ]
  [ "$(cat "$v/Tickets/T-001 Mine.md")" = "$before" ]
  [ -f "$v/.agent-office/config" ]
  # A new vault still gets it
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-new" --lang zh-TW >/dev/null
  [ -f "$VAULT-new/Tickets/T-001 試用 Agent Office.md" ]
}

test_install_rules_path() {
  # --rules puts the rules file in a folder and leaves the vault root alone
  local v="$VAULT-rules"
  /bin/bash "$REPO_DIR/install.sh" "$v" --lang zh-TW --rules "Agent Office/AGENTS.md" >/dev/null
  [ -f "$v/Agent Office/AGENTS.md" ]
  grep -q '^# Agent Office 守則' "$v/Agent Office/AGENTS.md"
  grep -q '^RULES_FILE=Agent Office/AGENTS.md$' "$v/.agent-office/config"
  [ ! -e "$v/AGENTS.md" ] && [ ! -e "$v/CLAUDE.md" ] && [ ! -e "$v/GEMINI.md" ]
  # A reinstall without --rules keeps the setting and still leaves the root alone
  /bin/bash "$REPO_DIR/install.sh" "$v" >/dev/null
  grep -q '^RULES_FILE=Agent Office/AGENTS.md$' "$v/.agent-office/config"
  [ ! -e "$v/AGENTS.md" ] && [ ! -e "$v/CLAUDE.md" ]
  # A root CLAUDE.md of the user stays
  printf 'mine\n' > "$v/CLAUDE.md"
  /bin/bash "$REPO_DIR/install.sh" "$v" >/dev/null
  [ "$(cat "$v/CLAUDE.md")" = mine ]
  # The work prompt names the rules file
  /bin/bash "$v/.agent-office/work.sh" "T-001" >/dev/null 2>&1 || true
  grep -q 'Agent Office/AGENTS.md' "$STUB_AGENT_LOG"
  # Bad paths exit 2
  local rc bad
  # --rules AGENTS.md switches back to the vault root
  /bin/bash "$REPO_DIR/install.sh" "$v" --rules AGENTS.md >/dev/null
  grep -q '^RULES_FILE=AGENTS.md$' "$v/.agent-office/config"
  [ -f "$v/AGENTS.md" ]
  # A dangling symlink of the user at the root stays
  local v2="$VAULT-rules2"; mkdir -p "$v2"; ln -s /nonexistent "$v2/GEMINI.md"
  /bin/bash "$REPO_DIR/install.sh" "$v2" --rules "Agent Office/AGENTS.md" >/dev/null
  [ -L "$v2/GEMINI.md" ]
  for bad in "../x.md" "/abs/x.md" "x.txt" "a|b.md" "" "a&b.md" 'a\b.md' "a/../b.md" "$(printf 'a\nb.md')"; do
    rc=0; /bin/bash "$REPO_DIR/install.sh" "$VAULT-badrules" --rules "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || return 1
  done
}

run_test "install.sh --lang on an old config, --link twice" test_lang_on_old_config_and_relink
run_test "stream-json error result and stderr fallback" test_stream_error_result
run_test "tui.py draws the screen and quits in en and zh-TW" test_tui_screen_both_languages
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
run_test "profiles (en, zh-TW) and cfg precedence" test_profiles_and_cfg_precedence
run_test "lib.sh delegated accepts (agent) and （agent） in any profile" test_lib_delegated_fullwidth_any_profile
run_test "prep.sh and tick.sh use MEETINGS_DIR from profile and config" test_meetings_dir_profile_and_override
run_test "work.sh, prep.sh, meeting.sh prompts use RULES_FILE" test_rules_file_in_prompts
run_test "install.sh --lang en|zh-TW layout, reinstall, and bad args" test_install_lang_flag
run_test "install.sh --link symlinks, .bak backups, and vault log path" test_install_link_flag
run_test "install.sh skips the example ticket in a vault with tickets" test_install_existing_tickets
run_test "install.sh --rules puts the rules file in a folder" test_install_rules_path
run_test "work.sh claude stream-json output and result extraction" test_work_claude_stream_json
run_test "tui.py with AO_LANG=zh-TW and --print" test_tui_zh_profile
run_test "A: add-on mechanism and core events" test_a_addon_mechanism
run_test "B: install.sh --addons flag, link, and session hook" test_b_install_addons
run_test "C: timelog add-on events, sync, Daily table, status history, and week" test_c_timelog
run_test "D: session add-on hook, install.py, meeting resume, and headless" test_d_session
run_test "E: tui.py week_report_lines with timelog on and off" test_e_tui_week_report

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
