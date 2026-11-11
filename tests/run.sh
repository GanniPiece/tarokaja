#!/bin/bash
# Automated test suite for Tarokaja (compatible with macOS bash 3.2).
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

    unset AGENT_CLI WORK_EVERY_HOURS WORK_HOURS_FROM WORK_HOURS_TO PREP_BEFORE_MIN REMIND_BEFORE_MIN TK_NOW TK_HOUR ADDONS TK_TICKET TK_HEADLESS
    # Profile keys: a developer's shell must not change the results
    unset TK_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS H_TIME MARK CRUMB_STOP CRUMB_NEXT CRUMB_OPENED \
      MEETINGS_DIR OUTPUTS_DIR RULES_FILE SEC_WORK SEC_PREP SEC_MEETING SEC_TALK WRITE_LANG AGENT_DIR_ROOTS TK_LANG MEETINGS_DIR OUTPUTS_DIR RULES_FILE

    VAULT="$test_tmp/vault"
    export VAULT
    export TK_FOREGROUND=1   # tick.sh runs sessions in the foreground, so tests can check them at once
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
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  [ -f "$t1" ]
  [ -f "$VAULT/.tarokaja/lib.sh" ]
  [ -f "$VAULT/.tarokaja/config" ]
  [ -x "$VAULT/.tarokaja/work.sh" ]
  [ -x "$VAULT/.tarokaja/prep.sh" ]
  [ -x "$VAULT/.tarokaja/meeting.sh" ]
  [ -x "$VAULT/.tarokaja/tick.sh" ]
  [ -x "$VAULT/.tarokaja/tui.py" ]

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
  grep -q '^AGENT_CLI=codex$' "$v2/.tarokaja/config"
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
  echo "custom-ticket-line" >> "$VAULT/Tickets/T-001 Try Tarokaja.md"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
  grep -q '^custom-marker-line$' "$VAULT/AGENTS.md"
  grep -q '^custom-ticket-line$' "$VAULT/Tickets/T-001 Try Tarokaja.md"
}

# ---------------------------------------------------------------------------
# 2. lib.sh tests
# ---------------------------------------------------------------------------

test_lib_fm_and_cfg() {
  . "$VAULT/.tarokaja/lib.sh"

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
  . "$VAULT/.tarokaja/lib.sh"

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
  [ "$found" = "$VAULT/Tickets/T-001 Try Tarokaja.md" ]
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
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"

  # Status not doing -> exits 0 without calling agent
  sed -i '' 's/^status: doing$/status: waiting/' "$t1"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001 >/dev/null 2>&1
  [ ! -s "$STUB_AGENT_LOG" ]

  # agent_state set -> exits 0 without calling agent
  sed -i '' 's/^status: waiting$/status: doing/' "$t1"
  sed -i '' 's/^agent_state:$/agent_state: decide/' "$t1"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001 >/dev/null 2>&1
  [ ! -s "$STUB_AGENT_LOG" ]

  # No (agent) subtask -> exits non-zero
  sed -i '' 's/^agent_state: decide$/agent_state:/' "$t1"
  sed -i '' 's/^- \[ \] \(.* (agent)\)$/- [x] \1/' "$t1"
  if /bin/bash "$VAULT/.tarokaja/work.sh" T-001 >/dev/null 2>&1; then
    return 1
  fi
  [ ! -s "$STUB_AGENT_LOG" ]
}

test_work_valid_claude_session() {
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001

  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^ARG: -p$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS.md'
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tickets/T-001 Try Tarokaja.md'

  [ -f "$VAULT/.tarokaja/logs/T-001-last-work.txt" ]
  grep -q 'stub result text' "$VAULT/.tarokaja/logs/T-001-last-work.txt"
  [ -s "$VAULT/.tarokaja/logs/T-001.last-work" ]
  [ ! -e "$VAULT/.tarokaja/logs/T-001.pid" ]
  grep -q '^- 2026-01-01 10:00 · \[agent\] Stopped: stub\. Next: stub\.$' "$t1"
}

test_work_codex_and_agent_dir() {
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"

  # AGENT_CLI=codex calls codex with exec
  AGENT_CLI=codex /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  grep -q '^CMD: codex$' "$STUB_AGENT_LOG"
  grep -q '^ARG: exec$' "$STUB_AGENT_LOG"

  # Relative agent_dir -> exits non-zero
  : > "$STUB_AGENT_LOG"
  sed -i '' 's/^links: \[\]$/agent_dir: relative\/path/' "$t1"
  if /bin/bash "$VAULT/.tarokaja/work.sh" T-001 >/dev/null 2>&1; then
    return 1
  fi
  [ ! -s "$STUB_AGENT_LOG" ]

  # Absolute existing folder outside AGENT_DIR_ROOTS -> refused, agent not called
  local ext_dir="$VAULT/../ext_work_dir"
  mkdir -p "$ext_dir"
  ext_dir="$(cd "$ext_dir" && pwd)"
  sed -i '' "s|^agent_dir: .*|agent_dir: $ext_dir|" "$t1"
  : > "$STUB_AGENT_LOG"
  if /bin/bash "$VAULT/.tarokaja/work.sh" T-001 2>/dev/null; then return 1; fi
  [ ! -s "$STUB_AGENT_LOG" ]

  # Inside AGENT_DIR_ROOTS -> claude stub gets --add-dir
  sed -i '' "s|^AGENT_DIR_ROOTS=.*|AGENT_DIR_ROOTS=$(dirname "$ext_dir")|" "$VAULT/.tarokaja/config"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --add-dir$' "$STUB_AGENT_LOG"
  # work.sh gives the agent the resolved path (no symlinks), as agent_dir_allowed checked it
  grep -q "^ARG: $(cd "$ext_dir" && pwd -P)$" "$STUB_AGENT_LOG"
}

