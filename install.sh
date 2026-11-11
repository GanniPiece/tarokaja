#!/bin/bash
# install.sh VAULT_DIR [--agent claude|codex|agy|gemini] [--lang en|zh-TW|ja] [--addons timelog,session] [--rules PATH] [--link] [--schedule]
#
# Copies the Tarokaja template into VAULT_DIR. VAULT_DIR can be a new folder or an
# existing Obsidian vault. Files that exist already are never overwritten.
#   --agent     the agent CLI for all sessions (Default: claude)
#   --lang      the language profile en, zh-TW, or ja: ticket headings, markers, folders, rules (Default: en)
#   --addons    the add-ons to turn on, separated by "," (timelog, session). Writes ADDONS in config.
#               session adds Claude Code hooks to VAULT_DIR/.claude/settings.json.
#   --rules     where the agent rules go, relative to VAULT_DIR, such as "Tarokaja/AGENTS.md".
#               Writes RULES_FILE in config. The vault root then gets no AGENTS.md, CLAUDE.md, or GEMINI.md,
#               so your own agent sessions in the vault do not load the office rules. (Default: AGENTS.md)
#   --link      link the scripts to this repo instead of copying them, so the vault runs
#               the repo's code (for development). config and logs stay in the vault.
#   --schedule  install the launchd job that runs .tarokaja/tick.sh every 5 minutes
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

vault="" agent="" lang="" addons="" set_addons=0 rules="" set_rules=0 link=0 schedule=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) [ $# -ge 2 ] || { echo "--agent needs a value" >&2; exit 2; }; agent="$2"; shift 2 ;;
    --agent=*) agent="${1#--agent=}"; shift ;;
    --lang) [ $# -ge 2 ] || { echo "--lang needs a value" >&2; exit 2; }; lang="$2"; shift 2 ;;
    --lang=*) lang="${1#--lang=}"; shift ;;
    --addons) [ $# -ge 2 ] && [ -n "$2" ] || { echo "--addons needs a value" >&2; exit 2; }; addons="$2"; set_addons=1; shift 2 ;;
    --addons=*) addons="${1#--addons=}"; [ -n "$addons" ] || { echo "--addons needs a value" >&2; exit 2; }; set_addons=1; shift ;;
    --rules) [ $# -ge 2 ] || { echo "--rules needs a value" >&2; exit 2; }; rules="$2"; set_rules=1; shift 2 ;;
    --rules=*) rules="${1#--rules=}"; set_rules=1; shift ;;
    --link) link=1; shift ;;
    --schedule) schedule=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) vault="$1"; shift ;;
  esac
done
[ -n "$vault" ] || { echo "Usage: install.sh VAULT_DIR [--agent claude|codex|agy|gemini] [--lang en|zh-TW|ja] [--addons timelog,session] [--rules PATH] [--link] [--schedule]" >&2; exit 2; }
if [ "$set_rules" = 1 ]; then
  case "$rules" in
    ""|/*|../*|*/../*|*/..|*"|"*|*"&"*|*\\*|*[[:cntrl:]]*) echo "--rules needs a path inside the vault, such as \"Tarokaja/AGENTS.md\"" >&2; exit 2 ;;
    *.md) ;;
    *) echo "--rules needs a .md file" >&2; exit 2 ;;
  esac
fi
if [ "$set_addons" = 1 ]; then
  case "$addons" in *[!A-Za-z0-9_,-]*) echo "--addons takes names separated by \",\", such as timelog,session" >&2; exit 2 ;; esac
  for a in $(echo "$addons" | tr ',' ' '); do
    [ -d "$HERE/template/.tarokaja/addons/$a" ] || { echo "Unknown add-on: $a (use timelog, session)" >&2; exit 2; }
  done
fi
case "${lang:-en}" in en|zh-TW|ja) ;; *) echo "--lang must be en, zh-TW, or ja" >&2; exit 2 ;; esac
case "${agent:-claude}" in claude|codex|agy|gemini) ;; *) echo "--agent must be claude, codex, agy, or gemini" >&2; exit 2 ;; esac

ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }

