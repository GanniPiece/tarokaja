# Record the README demo:  vhs docs/demo/demo.tape   (run from the repo root)
# The demo vault comes from make-vault.sh. docs/demo/bin/claude is a stand-in, so no real agent runs.
Output docs/demo/demo.gif

Set Shell "bash"
Set FontSize 15
Set Width 1300
Set Height 620
Set Padding 12
Set TypingSpeed 60ms
Set Theme "Catppuccin Mocha"

Hide
Type `export PATH="$PWD/docs/demo/bin:$PATH" V="${TMPDIR:-/tmp}/tarokaja-demo"; docs/demo/make-vault.sh "$V" >/dev/null && cd "$V" && clear`
Enter
Sleep 2s
Show

Type "python3 .tarokaja/tui.py"
Sleep 400ms
Enter
Sleep 2.5s

# T-001: the agent works on the subtasks marked (agent)
Sleep 1.5s
# T-002: the agent stopped and waits for a decision
Type "j"
Sleep 3s
# T-003: the agent finished and waits for review
Type "j"
Sleep 2.5s
# Back to T-001 and start a work session now
Type "k"
Sleep 400ms
Type "k"
Sleep 1.5s
Type "w"
Sleep 3s

# Keys
Type "?"
Sleep 3.5s
Type "?"
Sleep 500ms

# This week's time per ticket (timelog add-on)
Type "R"
Sleep 3.5s
Type "R"
Sleep 500ms

# Places: Needs me
Type "h"
Sleep 400ms
Type "k"
Sleep 2.5s
Type "q"
Sleep 800ms