# ---------------------------------------------------------------------------
# 4. tick.sh tests
# ---------------------------------------------------------------------------

test_tick_work_hours_and_throttling() {
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  local now=1700000000

  # Skips outside work hours
  TK_NOW="$now" TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]
  TK_NOW="$now" TK_HOUR=08 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]

  # Skips when ticket has agent_state
  sed -i '' 's/^agent_state:$/agent_state: decide/' "$t1"
  TK_NOW="$now" TK_HOUR=10 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]
  sed -i '' 's/^agent_state: decide$/agent_state:/' "$t1"

  # Skips when logs/<id>.last-work is newer than WORK_EVERY_HOURS (4h)
  mkdir -p "$VAULT/.tarokaja/logs"
  echo "$((now - 3600))" > "$VAULT/.tarokaja/logs/T-001.last-work"
  TK_NOW="$now" TK_HOUR=10 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]

  # Runs work inside work hours when last-work is older than WORK_EVERY_HOURS
  echo "$((now - 5 * 3600))" > "$VAULT/.tarokaja/logs/T-001.last-work"
  TK_NOW="$now" TK_HOUR=10 /bin/bash "$VAULT/.tarokaja/tick.sh"
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'run one work session on T-001'
}

test_tick_prep_and_reminder() {
  . "$VAULT/.tarokaja/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  local m_str="2026-11-11 15:00"
  local m_epoch
  m_epoch="$(to_epoch "$m_str")"

  sed -i '' "s/^meeting:$/meeting: $m_str/" "$t1"

  # Within PREP_BEFORE_MIN (30 min before) -> calls prep with agenda path under Office/meetings
  : > "$STUB_AGENT_LOG"
  : > "$STUB_NOTIFY_LOG"
  TK_NOW="$((m_epoch - 30 * 60))" TK_HOUR=14 /bin/bash "$VAULT/.tarokaja/tick.sh"
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/meetings/2026-11-11 1500 T-001.md'
  [ ! -s "$STUB_NOTIFY_LOG" ]

  # Within REMIND_BEFORE_MIN (3 min before) -> sends one reminder notification and not a second time on next tick
  : > "$STUB_AGENT_LOG"
  : > "$STUB_NOTIFY_LOG"
  TK_NOW="$((m_epoch - 3 * 60))" TK_HOUR=14 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ "$(grep -c 'Meeting soon: T-001' "$STUB_NOTIFY_LOG")" -eq 1 ]

  TK_NOW="$((m_epoch - 2 * 60))" TK_HOUR=14 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ "$(grep -c 'Meeting soon: T-001' "$STUB_NOTIFY_LOG")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 5. tui.py tests
# ---------------------------------------------------------------------------

test_tui_module_and_print() {
  python3 -I "$TESTS_DIR/test_tui.py" "$VAULT"

  local out
  out="$(cd "$VAULT" && python3 -I .tarokaja/tui.py --print)"
  printf '%s\n' "$out" | grep -q 'T-001'
}

# ---------------------------------------------------------------------------
# Run suite
# ---------------------------------------------------------------------------

test_install_keeps_config_and_bad_args() {
  # A reinstall without --agent keeps the user's AGENT_CLI
  sed -i '' 's/^AGENT_CLI=.*/AGENT_CLI=codex/' "$VAULT/.tarokaja/config"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
  grep -q '^AGENT_CLI=codex$' "$VAULT/.tarokaja/config"
  # A reinstall with --agent changes it
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --agent agy >/dev/null
  grep -q '^AGENT_CLI=agy$' "$VAULT/.tarokaja/config"
  # --agent as the last argument exits with an error and does not hang
  local rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --agent >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_lock_and_denied_paths() {
  . "$VAULT/.tarokaja/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  # A stale lock (dead pid) is removed and the session runs
  mkdir -p "$LOG_DIR/T-001.lock"
  echo 999999 > "$LOG_DIR/T-001.lock/pid"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  [ ! -e "$LOG_DIR/T-001.lock" ]
  # A live lock (this shell's pid) skips the session
  : > "$STUB_AGENT_LOG"
  rm -f "$LOG_DIR/T-001.last-work"
  mkdir -p "$LOG_DIR/T-001.lock"
  echo $$ > "$LOG_DIR/T-001.lock/pid"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  [ ! -s "$STUB_AGENT_LOG" ]
  rm -rf "$LOG_DIR/T-001.lock"
  # Claude Code gets deny rules for private/, .obsidian/, .trash/, and .tarokaja/
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  local denied
  denied="$(grep -A1 '^ARG: --disallowedTools$' "$STUB_AGENT_LOG" | tail -n 1)"
  case "$denied" in *'Read(./private/**)'*) ;; *) return 1 ;; esac
  case "$denied" in *'Edit(./.obsidian/**)'*) ;; *) return 1 ;; esac
  case "$denied" in *'Read(./.trash/**)'*) ;; *) return 1 ;; esac
  case "$denied" in *'Edit(./.tarokaja/**)'*) ;; *) return 1 ;; esac
}

test_no_personal_data() {
  if grep -rIlE 'popo|Po-Chun|@gmail|/Users/' "$REPO_DIR/install.sh" "$REPO_DIR/template" "$REPO_DIR/locale" "$REPO_DIR/launchd"; then return 1; fi
}

