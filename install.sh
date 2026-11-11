#!/bin/bash
# install.sh VAULT_DIR [--agent claude|codex|agy|gemini] [--lang en|zh-TW] [--link] [--schedule]
#
# Copies the Agent Office template into VAULT_DIR. VAULT_DIR can be a new folder or an
# existing Obsidian vault. Files that exist already are never overwritten.
#   --agent     the agent CLI for all sessions (Default: claude)
#   --lang      the language profile: ticket headings, markers, folders, rules (Default: en)
#   --link      link the scripts to this repo instead of copying them, so the vault runs
#               the repo's code (for development). config and logs stay in the vault.
#   --schedule  install the launchd job that runs .agent-office/tick.sh every 5 minutes
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

vault="" agent="" lang="" link=0 schedule=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) [ $# -ge 2 ] || { echo "--agent needs a value" >&2; exit 2; }; agent="$2"; shift 2 ;;
    --agent=*) agent="${1#--agent=}"; shift ;;
    --lang) [ $# -ge 2 ] || { echo "--lang needs a value" >&2; exit 2; }; lang="$2"; shift 2 ;;
    --lang=*) lang="${1#--lang=}"; shift ;;
    --link) link=1; shift ;;
    --schedule) schedule=1; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) vault="$1"; shift ;;
  esac
done
[ -n "$vault" ] || { echo "Usage: install.sh VAULT_DIR [--agent claude|codex|agy|gemini] [--lang en|zh-TW] [--link] [--schedule]" >&2; exit 2; }
case "${lang:-en}" in en|zh-TW) ;; *) echo "--lang must be en or zh-TW" >&2; exit 2 ;; esac
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
[ -f "$vault/.agent-office/config" ] || fresh=1
echo "Installing into $vault"
# The language of a reinstall: --lang, else the one in config, else en.
if [ -z "$lang" ] && [ "$fresh" = 0 ]; then
  lang="$(sed -n 's/^AO_LANG=//p' "$vault/.agent-office/config" | tail -n 1)"
fi
case "${lang:-en}" in en|zh-TW) lang="${lang:-en}" ;; *) lang=en ;; esac
# cp -n: never overwrite a file that exists. The trailing /. copies dotfiles too.
cp -Rn "$HERE/template/." "$vault/" 2>/dev/null || true
cp -Rn "$HERE/locale/$lang/." "$vault/" 2>/dev/null || true
if grep -q '^AO_LANG=' "$vault/.agent-office/config"; then
  sed -i '' "s/^AO_LANG=.*/AO_LANG=$lang/" "$vault/.agent-office/config"
else
  printf '\n# Language profile: en or zh-TW\nAO_LANG=%s\n' "$lang" >> "$vault/.agent-office/config"   # config from an older version
fi
ok "language profile: $lang"

if [ "$link" = 1 ]; then
  # Replace the scripts and profiles with links to this repo. config and logs stay in the vault.
  for name in lib.sh work.sh prep.sh meeting.sh tick.sh tui.py profiles; do
    dst="$vault/.agent-office/$name"
    src="$HERE/template/.agent-office/$name"
    if [ -L "$dst" ]; then rm -f "$dst"
    elif [ -e "$dst" ] && diff -rq "$dst" "$src" >/dev/null 2>&1; then rm -rf "$dst"   # same as the repo: no backup needed
    elif [ -e "$dst" ]; then rm -rf "$dst.bak"; mv "$dst" "$dst.bak"; fi
    ln -s "$src" "$dst"
  done
  ok "scripts linked to $HERE/template/.agent-office"
fi
# chmod follows symlinks, so only change the modes of copied scripts, never the repo's files.
for f in "$vault/.agent-office/"*.sh "$vault/.agent-office/tui.py"; do
  [ -L "$f" ] || chmod +x "$f"
done

today="$(date +%F)"
for t1 in "$vault/Tickets/T-001 "*.md; do :; done   # the example ticket of the language
if [ -f "$t1" ] && grep -q '^created: 2026-01-01$' "$t1"; then
  sed -i '' -e "s/^created: 2026-01-01$/created: $today/" -e "s/^updated: 2026-01-01$/updated: $today/" \
    -e "s/^- 2026-01-01 09:00 · /- $today $(date +%H:%M) · /" "$t1"
fi
# Set the agent on a fresh install, or when --agent is given. A reinstall keeps the user's config.
if [ "$fresh" = 1 ] || [ -n "$agent" ]; then
  sed -i '' "s/^AGENT_CLI=.*/AGENT_CLI=${agent:-claude}/" "$vault/.agent-office/config"
fi
ok "agent CLI: $(sed -n 's/^AGENT_CLI=//p' "$vault/.agent-office/config" | tail -n 1) (change it in .agent-office/config)"

if [ "$schedule" = 1 ]; then
  # One job per vault: the label ends with a checksum of the vault path.
  label="local.agent-office.tick.$(printf '%s' "$vault" | cksum | cut -d' ' -f1)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$vault/.agent-office/logs"
  # Escape the path for XML first, then for the sed replacement (\\, & and the | delimiter).
  xml="$(printf '%s' "$vault" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  esc="$(printf '%s' "$xml" | sed -e 's/[\\&|]/\\&/g')"
  sed -e "s|__VAULT__|$esc|g" -e "s|__LABEL__|$label|g" "$HERE/launchd/tick.plist" > "$plist"
  plutil -lint "$plist" >/dev/null || { warn "invalid plist: $plist"; exit 1; }
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
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
  3. Start the TUI:              python3 .agent-office/tui.py
  4. Select T-001 and follow its subtasks.
EOF