echo "Checking tools"
if [ -d /Applications/cmux.app ] || command -v cmux >/dev/null 2>&1; then ok "cmux"; else warn "cmux not found. Get it from https://cmux.com. Without cmux, sessions open in the same terminal."; fi
if [ -d /Applications/Obsidian.app ]; then ok "Obsidian"; else warn "Obsidian not found. Get it from https://obsidian.md."; fi
if command -v "${agent:-claude}" >/dev/null 2>&1; then ok "${agent:-claude}"; else warn "${agent:-claude} not found in PATH. Install it before the first session."; fi
if command -v python3 >/dev/null 2>&1; then ok "python3 (for the TUI)"; else warn "python3 not found. Run: xcode-select --install"; fi

mkdir -p "$vault" || exit 1
vault="$(cd "$vault" && pwd)"
fresh=0
[ -f "$vault/.tarokaja/config" ] || fresh=1
echo "Installing into $vault"
# The language of a reinstall: --lang, else the one in config, else en.
if [ -z "$lang" ] && [ "$fresh" = 0 ]; then
  lang="$(sed -n 's/^TK_LANG=//p' "$vault/.tarokaja/config" | tail -n 1)"
fi
case "${lang:-en}" in en|zh-TW|ja) lang="${lang:-en}" ;; *) lang=en ;; esac
# The rules file: --rules, else RULES_FILE in config, else AGENTS.md at the vault root.
if [ "$set_rules" = 0 ] && [ "$fresh" = 0 ]; then
  rules="$(sed -n 's/^RULES_FILE=//p' "$vault/.tarokaja/config" | tail -n 1)"
fi
rules="${rules:-AGENTS.md}"
root_new=""   # root rules files that this install creates, removed again when the rules live elsewhere
for name in AGENTS.md CLAUDE.md GEMINI.md; do [ -e "$vault/$name" ] || [ -L "$vault/$name" ] || root_new="$root_new $name"; done
# cp -n: never overwrite a file that exists. The trailing /. copies dotfiles too.
cp -Rn "$HERE/template/." "$vault/" 2>/dev/null || true
# The example ticket goes only into a vault without tickets: an existing T-001 would get a second file.
example="$(cd "$HERE/locale/$lang/Tickets" && ls T-001\ *.md)"
skip_example=0
if ls "$vault/Tickets/"T-*.md >/dev/null 2>&1 && [ ! -e "$vault/Tickets/$example" ]; then skip_example=1; fi
cp -Rn "$HERE/locale/$lang/." "$vault/" 2>/dev/null || true
if [ "$rules" != AGENTS.md ] && [ -d "$vault/$rules" ]; then
  echo "--rules must name a file, not a folder: $rules" >&2; exit 2
fi
if [ "$rules" != AGENTS.md ] || [ "$set_rules" = 1 ]; then
  if [ "$rules" != AGENTS.md ]; then
    mkdir -p "$(dirname "$vault/$rules")"
    [ -e "$vault/$rules" ] || cp "$HERE/locale/$lang/AGENTS.md" "$vault/$rules"
    for name in $root_new; do rm -f "$vault/$name"; done
  fi
  if grep -q '^RULES_FILE=' "$vault/.tarokaja/config"; then
    sed -i '' "s|^RULES_FILE=.*|RULES_FILE=$rules|" "$vault/.tarokaja/config"
  else
    printf '\n# Agent rules file, relative to the vault\nRULES_FILE=%s\n' "$rules" >> "$vault/.tarokaja/config"
  fi
  ok "rules file: $rules"
fi
if [ "$skip_example" = 1 ]; then
  rm -f "$vault/Tickets/$example"
  ok "example ticket skipped: Tickets/ has tickets already"
fi
if grep -q '^TK_LANG=' "$vault/.tarokaja/config"; then
  sed -i '' "s/^TK_LANG=.*/TK_LANG=$lang/" "$vault/.tarokaja/config"
else
  printf '\n# Language profile: en, zh-TW, or ja\nTK_LANG=%s\n' "$lang" >> "$vault/.tarokaja/config"   # config from an older version
fi
ok "language profile: $lang"

if [ "$set_addons" = 1 ]; then
  if grep -q '^ADDONS=' "$vault/.tarokaja/config"; then
    sed -i '' "s/^ADDONS=.*/ADDONS=$addons/" "$vault/.tarokaja/config"
  else
    printf '\n# Add-ons, separated by ","\nADDONS=%s\n' "$addons" >> "$vault/.tarokaja/config"
  fi
fi
ok "add-ons: $(sed -n 's/^ADDONS=//p' "$vault/.tarokaja/config" | tail -n 1)"