test_meeting_blocks_work_and_prep_once() {
  . "$VAULT/.tarokaja/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  # A live meeting (this shell's pid) blocks tick and work.sh
  echo $$ > "$LOG_DIR/T-001.meeting.pid"
  TK_HOUR=10 /bin/bash "$VAULT/.tarokaja/tick.sh"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001 2>/dev/null
  [ ! -s "$STUB_AGENT_LOG" ]
  # A dead meeting pid does not block
  echo 999999 > "$LOG_DIR/T-001.meeting.pid"
  TK_HOUR=10 /bin/bash "$VAULT/.tarokaja/tick.sh"
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"

  # Prep: one try per meeting, also when no agenda is written
  local m="2030-01-01 15:00"
  sed -i '' "s/^meeting:.*/meeting: $m/" "$t1"
  local m_epoch; m_epoch="$(to_epoch "$m")"
  printf '#!/bin/bash\necho "no agenda"\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
  : > "$STUB_AGENT_LOG"
  TK_NOW="$((m_epoch - 30 * 60))" TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ -f "$LOG_DIR/T-001.prepped-2030-01-01 1500" ]
  grep -q 'prep start T-001' "$LOG_DIR/agent.log"
  local n1; n1="$(grep -c 'prep start T-001' "$LOG_DIR/agent.log")"
  TK_NOW="$((m_epoch - 25 * 60))" TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
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
  [ "$(plutil -extract ProgramArguments.1 raw "$out")" = "$vault/.tarokaja/tick.sh" ]
  grep -qF "$(sed -n '/Escape the path for XML/,/plutil -lint/p' "$REPO_DIR/install.sh" | grep 'xml=')" "$REPO_DIR/install.sh"
}

test_profiles_and_cfg_precedence() {
  [ -f "$REPO_DIR/template/.tarokaja/profiles/en.conf" ]
  [ -f "$REPO_DIR/template/.tarokaja/profiles/zh-TW.conf" ]
  [ -f "$VAULT/.tarokaja/profiles/en.conf" ]
  [ -f "$VAULT/.tarokaja/profiles/zh-TW.conf" ]

  unset TK_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS MARK CRUMB_STOP CRUMB_NEXT MEETINGS_DIR OUTPUTS_DIR RULES_FILE
  . "$VAULT/.tarokaja/lib.sh"

  # Default profile (TK_LANG=en)
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

  # TK_LANG=zh-TW in config selects zh-TW profile
  if grep -q '^TK_LANG=' "$VAULT/.tarokaja/config"; then
    sed -i '' 's/^TK_LANG=.*/TK_LANG=zh-TW/' "$VAULT/.tarokaja/config"
  else
    echo "TK_LANG=zh-TW" >> "$VAULT/.tarokaja/config"
  fi
  unset TK_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS MARK CRUMB_STOP CRUMB_NEXT MEETINGS_DIR OUTPUTS_DIR RULES_FILE
  . "$VAULT/.tarokaja/lib.sh"

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

  # Precedence: env > .tarokaja/config > selected profile > DEFAULT
  [ "$(cfg UNSET_KEY_XYZ my_default)" = "my_default" ]
  unset OUTPUTS_DIR
  [ "$(cfg OUTPUTS_DIR my_default)" = "Office/產出" ]
  echo "OUTPUTS_DIR=Custom/outputs" >> "$VAULT/.tarokaja/config"
  unset OUTPUTS_DIR
  . "$VAULT/.tarokaja/lib.sh"
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
  unset TK_LANG
  . "$VAULT/.tarokaja/lib.sh"
  delegated "$f_fw"
  delegated "$f_hw"
  if delegated "$f_done"; then return 1; fi

  # zh-TW profile accepts both (agent) and （agent）
  if grep -q '^TK_LANG=' "$VAULT/.tarokaja/config"; then
    sed -i '' 's/^TK_LANG=.*/TK_LANG=zh-TW/' "$VAULT/.tarokaja/config"
  else
    echo "TK_LANG=zh-TW" >> "$VAULT/.tarokaja/config"
  fi
  unset TK_LANG
  . "$VAULT/.tarokaja/lib.sh"
  delegated "$f_fw"
  delegated "$f_hw"
  if delegated "$f_done"; then return 1; fi
}

test_meetings_dir_profile_and_override() {
  . "$VAULT/.tarokaja/lib.sh"
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  local m_str="2026-11-11 15:00"
  local m_epoch
  m_epoch="$(to_epoch "$m_str")"
  sed -i '' "s/^meeting:$/meeting: $m_str/" "$t1"

  if grep -q '^TK_LANG=' "$VAULT/.tarokaja/config"; then
    sed -i '' 's/^TK_LANG=.*/TK_LANG=zh-TW/' "$VAULT/.tarokaja/config"
  else
    echo "TK_LANG=zh-TW" >> "$VAULT/.tarokaja/config"
  fi

  # prep.sh with TK_LANG=zh-TW writes agenda path under Office/會議
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/prep.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/會議/2026-11-11 1500 T-001.md'

  # tick.sh looks for agenda under Office/會議 (skips prep when agenda exists there)
  rm -f "$VAULT/.tarokaja/logs/T-001.prepped-2026-11-11 1500"
  mkdir -p "$VAULT/Office/會議"
  : > "$VAULT/Office/會議/2026-11-11 1500 T-001.md"
  : > "$STUB_AGENT_LOG"
  TK_NOW="$((m_epoch - 30 * 60))" TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]

  # tick.sh runs prep when agenda under Office/會議 is missing
  rm -f "$VAULT/Office/會議/2026-11-11 1500 T-001.md"
  TK_NOW="$((m_epoch - 30 * 60))" TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/會議/2026-11-11 1500 T-001.md'

  # Config line MEETINGS_DIR=Tarokaja/會議 overrides the profile
  echo "MEETINGS_DIR=Tarokaja/會議" >> "$VAULT/.tarokaja/config"
  rm -f "$VAULT/.tarokaja/logs/T-001.prepped-2026-11-11 1500"
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/prep.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tarokaja/會議/2026-11-11 1500 T-001.md'

  # tick.sh respects MEETINGS_DIR=Tarokaja/會議 override
  rm -f "$VAULT/.tarokaja/logs/T-001.prepped-2026-11-11 1500"
  mkdir -p "$VAULT/Tarokaja/會議"
  : > "$VAULT/Tarokaja/會議/2026-11-11 1500 T-001.md"
  : > "$STUB_AGENT_LOG"
  TK_NOW="$((m_epoch - 30 * 60))" TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ ! -s "$STUB_AGENT_LOG" ]
}

