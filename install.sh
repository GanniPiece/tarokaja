#!/bin/bash
# install.sh VAULT_DIR [--agent claude|codex|agy|gemini] [--schedule]
#
# Copies the Agent Office template into VAULT_DIR. VAULT_DIR can be a new folder or an
# existing Obsidian vault. Files that exist already are never overwritten.
#   --agent     the agent CLI for all sessions (Default: claude)
#   --schedule  install the launchd job that runs .agent-office/tick.sh every 5 minutes
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

vault="" agent="" schedule=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) [ $# -ge 2 ] || { echo "--agent needs a value" >&2; exit 2; }; agent="$2"; shift 2 ;;
    --agent=*) agent="${1#--agent=}"; shift ;;
    --schedule) schedule=1; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) vault="$1"; shift ;;
  esac
done
[ -n "$vault" ] || { echo "Usage: install.sh VAULT_DIR [--agent claude|codex|agy|gemini] [--schedule]" >&2; exit 2; }
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
# cp -n: never overwrite a file that exists. The trailing /. copies dotfiles too.
cp -Rn "$HERE/template/." "$vault/" 2>/dev/null || true
chmod +x "$vault/.agent-office/"*.sh "$vault/.agent-office/tui.py"

today="$(date +%F)"
t1="$vault/Tickets/T-001 Try Agent Office.md"
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