if [ "$link" = 1 ]; then
  # Replace the scripts and profiles with links to this repo. config and logs stay in the vault.
  for name in lib.sh work.sh prep.sh meeting.sh tick.sh tui.py profiles addons; do
    dst="$vault/.tarokaja/$name"
    src="$HERE/template/.tarokaja/$name"
    if [ -L "$dst" ]; then rm -f "$dst"
    elif [ -e "$dst" ] && diff -rq "$dst" "$src" >/dev/null 2>&1; then rm -rf "$dst"   # same as the repo: no backup needed
    elif [ -e "$dst" ]; then rm -rf "$dst.bak"; mv "$dst" "$dst.bak"; fi
    ln -s "$src" "$dst"
  done
  ok "scripts linked to $HERE/template/.tarokaja"
fi
# chmod follows symlinks, so only change the modes of copied scripts, never the repo's files.
for f in "$vault/.tarokaja/"*.sh "$vault/.tarokaja/tui.py" "$vault/.tarokaja/addons/"*/on_event; do
  case "$f" in "$vault/.tarokaja/addons/"*) [ -L "$vault/.tarokaja/addons" ] && continue ;; esac
  [ -L "$f" ] || chmod +x "$f" 2>/dev/null
done
if [ "$set_addons" = 1 ]; then
  # The session add-on hooks live in the vault's project settings, never in ~/.claude.
  case ",$addons," in
    *,session,*)
      if python3 -I "$vault/.tarokaja/addons/session/install.py" "$vault"; then ok "session hooks in $vault/.claude/settings.json"
      else warn "could not add the session hooks to $vault/.claude/settings.json"; fi ;;
    *)
      if [ -f "$vault/.claude/settings.json" ] && ! python3 -I "$vault/.tarokaja/addons/session/install.py" "$vault" --remove; then
        warn "could not remove the session hooks from $vault/.claude/settings.json"
      fi ;;
  esac
fi

today="$(date +%F)"
t1="$vault/Tickets/$example"   # the example ticket of the language
if [ -f "$t1" ] && grep -q '^created: 2026-01-01$' "$t1"; then
  sed -i '' -e "s/^created: 2026-01-01$/created: $today/" -e "s/^updated: 2026-01-01$/updated: $today/" \
    -e "s/^- 2026-01-01 09:00 · /- $today $(date +%H:%M) · /" "$t1"
fi
# Set the agent on a fresh install, or when --agent is given. A reinstall keeps the user's config.
if [ "$fresh" = 1 ] || [ -n "$agent" ]; then
  sed -i '' "s/^AGENT_CLI=.*/AGENT_CLI=${agent:-claude}/" "$vault/.tarokaja/config"
fi
ok "agent CLI: $(sed -n 's/^AGENT_CLI=//p' "$vault/.tarokaja/config" | tail -n 1) (change it in .tarokaja/config)"

if [ "$schedule" = 1 ]; then
  # One job per vault: the label ends with a checksum of the vault path.
  label="local.tarokaja.tick.$(printf '%s' "$vault" | cksum | cut -d' ' -f1)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$vault/.tarokaja/logs"
  # Escape the path for XML first, then for the sed replacement (\\, & and the | delimiter).
  xml="$(printf '%s' "$vault" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  esc="$(printf '%s' "$xml" | sed -e 's/[\\&|]/\\&/g')"
  sed -e "s|__VAULT__|$esc|g" -e "s|__LABEL__|$label|g" "$HERE/launchd/tick.plist" > "$plist"
  plutil -lint "$plist" >/dev/null || { warn "invalid plist: $plist"; exit 1; }
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/local.agent-office.tick.${label##*.}" 2>/dev/null || true   # label before the rename to Tarokaja
  launchctl bootout "gui/$(id -u)/local.agent-office.tick" 2>/dev/null || true   # label of versions before 0.1
  if launchctl bootstrap "gui/$(id -u)" "$plist"; then
    ok "schedule: tick.sh every 5 minutes ($plist)"
  else
    warn "launchctl could not load $plist"
  fi
fi

cat <<EOF

Next:
  1. Open $vault as a vault in Obsidian.
  2. In cmux, open the folder:   cmux "$vault"
  3. Start the TUI:              python3 .tarokaja/tui.py
EOF
if [ "$skip_example" = 1 ]; then
  echo "  4. Open a ticket and delegate a subtask: end it with $( [ "$lang" = en ] && echo '(agent)' || echo '（agent）' )."
else
  echo "  4. Select T-001 and follow its subtasks."
fi