test_rules_file_in_prompts() {
  local t1="$VAULT/Tickets/T-001 Try Tarokaja.md"
  sed -i '' 's/^meeting:$/meeting: 2026-11-11 15:00/' "$t1"
  echo "RULES_FILE=Tarokaja/AGENT.md" >> "$VAULT/.tarokaja/config"

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tarokaja/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/prep.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tarokaja/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/meeting.sh" T-001
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tarokaja/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi

  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/meeting.sh" T-001 --talk
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Tarokaja/AGENT.md'
  if grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'AGENTS\.md'; then return 1; fi
}

test_install_lang_flag() {
  # Default en install must NOT create Office/會議
  if [ -e "$VAULT/Office/會議" ]; then return 1; fi

  local v_zh="$VAULT-zh"
  /bin/bash "$REPO_DIR/install.sh" "$v_zh" --lang zh-TW >/dev/null
  grep -q '^TK_LANG=zh-TW$' "$v_zh/.tarokaja/config"
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

  # Reinstall without --lang keeps TK_LANG
  /bin/bash "$REPO_DIR/install.sh" "$v_zh" >/dev/null
  grep -q '^TK_LANG=zh-TW$' "$v_zh/.tarokaja/config"

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
  echo "# pre-link-marker" >> "$VAULT/.tarokaja/work.sh"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --link >/dev/null

  local item target
  for item in lib.sh work.sh prep.sh meeting.sh tick.sh tui.py profiles; do
    [ -L "$VAULT/.tarokaja/$item" ]
    target="$(readlink "$VAULT/.tarokaja/$item")"
    case "$target" in
      *"template/.tarokaja/$item") ;;
      *) return 1 ;;
    esac
  done

  # .tarokaja/config is a regular file, not a symlink
  [ -f "$VAULT/.tarokaja/config" ]
  if [ -L "$VAULT/.tarokaja/config" ]; then return 1; fi

  # A script that differs from the repo is kept as <name>.bak (spec revised in Code stage:
  # a script that is the same as the repo needs no backup, so a fresh --link install has no .bak noise)
  [ -f "$VAULT/.tarokaja/work.sh.bak" ]
  if [ -L "$VAULT/.tarokaja/work.sh.bak" ]; then return 1; fi
  grep -q '^# pre-link-marker$' "$VAULT/.tarokaja/work.sh.bak"
  for item in lib.sh prep.sh meeting.sh tick.sh tui.py profiles; do
    if [ -e "$VAULT/.tarokaja/$item.bak" ]; then return 1; fi
  done

  # work.sh run through the symlink still finds the vault (logs in VAULT/.tarokaja/logs, not repo)
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  [ -f "$VAULT/.tarokaja/logs/T-001-last-work.txt" ]
  [ -f "$VAULT/.tarokaja/logs/agent.log" ]
  if [ -e "$REPO_DIR/template/.tarokaja/logs" ]; then return 1; fi
}

test_work_claude_stream_json() {
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001

  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --output-format$' "$STUB_AGENT_LOG"
  grep -q '^ARG: stream-json$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --verbose$' "$STUB_AGENT_LOG"

  local stream="$VAULT/.tarokaja/logs/T-001-stream.jsonl"
  [ -f "$stream" ]
  grep -q '{"type":"assistant"' "$stream"
  grep -q '{"type":"result","result":"stub result text"}' "$stream"

  local last_work="$VAULT/.tarokaja/logs/T-001-last-work.txt"
  [ -f "$last_work" ]
  [ "$(cat "$last_work")" = "stub result text" ]
}

test_tui_zh_profile() {
  # en behavior and --print
  python3 -I "$TESTS_DIR/test_tui.py" "$VAULT"
  local out_en
  out_en="$(cd "$VAULT" && python3 -I .tarokaja/tui.py --print)"
  printf '%s\n' "$out_en" | grep -q 'T-001'

  # zh-TW behavior and --print
  if grep -q '^TK_LANG=' "$VAULT/.tarokaja/config"; then
    sed -i '' 's/^TK_LANG=.*/TK_LANG=zh-TW/' "$VAULT/.tarokaja/config"
  else
    echo "TK_LANG=zh-TW" >> "$VAULT/.tarokaja/config"
  fi
  rm -f "$VAULT/Tickets/T-001 Try Tarokaja.md" "$VAULT/Tickets/T-002 Second task.md"
  python3 -I "$TESTS_DIR/test_tui_zh.py" "$VAULT"

  local out_zh
  out_zh="$(cd "$VAULT" && python3 -I .tarokaja/tui.py --print)"
  printf '%s\n' "$out_zh" | grep -q 'T-001'
  printf '%s\n' "$out_zh" | grep -q 'T-002'
}

test_tui_screen_both_languages() {
  # Draw the real curses screen in a pseudo-terminal, press keys, and quit, in en, zh-TW, and ja.
  local lang
  for lang in en zh-TW ja; do
    sed -i '' "s/^TK_LANG=.*/TK_LANG=$lang/" "$VAULT/.tarokaja/config"
    python3 -I "$TESTS_DIR/tui_screen.py" "$VAULT" "$lang"
  done
}

test_lang_on_old_config_and_relink() {
  # A config from v0.1 has no TK_LANG line: --lang must add it
  sed -i '' '/^TK_LANG=/d' "$VAULT/.tarokaja/config"
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --lang zh-TW >/dev/null
  grep -q '^TK_LANG=zh-TW$' "$VAULT/.tarokaja/config"
  ( . "$VAULT/.tarokaja/lib.sh"; [ "$TK_LANG" = zh-TW ] && [ "$MEETINGS" = "Office/會議" ] )
  # --link twice: still links, no .bak of a link, and the repo's file modes do not change
  # Work on a copy of the repo, so the test never changes the real repo's files.
  local repo="$test_tmp/repo-copy" mode
  mkdir -p "$repo" && cp -R "$REPO_DIR/install.sh" "$REPO_DIR/template" "$REPO_DIR/locale" "$REPO_DIR/launchd" "$repo/"
  chmod a-x "$repo/template/.tarokaja/prep.sh"
  mode="$(stat -f '%Lp' "$repo/template/.tarokaja/prep.sh")"
  /bin/bash "$repo/install.sh" "$VAULT" --link >/dev/null
  /bin/bash "$repo/install.sh" "$VAULT" --link >/dev/null
  [ "$(stat -f '%Lp' "$repo/template/.tarokaja/prep.sh")" = "$mode" ]
  [ -L "$VAULT/.tarokaja/work.sh" ]
  if [ -e "$VAULT/.tarokaja/work.sh.bak" ]; then return 1; fi
}

test_stream_error_result() {
  # A result event without text (an error such as error_max_turns) still gives the manager a reason
  printf '#!/bin/bash\necho '"'"'{"type":"result","subtype":"error_max_turns","is_error":true}'"'"'\n' > "$HOME/.local/bin/claude"
  chmod +x "$HOME/.local/bin/claude"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  grep -q 'error_max_turns' "$VAULT/.tarokaja/logs/T-001-last-work.txt"
  # No result event at all: the stderr tail is kept
  printf '#!/bin/bash\necho "auth failed" >&2\nexit 1\n' > "$HOME/.local/bin/claude"
  rm -f "$VAULT/.tarokaja/logs/T-001.last-work"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001 || true
  grep -q 'auth failed' "$VAULT/.tarokaja/logs/T-001-last-work.txt"
}

# ---------------------------------------------------------------------------
# 6. Add-on tests (Specs A-E)
# ---------------------------------------------------------------------------

test_a_addon_mechanism() {
  grep -q '^ADDONS=$' "$VAULT/.tarokaja/config"
  ( . "$VAULT/.tarokaja/lib.sh"; type emit >/dev/null 2>&1 )

  local fake_log="$VAULT/.tarokaja/logs/fake-events.log"
  mkdir -p "$VAULT/.tarokaja/addons/fake"
  cat > "$VAULT/.tarokaja/addons/fake/on_event" <<EOF
#!/bin/bash
echo "\$1 \$2 \$3" >> "$fake_log"
EOF
  chmod +x "$VAULT/.tarokaja/addons/fake/on_event"

  # With ADDONS empty nothing is called
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  if [ -s "$fake_log" ]; then return 1; fi

  # With ADDONS=fake: work.sh emits session_start T-001 bg then session_end T-001 bg
  sed -i '' 's/^ADDONS=.*/ADDONS=fake/' "$VAULT/.tarokaja/config"
  : > "$fake_log"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  [ "$(sed -n '1p' "$fake_log")" = "session_start T-001 bg" ]
  [ "$(tail -n 1 "$fake_log")" = "session_end T-001 bg" ]

  # tick.sh (TK_HOUR=22 so no work starts) emits tick - -
  : > "$fake_log"
  TK_HOUR=22 /bin/bash "$VAULT/.tarokaja/tick.sh"
  [ "$(cat "$fake_log")" = "tick - -" ]

  # meeting.sh emits meeting_start ID <pid> before the agent and meeting_end ID <pid> after it exits
  : > "$fake_log"
  /bin/bash "$VAULT/.tarokaja/meeting.sh" T-001
  local m_start m_end m_pid
  m_start="$(sed -n '1p' "$fake_log")"
  m_end="$(sed -n '2p' "$fake_log")"
  m_pid="${m_start#meeting_start T-001 }"
  [ -n "$m_pid" ]
  case "$m_pid" in *[!0-9]*) return 1 ;; esac
  [ "$m_start" = "meeting_start T-001 $m_pid" ]
  [ "$m_end" = "meeting_end T-001 $m_pid" ]

  # An on_event that exits 1 (or a missing add-on) does not make work.sh fail
  sed -i '' 's/^ADDONS=.*/ADDONS=missing,fake/' "$VAULT/.tarokaja/config"
  printf '#!/bin/bash\nexit 1\n' > "$VAULT/.tarokaja/addons/fake/on_event"
  chmod +x "$VAULT/.tarokaja/addons/fake/on_event"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
}

test_b_install_addons() {
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog,session >/dev/null
  grep -q '^ADDONS=timelog,session$' "$VAULT/.tarokaja/config"

  [ -d "$VAULT/.tarokaja/addons/timelog" ]
  [ -x "$VAULT/.tarokaja/addons/timelog/on_event" ]
  [ -f "$VAULT/.tarokaja/addons/timelog/timelog.py" ]
  [ -d "$VAULT/.tarokaja/addons/session" ]
  [ -f "$VAULT/.tarokaja/addons/session/hook.py" ]
  [ -f "$VAULT/.tarokaja/addons/session/install.py" ]

  # session install.py adds hook to VAULT/.claude/settings.json (never ~/.claude)
  [ -f "$VAULT/.claude/settings.json" ]
  grep -q 'hook.py' "$VAULT/.claude/settings.json"
  if [ -e "$HOME/.claude/settings.json" ]; then return 1; fi

  # Reinstall without --addons keeps ADDONS
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" >/dev/null
  grep -q '^ADDONS=timelog,session$' "$VAULT/.tarokaja/config"

  # With --link, the addons folder is a symlink into the repo
  local v_link="$VAULT-link"
  /bin/bash "$REPO_DIR/install.sh" "$v_link" --link --addons timelog,session >/dev/null
  [ -L "$v_link/.tarokaja/addons" ]
  case "$(readlink "$v_link/.tarokaja/addons")" in
    *"template/.tarokaja/addons") ;;
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
  ( unset TK_LANG H_TIME; . "$VAULT/.tarokaja/lib.sh"; [ "$(cfg H_TIME fallback)" = "## Time" ] )
  ( unset H_TIME; TK_LANG=zh-TW; . "$VAULT/.tarokaja/lib.sh"; [ "$(cfg H_TIME fallback)" = "## 時間" ] )

  python3 -I "$TESTS_DIR/test_c_timelog.py" "$VAULT"
}

test_d_session() {
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog,session >/dev/null
  python3 -I "$TESTS_DIR/test_d_session.py" "$VAULT"

  # T-001 has session: sess-0002-bbbb from test_d_session.py, but no transcript file yet -> no --resume
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/meeting.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep -q '^TK_TICKET: T-001$' "$STUB_AGENT_LOG"
  if grep -q '^ARG: --resume$' "$STUB_AGENT_LOG"; then return 1; fi

  # When ~/.claude/projects/*/<sid>.jsonl exists -> meeting.sh calls claude with --resume <sid>
  mkdir -p "$HOME/.claude/projects/vault-proj"
  : > "$HOME/.claude/projects/vault-proj/sess-0002-bbbb.jsonl"
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/meeting.sh" T-001
  grep -q '^TK_TICKET: T-001$' "$STUB_AGENT_LOG"
  grep -q '^ARG: --resume$' "$STUB_AGENT_LOG"
  grep -q '^ARG: sess-0002-bbbb$' "$STUB_AGENT_LOG"

  # When ticket has no session -> no --resume even if transcript files exist
  sed -i '' 's/^session: .*/session:/' "$VAULT/Tickets/T-001 Try Tarokaja.md"
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/meeting.sh" T-001
  grep -q '^TK_TICKET: T-001$' "$STUB_AGENT_LOG"
  if grep -q '^ARG: --resume$' "$STUB_AGENT_LOG"; then return 1; fi

  # Background sessions export TK_HEADLESS=1
  : > "$STUB_AGENT_LOG"
  /bin/bash "$VAULT/.tarokaja/work.sh" T-001
  grep -q '^TK_HEADLESS: 1$' "$STUB_AGENT_LOG"
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
  [ ! -e "$v/Tickets/T-001 試用 Tarokaja.md" ]
  [ "$(cat "$v/Tickets/T-001 Mine.md")" = "$before" ]
  [ -f "$v/.tarokaja/config" ]
  # A new vault still gets it
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-new" --lang zh-TW >/dev/null
  [ -f "$VAULT-new/Tickets/T-001 試用 Tarokaja.md" ]
}

test_install_rules_path() {
  # --rules puts the rules file in a folder and leaves the vault root alone
  local v="$VAULT-rules"
  /bin/bash "$REPO_DIR/install.sh" "$v" --lang zh-TW --rules "Tarokaja/AGENTS.md" >/dev/null
  [ -f "$v/Tarokaja/AGENTS.md" ]
  grep -q '^# Tarokaja 守則' "$v/Tarokaja/AGENTS.md"
  grep -q '^RULES_FILE=Tarokaja/AGENTS.md$' "$v/.tarokaja/config"
  [ ! -e "$v/AGENTS.md" ] && [ ! -e "$v/CLAUDE.md" ] && [ ! -e "$v/GEMINI.md" ]
  # A reinstall without --rules keeps the setting and still leaves the root alone
  /bin/bash "$REPO_DIR/install.sh" "$v" >/dev/null
  grep -q '^RULES_FILE=Tarokaja/AGENTS.md$' "$v/.tarokaja/config"
  [ ! -e "$v/AGENTS.md" ] && [ ! -e "$v/CLAUDE.md" ]
  # A root CLAUDE.md of the user stays
  printf 'mine\n' > "$v/CLAUDE.md"
  /bin/bash "$REPO_DIR/install.sh" "$v" >/dev/null
  [ "$(cat "$v/CLAUDE.md")" = mine ]
  # The work prompt names the rules file
  /bin/bash "$v/.tarokaja/work.sh" "T-001" >/dev/null 2>&1 || true
  grep -q 'Tarokaja/AGENTS.md' "$STUB_AGENT_LOG"
  # Bad paths exit 2
  local rc bad
  # --rules AGENTS.md switches back to the vault root
  /bin/bash "$REPO_DIR/install.sh" "$v" --rules AGENTS.md >/dev/null
  grep -q '^RULES_FILE=AGENTS.md$' "$v/.tarokaja/config"
  [ -f "$v/AGENTS.md" ]
  # A dangling symlink of the user at the root stays
  local v2="$VAULT-rules2"; mkdir -p "$v2"; ln -s /nonexistent "$v2/GEMINI.md"
  /bin/bash "$REPO_DIR/install.sh" "$v2" --rules "Tarokaja/AGENTS.md" >/dev/null
  [ -L "$v2/GEMINI.md" ]
  for bad in "../x.md" "/abs/x.md" "x.txt" "a|b.md" "" "a&b.md" 'a\b.md' "a/../b.md" "$(printf 'a\nb.md')"; do
    rc=0; /bin/bash "$REPO_DIR/install.sh" "$VAULT-badrules" --rules "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || return 1
  done
}

test_logs_ignored_in_own_gitignore() {
  # A vault with its own .gitignore still keeps logs out of git
  local v="$VAULT-gi"; mkdir -p "$v"; printf 'node_modules/\n' > "$v/.gitignore"
  /bin/bash "$REPO_DIR/install.sh" "$v" >/dev/null
  [ "$(cat "$v/.gitignore")" = "node_modules/" ]
  grep -qx 'logs/' "$v/.tarokaja/.gitignore"
}

test_install_lang_ja() {
  local v_ja="$VAULT-ja"
  /bin/bash "$REPO_DIR/install.sh" "$v_ja" --lang ja >/dev/null
  grep -q '^TK_LANG=ja$' "$v_ja/.tarokaja/config"

  [ -f "$v_ja/AGENTS.md" ]
  [ "$(sed -n '1p' "$v_ja/AGENTS.md")" = "# Tarokaja のルール" ]

  local t1="$v_ja/Tickets/T-001 Tarokaja を試す.md"
  [ -f "$t1" ]
  . "$v_ja/.tarokaja/lib.sh"
  [ "$(fm "$t1" id)" = "T-001" ]
  [ "$(fm "$t1" status)" = "doing" ]
  grep -q '^## 完了条件$' "$t1"
  grep -q '^## サブタスク$' "$t1"
  grep -q '^## Decisions$' "$t1"
  grep -q '^## 経過$' "$t1"
  grep -qE '^[[:space:]]*- \[ \] .*（agent）[[:space:]]*$' "$t1"

  [ -d "$v_ja/Office/会議" ]
  [ -d "$v_ja/Office/成果物" ]
  if [ -e "$v_ja/Office/meetings" ]; then return 1; fi
  if [ -e "$v_ja/Office/outputs" ]; then return 1; fi

  # Reinstall without --lang keeps TK_LANG=ja
  /bin/bash "$REPO_DIR/install.sh" "$v_ja" >/dev/null
  grep -q '^TK_LANG=ja$' "$v_ja/.tarokaja/config"

  # Unknown languages still exit 2
  local rc=0
  /bin/bash "$REPO_DIR/install.sh" "$VAULT-bad-ja" --lang invalid >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_ja_profile_and_cfg() {
  [ -f "$REPO_DIR/template/.tarokaja/profiles/ja.conf" ]
  [ -f "$VAULT/.tarokaja/profiles/ja.conf" ]

  if grep -q '^TK_LANG=' "$VAULT/.tarokaja/config"; then
    sed -i '' 's/^TK_LANG=.*/TK_LANG=ja/' "$VAULT/.tarokaja/config"
  else
    echo "TK_LANG=ja" >> "$VAULT/.tarokaja/config"
  fi
  unset TK_LANG H_DONE H_SUBTASKS H_DECISIONS H_CRUMBS H_TIME MARK CRUMB_STOP CRUMB_NEXT CRUMB_OPENED \
    MEETINGS_DIR OUTPUTS_DIR RULES_FILE SEC_WORK SEC_PREP SEC_MEETING SEC_TALK WRITE_LANG MEETINGS OUTPUTS
  . "$VAULT/.tarokaja/lib.sh"

  [ "$TK_LANG" = "ja" ]
  [ "$(cfg H_DONE fallback)" = "## 完了条件" ]
  [ "$(cfg H_SUBTASKS fallback)" = "## サブタスク" ]
  [ "$(cfg H_DECISIONS fallback)" = "## Decisions" ]
  [ "$(cfg H_CRUMBS fallback)" = "## 経過" ]
  [ "$(cfg MARK fallback)" = "（agent）" ]
  [ "$(cfg CRUMB_STOP fallback)" = "現状：" ]
  [ "$(cfg CRUMB_NEXT fallback)" = "次：" ]
  [ "$(cfg CRUMB_OPENED fallback)" = "起票。" ]
  [ "$(cfg MEETINGS_DIR fallback)" = "Office/会議" ]
  [ "$(cfg OUTPUTS_DIR fallback)" = "Office/成果物" ]
  [ "$(cfg SEC_WORK fallback)" = "作業セッション" ]
  [ "$(cfg SEC_PREP fallback)" = "会議の準備" ]
  [ "$(cfg SEC_MEETING fallback)" = "会議中" ]
  [ "$(cfg SEC_TALK fallback)" = "マネージャーとの対話" ]
  [ "$(cfg H_TIME fallback)" = "## 時間" ]
  case "$(cfg WRITE_LANG fallback)" in
    *Japanese*) ;;
    *) return 1 ;;
  esac
  [ "$MEETINGS" = "Office/会議" ]
  [ "$OUTPUTS" = "Office/成果物" ]
}

test_work_ja_vault() {
  local v_ja="$VAULT-ja"
  /bin/bash "$REPO_DIR/install.sh" "$v_ja" --lang ja >/dev/null
  : > "$STUB_AGENT_LOG"
  /bin/bash "$v_ja/.tarokaja/work.sh" T-001
  grep -q '^CMD: claude$' "$STUB_AGENT_LOG"
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q '作業セッション'
  grep '^ARG: ' "$STUB_AGENT_LOG" | grep -q 'Office/成果物/T-001/'
}

test_tui_ja_profile() {
  if grep -q '^TK_LANG=' "$VAULT/.tarokaja/config"; then
    sed -i '' 's/^TK_LANG=.*/TK_LANG=ja/' "$VAULT/.tarokaja/config"
  else
    echo "TK_LANG=ja" >> "$VAULT/.tarokaja/config"
  fi
  rm -f "$VAULT/Tickets/T-001 Try Tarokaja.md" "$VAULT/Tickets/T-002 Second task.md"
  python3 -I "$TESTS_DIR/test_tui_ja.py" "$VAULT"

  local out_ja
  out_ja="$(cd "$VAULT" && python3 -I .tarokaja/tui.py --print)"
  printf '%s\n' "$out_ja" | grep -q '要対応'
  printf '%s\n' "$out_ja" | grep -q '未完了'
  printf '%s\n' "$out_ja" | grep -q 'T-001'
  printf '%s\n' "$out_ja" | grep -q 'T-002'
}

test_timelog_ja() {
  local v_ja="$VAULT-ja-tl"
  /bin/bash "$REPO_DIR/install.sh" "$v_ja" --lang ja --addons timelog >/dev/null
  grep -q '^TK_LANG=ja$' "$v_ja/.tarokaja/config"
  grep -q '^ADDONS=timelog$' "$v_ja/.tarokaja/config"

  python3 -I - "$v_ja" <<'PY'
import datetime as dt
import os
import subprocess
import sys

vault = sys.argv[1]
timelog_py = os.path.join(vault, ".tarokaja", "addons", "timelog", "timelog.py")
day_str = "2026-11-11"
t0 = int(dt.datetime(2026, 11, 11, 10, 0, 0).timestamp())
now = int(dt.datetime(2026, 11, 11, 14, 0, 0).timestamp())

for args in [
    ["add", "T-001", "seat_start", "s1", "--at", str(t0)],
    ["add", "T-001", "seat_end", "s1", "--at", str(t0 + 600)],
    ["add", "T-001", "agent_start", "bg", "--at", str(t0)],
    ["add", "T-001", "agent_end", "bg", "--at", str(t0 + 1200)],
]:
    r = subprocess.run([sys.executable, "-I", timelog_py] + args, cwd=vault)
    assert r.returncode == 0

daily_path = os.path.join(vault, "Daily", f"{day_str}.md")
os.makedirs(os.path.dirname(daily_path), exist_ok=True)
with open(daily_path, "w", encoding="utf-8") as fh:
    fh.write(f"# {day_str}\n")

r = subprocess.run([sys.executable, "-I", timelog_py, "sync", "--now", str(now)], cwd=vault)
assert r.returncode == 0

with open(daily_path, encoding="utf-8") as fh:
    daily_ja = fh.read()

lines = daily_ja.splitlines()
assert "## 時間" in lines, f"Missing ## 時間 in:\n{daily_ja}"
assert "| チケット | 自分（分） | agent（分） |" in lines, f"Missing ja table header in:\n{daily_ja}"
assert any(ln.startswith("| 合計 |") for ln in lines), f"Missing '| 合計 |' total row in:\n{daily_ja}"
PY
}

test_week_report_titles() {
  # The week report has a title row, says when there is no time, and lines up wide (CJK) titles
  /bin/bash "$REPO_DIR/install.sh" "$VAULT" --addons timelog >/dev/null
  local tl="$VAULT/.tarokaja/addons/timelog/timelog.py" out
  out="$(cd "$VAULT" && python3 -I "$tl" week)"
  [ "$(printf '%s\n' "$out" | sed -n 2p | tr -s ' ')" = "Ticket (minutes) Me Agent" ]
  printf '%s\n' "$out" | grep -qx 'No time this week.'
  printf -- '---\nid: T-009\nstatus: doing\n---\n# x\n' > "$VAULT/Tickets/T-009 日本語のタイトル.md"
  local now; now="$(date +%s)"
  python3 -I "$tl" add T-009 seat_start s --at $((now - 600))
  python3 -I "$tl" add T-009 seat_end s --at $((now - 60))
  sed -i '' 's/^TK_LANG=.*/TK_LANG=ja/' "$VAULT/.tarokaja/config"
  out="$(cd "$VAULT" && python3 -I "$tl" week)"
  printf '%s\n' "$out" | grep -q '日本語のタイトル'
  # Every line after the first has the same screen width, so the number columns line up
  printf '%s\n' "$out" | python3 -I -c 'import sys, unicodedata
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
rows = sys.stdin.read().splitlines()[1:]
assert len({w(r) for r in rows}) == 1, rows'
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
run_test "logs stay out of git in a vault with its own .gitignore" test_logs_ignored_in_own_gitignore
run_test "work.sh claude stream-json output and result extraction" test_work_claude_stream_json
run_test "tui.py with TK_LANG=zh-TW and --print" test_tui_zh_profile
run_test "A: add-on mechanism and core events" test_a_addon_mechanism
run_test "B: install.sh --addons flag, link, and session hook" test_b_install_addons
run_test "C: timelog add-on events, sync, Daily table, status history, and week" test_c_timelog
run_test "D: session add-on hook, install.py, meeting resume, and headless" test_d_session
run_test "E: tui.py week_report_lines with timelog on and off" test_e_tui_week_report
run_test "install.sh --lang ja layout, rules, ticket, and folders" test_install_lang_ja
run_test "ja profile and lib.sh cfg values" test_ja_profile_and_cfg
run_test "work.sh T-001 in a ja vault" test_work_ja_vault
run_test "tui.py with TK_LANG=ja and --print" test_tui_ja_profile
run_test "timelog add-on with TK_LANG=ja Daily table" test_timelog_ja
run_test "week report title row, empty week, and CJK alignment" test_week_report_titles

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
