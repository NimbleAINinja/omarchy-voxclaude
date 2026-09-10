#!/usr/bin/env bash
# Behavioural tests for bin/voxclaude with stubbed voxtype / claude / omarchy
# helpers on PATH. Every stub appends its argv (and cwd) to $LOG.
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$dir/bin/voxclaude"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export XDG_RUNTIME_DIR="$tmp/run"
export PATH="$tmp/bin:$PATH"
export LOG="$tmp/calls.log"
export VOXTYPE_STOP_EXIT=0
export VOXTYPE_START_EXIT=0
export VOXTYPE_TEXT="hello there"
mkdir -p "$HOME/.config/omarchy" "$HOME/.claude" "$XDG_RUNTIME_DIR" "$tmp/bin" "$HOME/Work" "$HOME/Proj"
echo '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$HOME/.claude/settings.json"
RT="$XDG_RUNTIME_DIR/voxclaude"

make_stub() {
  local name=$1 body=$2
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\t%%s\\n" "%s" "$PWD" "$*" >> "$LOG"\n%s\n' "$name" "$body" > "$tmp/bin/$name"
  chmod +x "$tmp/bin/$name"
}
make_stub voxtype '
case "$1 $2" in
  "record start") [[ -n ${JQ_COUNT:-} ]] && wc -l < "$JQ_COUNT" > "$JQ_COUNT.at-record-start"; exit "$VOXTYPE_START_EXIT" ;;
  "record stop") [[ $VOXTYPE_STOP_EXIT == 0 ]] && printf "%s\n" "$VOXTYPE_TEXT"; [[ $VOXTYPE_STOP_EXIT == 1 ]] && echo "daemon exploded" >&2; exit "$VOXTYPE_STOP_EXIT" ;;
esac'
make_stub claude '
case "$1" in
  wrap) shift; "$@" ;;
  -p) shift; [[ $1 == wrap ]] && { shift; "$@"; } ;;
  --bg) echo "Starting background service…"; echo "backgrounded · abcd1234 · voice"; echo "  claude attach abcd1234" ;;
  rm) ;;
  agents) echo "[{\"id\":\"abcd1234\",\"kind\":\"background\",\"sessionId\":\"abcd1234-0000-4000-8000-000000000000\",\"status\":\"busy\",\"pid\":${CLAUDE_STUB_PID:-0}},{\"id\":null,\"kind\":\"interactive\",\"sessionId\":\"ffff1234-0000-4000-8000-000000000000\",\"name\":\"work-1\",\"status\":\"busy\",\"pid\":$$}]" ;;
esac'
make_stub omarchy-notification-send ''
make_stub omarchy-launch-tui ''
make_stub omarchy-launch-or-focus-tui ''
make_stub xdg-open ''
make_stub hyprctl '
case "$1 $2" in
  "binds -j") echo "${HYPR_BINDS:-[]}" ;;
  "clients -j") [[ ${HYPR_NO_WINDOWS:-} == 1 ]] && echo "[]" || echo "[{\"address\":\"0xabc\",\"pid\":${HYPR_WINDOW_PID:-0},\"class\":\"org.omarchy.agent\",\"title\":\"work\"}]" ;;
  "activewindow -j") echo "{\"address\":\"${HYPR_ACTIVE:-0xother}\"}" ;;
esac'

# A counting jq for the cost checks; it lives on its own PATH entry so the
# rest of the suite runs against the real one.
mkdir -p "$tmp/countbin"
real_jq=$(command -v jq)
cat > "$tmp/countbin/jq" <<SH
#!/usr/bin/env bash
echo jq >> "\$JQ_COUNT"
exec $real_jq "\$@"
SH
chmod +x "$tmp/countbin/jq"
count_hook() { # <countfile> <payload>
  : > "$1"
  printf '%s' "$2" | JQ_COUNT="$1" PATH="$tmp/countbin:$PATH" "$script" hook tool || true
}

fails=0
check() { # check <name> <condition...>
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}
# Launches are forked off, so give the stub a moment to log itself.
called() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q -- "$1" "$LOG" && return 0; sleep 0.2; done; return 1; }
not_called() { sleep 0.3; ! grep -q -- "$1" "$LOG"; }
status() { cat "$RT/status" 2>/dev/null || echo "<none>"; }
reset() { rm -rf "$RT"; : > "$LOG"; }

# ---- start ------------------------------------------------------------
reset
"$script" start
check "start asks voxtype to record to the prompt file" called $'voxtype\t.*\trecord start --file='"$RT/prompt.txt"
check "start leaves a recording marker" test -f "$RT/recording"
check "start sets status listening" test "$(status)" = listening

reset; VOXTYPE_START_EXIT=1 "$script" start || true
check "start failure sets status error" test "$(status)" = error
check "start failure notifies" called $'omarchy-notification-send\t.*voxtype'
check "start failure leaves no marker" test ! -f "$RT/recording"

# ---- stop -------------------------------------------------------------
reset; "$script" start; : > "$LOG"
VOXTYPE_STOP_EXIT=3 "$script" stop
check "stop waits for the transcript" called $'voxtype\t.*\trecord stop --wait --timeout 60'
check "nothing heard -> idle" test "$(status)" = idle
check "nothing heard notifies" called $'omarchy-notification-send\t.*Nothing heard'
check "nothing heard launches nothing" not_called $'^claude\t'
check "stop removes the marker" test ! -f "$RT/recording"

reset; "$script" start; : > "$LOG"
VOXTYPE_STOP_EXIT=1 "$script" stop || true
check "transcription failure -> error" test "$(status)" = error
check "transcription failure notifies with stderr" called $'omarchy-notification-send\t.*daemon exploded'

reset; "$script" start; : > "$LOG"
"$script" start
check "start while recording acts as stop" called $'voxtype\t.*\trecord stop'

# ---- dispatch: headless -------------------------------------------------
reset; VOXTYPE_TEXT="create hello.txt with hi" "$script" stop
check "headless launches claude --bg in the default cwd" called $'claude\t'"$HOME/Work"$'\t--bg .*--permission-mode auto .*-- create hello.txt with hi'
check "headless passes the hooks settings file" called -- '--settings '"$RT/hooks.json"
check "hooks.json points Stop at this script" bash -c "jq -e --arg s \"$script hook stop\" '.hooks.Stop[0].hooks[0].command == \$s' '$RT/hooks.json' >/dev/null"
check "hooks.json ends sessions through this script" bash -c "jq -e --arg s \"$script hook end\" '.hooks.SessionEnd[0].hooks[0].command == \$s' '$RT/hooks.json' >/dev/null"
check "hooks.json watches the needs-input notifications" bash -c "jq -e '.hooks.Notification[0].matcher == \"permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog\"' '$RT/hooks.json' >/dev/null"
check "session record written under the short id" test -f "$RT/sessions/abcd1234.json"
check "session record carries prompt and status" bash -c "jq -e '.shortId == \"abcd1234\" and .prompt == \"create hello.txt with hi\" and .status == \"thinking\" and (.startedAt > 0)' '$RT/sessions/abcd1234.json' >/dev/null"
check "headless sets status thinking" test "$(status)" = thinking
check "headless toast names the prompt" called $'omarchy-notification-send\t.*create hello.txt'
check "headless tells Claude it was launched by voice" called -- '--append-system-prompt .*cannot see'
check "dispatch publishes the sessions feed" bash -c "jq -e 'length == 1 and .[0].shortId == \"abcd1234\" and .[0].step == \"\"' '$RT/sessions.json' >/dev/null"
check "a headless session is told nobody is watching" called '--append-system-prompt'

# ---- dispatch: terminal ---------------------------------------------------
# A terminal word opens a window on the session; the session itself still
# belongs to the Claude daemon, so closing that window cannot stop the work.
reset; VOXTYPE_TEXT="open a terminal and run the tests" "$script" stop
check "a terminal word still starts a background session" called $'^claude\t'"$HOME/Work"$'\t--bg'
check "a terminal word opens a window attached to that session" \
  called $'omarchy-launch-or-focus-tui\t.*--app-id=org.omarchy.voxclaude.abcd1234 claude attach abcd1234'
check "a terminal word never runs claude inside the window" not_called $'omarchy-launch-tui\t.*claude --permission-mode'
check "a watched session is not told the user cannot see it" not_called '--append-system-prompt'
check "a terminal request is tracked like any other" bash -c "jq -e '.status == \"thinking\" and .prompt == \"open a terminal and run the tests\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "a terminal request sets the bar working" test "$(status)" = thinking
check "a terminal request lets the window speak for itself" not_called 'Working on it'

# ---- settings from shell.json ---------------------------------------------
cat > "$HOME/.config/omarchy/shell.json" <<JSON
{"bar":{"layout":{"right":[{"id":"io.github.nimbleaininja.voxclaude","cwd":"~/Proj","permissionMode":"acceptEdits","terminalWords":"terminal, shell","waitSeconds":25}]}}}
JSON
reset; VOXTYPE_TEXT="in a shell please" "$script" stop
check "extra trigger words open a window on the session" called $'omarchy-launch-or-focus-tui\t.*claude attach abcd1234'
check "extra trigger words still honour the settings" called $'^claude\t'"$HOME/Proj"$'\t--bg.*--permission-mode acceptEdits'
reset; "$script" start; : > "$LOG"; VOXTYPE_TEXT="plain task" "$script" stop
check "waitSeconds setting reaches voxtype" called $'record stop --wait --timeout 25'
check "cwd and permissionMode settings reach claude" called $'claude\t'"$HOME/Proj"$'\t--bg .*--permission-mode acceptEdits'
# A field cleared in the settings UI arrives as "". Splitting on a whitespace
# separator folded it away and shifted every later setting into the wrong
# variable, which emptied the timeout and made voxtype reject every stop.
cat > "$HOME/.config/omarchy/shell.json" <<JSON
{"bar":{"layout":{"right":[{"id":"io.github.nimbleaininja.voxclaude","terminalWords":"","waitSeconds":25}]}}}
JSON
reset; "$script" start; : > "$LOG"; VOXTYPE_TEXT="open a terminal please" "$script" stop
check "a cleared setting does not shift the ones after it" called $'record stop --wait --timeout 25'
check "cleared trigger words simply never match" not_called 'claude attach'
cat > "$HOME/.config/omarchy/shell.json" <<JSON
{"bar":{"layout":{"right":[{"id":"io.github.nimbleaininja.voxclaude","cwd":"","permissionMode":""}]}}}
JSON
reset; VOXTYPE_TEXT="plain task" "$script" stop
check "a cleared setting falls back instead of poisoning the next one" called $'claude	'"$HOME"$'	--bg .*--permission-mode auto'
rm "$HOME/.config/omarchy/shell.json"

# The shipped default working directory need not exist on this machine.
cat > "$HOME/.config/omarchy/shell.json" <<JSON
{"bar":{"layout":{"right":[{"id":"io.github.nimbleaininja.voxclaude","cwd":"~/NoSuchPlace"}]}}}
JSON
reset; VOXTYPE_TEXT="plain task" "$script" stop
check "a working directory that is not there falls back to home" called $'claude	'"$HOME"$'	--bg '
check "a missing working directory still starts a session" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "a missing working directory is not reported as a failure" not_called 'Claude did not start'
rm "$HOME/.config/omarchy/shell.json"

# ---- hooks ----------------------------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop; : > "$LOG"
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input
check "needs-input attaches a terminal to the session" called $'omarchy-launch-or-focus-tui\t.*\t--app-id=org.omarchy.voxclaude.abcd1234 claude attach abcd1234'
check "needs-input marks the session" bash -c "jq -e '.status == \"needs-input\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "needs-input sets the bar status" test "$(status)" = needs-input
# Answering the prompt fires no hook of its own, but a tool call cannot run
# until it is answered, so the next one means the session is working again.
printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/x/App.jsx"}}' | "$script" hook tool
check "a tool call after you answer clears needs-input" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "the bar stops asking for you once the session works again" test "$(status)" = thinking
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input

: > "$LOG"
echo '{"session_id":"ffffffff-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input
check "unknown session is ignored" not_called omarchy-launch-or-focus-tui

: > "$LOG"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"I created   hello.txt\nwith the text hi."}' | "$script" hook stop
check "stop marks the session done with the reply" bash -c "jq -e '.status == \"done\" and .reply == \"I created hello.txt with the text hi.\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "stop returns the bar to idle" test "$(status)" = idle
check "stop toast carries the reply and attaches on click" called $'omarchy-notification-send\t.*I created hello.txt.*--exec omarchy-launch-tui --app-id=org.omarchy.voxclaude.abcd1234 claude attach abcd1234'
: > "$LOG"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"**Merged.** Run `npm test`, then see [the PR](https://github.com/x/y/pull/1).\n- one\n- two"}' | "$script" hook stop
check "stored reply is plain text" bash -c "jq -e '.reply == \"Merged. Run npm test, then see the PR. one two\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "toast shows plain text" called $'omarchy-notification-send\t.*Claude Merged. Run npm test, then see the PR. one two'
check "results still come from the raw reply" bash -c "jq -e '.results[0].value == \"https://github.com/x/y/pull/1\"' '$RT/sessions/abcd1234.json' >/dev/null"

# ---- session end ----------------------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input
: > "$LOG"
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"SessionEnd","reason":"other"}' | "$script" hook end
check "session end marks an unanswered session stopped" bash -c "jq -e '.status == \"stopped\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "session end returns the bar to idle" test "$(status)" = idle
check "session end is quiet" not_called omarchy-notification-send
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"all done"}' | "$script" hook stop
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"SessionEnd","reason":"other"}' | "$script" hook end
check "session end keeps a finished session done" bash -c "jq -e '.status == \"done\"' '$RT/sessions/abcd1234.json' >/dev/null"

# ---- progress ---------------------------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop; : > "$LOG"
tool() { printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2" | "$script" hook tool || true; }
step() { jq -r '.step' "$RT/sessions/abcd1234.json"; }
tool Bash '{"command":"npm install","description":"Install deps"}'
check "bash step uses the description" test "$(step)" = "Running: Install deps"
tool Bash '{"command":"npm run build && npm test"}'
check "bash step falls back to the command" test "$(step)" = "Running: npm run build && npm test"
tool Edit '{"file_path":"/home/x/Work/plants/src/App.jsx","old_string":"a","new_string":"b"}'
check "edit step names the file" test "$(step)" = "Editing App.jsx"
tool Write '{"file_path":"/home/x/Work/index.html","content":"x"}'
check "write step names the file" test "$(step)" = "Writing index.html"
tool Read '{"file_path":"/home/x/Work/README.md"}'
check "read step names the file" test "$(step)" = "Reading README.md"
tool Grep '{"pattern":"useState","path":"src"}'
check "grep step shows the pattern" test "$(step)" = "Searching for useState"
tool WebFetch '{"url":"https://docs.example.com/a/b","prompt":"x"}'
check "fetch step shows the host" test "$(step)" = "Fetching docs.example.com"
tool Agent '{"description":"Explore the repo","prompt":"..."}'
check "agent step shows the description" test "$(step)" = "Delegating: Explore the repo"
tool AskUserQuestion '{"questions":[]}'
check "question step" test "$(step)" = "Asking you a question"
tool Frobnicate '{"x":1}'
check "unknown tool step" test "$(step)" = "Using Frobnicate"
check "progress updates the feed" bash -c "jq -e '.[0].step == \"Using Frobnicate\" and (.[0].updatedAt > 0)' '$RT/sessions.json' >/dev/null"
check "progress is quiet" not_called omarchy-notification-send
printf '{"session_id":"ffffffff-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}' | "$script" hook tool || true
check "progress for unknown sessions is ignored" test ! -f "$RT/sessions/ffffffff.json"

# ---- resume after done ------------------------------------------------------
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"first pass done"}' | "$script" hook stop
check "stop marks done" bash -c "jq -e '.status == \"done\"' '$RT/sessions/abcd1234.json' >/dev/null"
tool Bash '{"command":"cat out.log","description":"Read background output"}'
check "a tool call after done marks the session busy again" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "resumed session sets the bar busy" test "$(status)" = thinking
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"second pass done"}' | "$script" hook stop
: > "$LOG"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"UserPromptSubmit","prompt":"keep going"}' | "$script" hook prompt || true
check "a new prompt after done marks the session busy again" bash -c "jq -e '.status == \"thinking\" and .step == \"\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "hooks.json routes UserPromptSubmit to this script" bash -c "jq -e --arg s \"$script hook prompt\" '.hooks.UserPromptSubmit[0].hooks[0].command == \$s' '$RT/hooks.json' >/dev/null"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"all done"}' | "$script" hook stop

# ---- background tasks keep a session waiting ---------------------------------
bash -c 'source /nonexistent/shell-snapshots/fake.sh 2>/dev/null; sleep 60; true' &
bgpid=$!
export CLAUDE_STUB_PID=$$
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"Waiting on the build."}' | "$script" hook stop
check "stop with a background task still running marks the session waiting" bash -c "jq -e '.status == \"waiting\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "waiting sets the bar status" test "$(status)" = waiting
check "waiting keeps the reply" bash -c "jq -e '.reply == \"Waiting on the build.\"' '$RT/sessions/abcd1234.json' >/dev/null"
tool Bash '{"command":"gh pr view","description":"Check the PR"}'
check "a tool call on a waiting session marks it busy" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"
kill "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null || true
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"Build passed, merged."}' | "$script" hook stop
check "stop with nothing running marks the session done" bash -c "jq -e '.status == \"done\"' '$RT/sessions/abcd1234.json' >/dev/null"
unset CLAUDE_STUB_PID

# ---- results ------------------------------------------------------------------
: > "$LOG"; mkdir -p "$HOME/Work/plants"; : > "$HOME/Work/plants/index.html"; : > "$HOME/notes.md"
printf '%s' "{\"session_id\":\"abcd1234-0000-4000-8000-000000000000\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Built it. Run npm run dev and open http://localhost:5173/ in a browser. The entry file is plants/index.html, notes are in $HOME/notes.md, and/or missing/file.txt is not there.\"}" | "$script" hook stop
check "stop extracts urls and existing paths as results" bash -c "jq -e '.results == [{kind:\"url\",value:\"http://localhost:5173/\"},{kind:\"path\",value:\"$HOME/Work/plants/index.html\"},{kind:\"path\",value:\"$HOME/notes.md\"}]' '$RT/sessions/abcd1234.json' >/dev/null"
check "stop records when it finished" bash -c "jq -e '.finishedAt > 0' '$RT/sessions/abcd1234.json' >/dev/null"
check "stop toast opens the first result on click" called $'omarchy-notification-send\t.*--exec xdg-open http://localhost:5173/$'
: > "$LOG"; "$script" open "http://localhost:5173/"
check "open hands a result to xdg-open" called $'xdg-open\t.*\thttp://localhost:5173/'

reset; VOXTYPE_TEXT="make a game" "$script" stop; : > "$HOME/Work/index.html"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"The game is in `index.html`. Open index.html in a browser; see also missing.html and README.md."}' | "$script" hook stop
check "bare filenames that exist in the cwd become results" bash -c "jq -e '.results == [{kind:\"path\",value:\"$HOME/Work/index.html\"}]' '$RT/sessions/abcd1234.json' >/dev/null"

# ---- pin --------------------------------------------------------------------
"$script" pin abcd1234 || true
check "pin marks the record pinned" bash -c "jq -e '.pinned == true' '$RT/sessions/abcd1234.json' >/dev/null"
check "pin updates the feed" bash -c "jq -e '.[0].pinned == true' '$RT/sessions.json' >/dev/null"
"$script" pin abcd1234 || true
check "pin toggles off again" bash -c "jq -e '.pinned == false' '$RT/sessions/abcd1234.json' >/dev/null"
"$script" pin abcd1234 || true
touch -d '2 days ago' "$RT/sessions/abcd1234.json"
"$script" start; VOXTYPE_STOP_EXIT=3 "$script" stop
check "prune keeps pinned records" test -f "$RT/sessions/abcd1234.json"
"$script" pin abcd1234 || true
touch -d '2 days ago' "$RT/sessions/abcd1234.json"
"$script" start; VOXTYPE_STOP_EXIT=3 "$script" stop
check "prune drops old unpinned records" test ! -f "$RT/sessions/abcd1234.json"
reset; VOXTYPE_TEXT="do a thing" "$script" stop
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"all done"}' | "$script" hook stop

# ---- forget hides a row, and does nothing else --------------------------------
: > "$LOG"; "$script" forget abcd1234
check "forget hides the row" bash -c "jq -e '.hidden == true' '$RT/sessions/abcd1234.json' >/dev/null"
check "forget keeps the record" test -f "$RT/sessions/abcd1234.json"
check "forget never deletes the claude session" not_called $'claude\t.*\trm abcd1234'
check "forget leaves the rest of the record alone" bash -c "jq -e '.prompt == \"do a thing\" and .status == \"done\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "forget updates the feed" bash -c "jq -e '.[0].hidden == true' '$RT/sessions.json' >/dev/null"
: > "$LOG"; "$script" attach latest >/dev/null 2>&1 || true
check "attach latest passes over a hidden row" not_called 'claude attach'
reset; VOXTYPE_TEXT="do a thing" "$script" stop
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"all done"}' | "$script" hook stop

# ---- global hooks: terminal sessions ------------------------------------------
reset
"$script" hooks install >/dev/null 2>&1 || true
settings=$HOME/.claude/settings.json
check "hooks install writes every event into user settings" bash -c "jq -e --arg s \"$script\" '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.PreToolUse, .hooks.Notification, .hooks.Stop, .hooks.SessionEnd] | all(any(.[]; .hooks[0].command | startswith(\$s)))' '$settings' >/dev/null"
check "hooks install keeps the needs-input matcher" bash -c "jq -e '.hooks.Notification[0].matcher == \"permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog\"' '$settings' >/dev/null"
check "hooks status reports installed" bash -c "'$script' hooks status | grep -q installed"
"$script" hooks install >/dev/null 2>&1 || true
check "hooks install is idempotent and keeps foreign hooks" bash -c "jq -e '(.hooks.Stop | length) == 2 and ([.hooks.Stop[].hooks[].command] | index(\"echo other\") != null)' '$settings' >/dev/null"
: > "$LOG"; VOXTYPE_TEXT="voice task" "$script" stop
check "dispatch skips its own hooks file once global hooks exist" not_called 'settings '"$RT"'/hooks.json'
check "voice record is tagged voice" bash -c "jq -e '.kind == \"voice\"' '$RT/sessions/abcd1234.json' >/dev/null"

export HYPR_WINDOW_PID=$$
printf '%s' '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"SessionStart","source":"startup","cwd":"'"$HOME/Proj"'"}' | "$script" hook start || true
check "session start creates a terminal record" bash -c "jq -e '.kind == \"terminal\" and .status == \"ready\" and .prompt == \"\" and .cwd == \"$HOME/Proj\" and .sessionId == \"ffff1234-0000-4000-8000-000000000000\"' '$RT/sessions/ffff1234.json' >/dev/null"
check "session start remembers the terminal window" bash -c "jq -e '.window.address == \"0xabc\" and .window.pid == $$' '$RT/sessions/ffff1234.json' >/dev/null"
check "a ready session does not change the bar status" test "$(status)" = thinking
printf '%s' '{"session_id":"eeee9999-0000-4000-8000-000000000000","hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}' | "$script" hook start || true
check "sessions unknown to claude agents are ignored" test ! -f "$RT/sessions/eeee9999.json"
# Fresh interactive sessions are not listed yet, but the hook runs under the
# claude process itself, so the ancestry tells us it is a terminal session.
printf '%s' "{\"session_id\":\"dddd5555-0000-4000-8000-000000000000\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$PWD\"}" | "$tmp/bin/claude" wrap "$script" hook start || true
check "an unlisted session under a claude process is a terminal session" bash -c "jq -e '.kind == \"terminal\" and .status == \"ready\" and .cwd == \"$PWD\"' '$RT/sessions/dddd5555.json' >/dev/null"
printf '%s' "{\"session_id\":\"cccc7777-0000-4000-8000-000000000000\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$PWD\"}" | "$tmp/bin/claude" -p wrap "$script" hook start || true
check "claude -p one-shots are ignored" test ! -f "$RT/sessions/cccc7777.json"
printf '%s' '{"session_id":"bbbb8888-0000-4000-8000-000000000000","hook_event_name":"SessionStart","source":"startup","cwd":"/somewhere/else"}' | "$tmp/bin/claude" wrap "$script" hook start || true
check "a claude ancestor running elsewhere is not this session" test ! -f "$RT/sessions/bbbb8888.json"
rm -f "$RT/sessions/dddd5555.json"

printf '%s' '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"UserPromptSubmit","prompt":"<task-notification><task-id>x</task-id> finished</task-notification>"}' | "$script" hook prompt || true
check "system-injected prompts never become the title" bash -c "jq -e '.prompt == \"\"' '$RT/sessions/ffff1234.json' >/dev/null"
printf '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/notes.md"}}' | "$script" hook tool || true
check "a tool call on a ready session marks it busy" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/ffff1234.json' >/dev/null"
printf '%s' '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"UserPromptSubmit","prompt":"fix the failing tests please"}' | "$script" hook prompt || true
check "first prompt becomes the row title" bash -c "jq -e '.prompt == \"fix the failing tests please\" and .status == \"thinking\"' '$RT/sessions/ffff1234.json' >/dev/null"
printf '%s' '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"UserPromptSubmit","prompt":"and then deploy"}' | "$script" hook prompt || true
check "later prompts keep the title" bash -c "jq -e '.prompt == \"fix the failing tests please\"' '$RT/sessions/ffff1234.json' >/dev/null"
printf '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/x/y/app.js"}}' | "$script" hook tool || true
check "terminal sessions get progress too" bash -c "jq -e '.step == \"Editing app.js\"' '$RT/sessions/ffff1234.json' >/dev/null"

: > "$LOG"; HYPR_ACTIVE=0xother
echo '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | HYPR_ACTIVE=0xother "$script" hook needs-input
check "needs-input on an unfocused terminal focuses its window" called $'hyprctl\t.*\tdispatch .*0xabc'
check "needs-input on an unfocused terminal toasts" called $'omarchy-notification-send\t.*Claude needs you'
check "needs-input on a terminal never opens a new window" not_called omarchy-launch
: > "$LOG"
echo '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | HYPR_ACTIVE=0xabc "$script" hook needs-input
check "needs-input on the focused terminal is quiet" not_called omarchy-notification-send

: > "$LOG"
printf '%s' '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"Tests fixed."}' | HYPR_ACTIVE=0xother "$script" hook stop
check "stop on an unfocused terminal toasts the reply with a focus action" called $'omarchy-notification-send\t.*Tests fixed.*--exec '"$script"' attach ffff1234'
: > "$LOG"
printf '%s' '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"Tests fixed."}' | HYPR_ACTIVE=0xabc "$script" hook stop
check "stop on the focused terminal is quiet" not_called omarchy-notification-send
check "stop on a terminal marks it done" bash -c "jq -e '.status == \"done\"' '$RT/sessions/ffff1234.json' >/dev/null"

: > "$LOG"; "$script" attach ffff1234
check "attach on a terminal session focuses its window" called $'hyprctl\t.*\tdispatch .*0xabc'
: > "$LOG"; HYPR_NO_WINDOWS=1 "$script" attach ffff1234
check "attach with the window gone resumes in a new terminal" called $'omarchy-launch-tui\t'"$HOME/Proj"$'\t--app-id=org.omarchy.voxclaude.ffff1234 claude --resume ffff1234-0000-4000-8000-000000000000'
"$script" hooks uninstall >/dev/null 2>&1 || true
check "hooks uninstall removes ours" bash -c "jq -e '(.hooks // {} | to_entries | map(.value[]?.hooks[]?.command | select(startswith(\"$script\"))) | length) == 0' '$settings' >/dev/null"
check "hooks uninstall keeps other settings" bash -c "jq -e '.theme == \"dark\"' '$settings' >/dev/null"
unset HYPR_WINDOW_PID; rm -f "$RT/sessions/ffff1234.json"
reset; VOXTYPE_TEXT="do a thing" "$script" stop
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"all done"}' | "$script" hook stop

# ---- concurrency and damaged state --------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
for round in 1 2 3; do
  for i in 1 2 3 4 5 6; do
    printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"step %d-%d"}}' "$round" "$i" | "$script" hook tool &
  done
  wait
done
check "concurrent hooks leave the record valid" bash -c "jq -e . '$RT/sessions/abcd1234.json' >/dev/null"
check "concurrent hooks leave the feed valid" bash -c "jq -e 'length == 1' '$RT/sessions.json' >/dev/null"
check "concurrent hooks leave no stray temp files" bash -c "! ls '$RT'/sessions/*.tmp* '$RT'/sessions.json.* >/dev/null 2>&1"
check "the bar status survives concurrent hooks" test "$(status)" = thinking

echo 'not json at all' > "$RT/sessions/9999aaaa.json"
check "an unreadable record does not break the listing" bash -c "'$script' list | jq -e 'length == 1' >/dev/null"
"$script" hook tool <<< '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/y.md"}}'
check "an unreadable record does not blank the bar status" test "$(status)" = thinking
printf 'garbage' > "$RT/sessions/abcd1234.json"
printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/y.md"}}' | "$script" hook tool || true
check "a damaged record is rebuilt rather than left broken" bash -c "jq -e . '$RT/sessions/abcd1234.json' >/dev/null"
rm -f "$RT/sessions/9999aaaa.json"
check "status falls back to idle when the status file is empty" bash -c ": > '$RT/status'; [[ \$('$script' status) == idle ]]"

# ---- awkward replies ------------------------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"Done. See https://example.com/foo\\_bar and \"quoted\" output."}' | "$script" hook stop
check "a reply with a backslash url still completes the session" bash -c "jq -e '.status == \"done\" and (.reply | length) > 0' '$RT/sessions/abcd1234.json' >/dev/null"
check "results stay valid json for an awkward reply" bash -c "jq -e '.results | type == \"array\"' '$RT/sessions/abcd1234.json' >/dev/null"

# ---- replies with nothing to point at ---------------------------------------------
# Voice sessions are asked to end with where the result is, and models answer
# that instruction even when there is nothing: "No file or URL for this one."
# is noise in a toast, so it is dropped whenever something is left to show.
reply_after() { # <last_assistant_message>
  reset >/dev/null
  VOXTYPE_TEXT="tell me a joke" "$script" stop >/dev/null 2>&1
  jq -n --arg m "$1" '{ session_id: "abcd1234-0000-4000-8000-000000000000",
                        hook_event_name: "Stop", last_assistant_message: $m }' \
    | "$script" hook stop
  jq -r '.reply' "$RT/sessions/abcd1234.json"
}

check "a trailing no-file-or-URL note is dropped" \
  test "$(reply_after 'Why did the cat sit on the computer? To keep an eye on the mouse. 🐱 No file or URL for this one.')" \
     = 'Why did the cat sit on the computer? To keep an eye on the mouse. 🐱'
check "the same note in its own sentence is dropped" \
  test "$(reply_after 'Signal is running now. There is no file or URL to open.')" = 'Signal is running now.'
check "the toast never carries the note" \
  bash -c "sleep 0.3; ! grep '^omarchy-notification-send' '\$LOG' | grep -qi 'no file or url'" 
check "a real result line is kept" \
  test "$(reply_after 'Wrote the notes to ~/Work/notes.md.')" = 'Wrote the notes to ~/Work/notes.md.'
check "a sentence that only starts with no is kept" \
  test "$(reply_after 'No file was found in the URL list, so I created config.yaml at ~/Work/config.yaml.')" \
     = 'No file was found in the URL list, so I created config.yaml at ~/Work/config.yaml.'
check "a reply that is nothing but the note still says something" \
  test "$(reply_after 'No file or URL for this one.')" = 'No file or URL for this one.'
# The note is only ever a bare absence with filler after it. An answer that
# happens to be negative says what happened, and must survive whole.
check "an answer that is itself a negative result is kept" \
  test "$(reply_after 'Searched the log. No results found for timeout.')" \
     = 'Searched the log. No results found for timeout.'
check "a negative answer about a path is kept" \
  test "$(reply_after 'Checked the config. No path is set for the cache.')" \
     = 'Checked the config. No path is set for the cache.'
check "a negative answer about files is kept" \
  test "$(reply_after 'Bumped the version. No files changed outside src.')" \
     = 'Bumped the version. No files changed outside src.'
check "a negative answer about output is kept" \
  test "$(reply_after 'The build is clean. No output was produced.')" = 'The build is clean. No output was produced.'
check "the note is still dropped when it is only filler" \
  test "$(reply_after 'Sorted. No output file this time.')" = 'Sorted.'
check "a nothing-to-open note is dropped too" \
  test "$(reply_after 'Done. Nothing to open here.')" = 'Done.'
# Replies arrive as markdown and are shown as prose, so a row and a toast read
# as a sentence rather than as source.
check "markdown in a reply becomes prose" \
  test "$(reply_after '## Done
- fixed **the** parser
See [the docs](https://example.com/x) and `a.txt`')" = 'Done fixed the parser See the docs and a.txt'
check "a fenced code block keeps its command, not its fence" \
  test "$(reply_after 'Run it yourself:
```bash
npm test
```
All green.')" = 'Run it yourself: npm test All green.'

# ---- recording states are not clobbered -------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
"$script" start
check "recording sets listening" test "$(status)" = listening
printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"noise"}}' | "$script" hook tool
check "another session's hook does not cancel listening" test "$(status)" = listening
VOXTYPE_STOP_EXIT=3 "$script" stop
check "nothing heard hands the bar back to the sessions" test "$(status)" = thinking
reset
VOXTYPE_STOP_EXIT=3 "$script" stop
check "nothing heard with no sessions is idle" test "$(status)" = idle

# A session waiting on the user must survive a press that hears nothing: the
# bar used to be forced to idle and the alert was lost until its next hook.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input
VOXTYPE_STOP_EXIT=3 "$script" stop
check "nothing heard does not erase a session waiting on you" test "$(status)" = needs-input

# voxtype gave up on its own: the marker goes, and so must the word, or
# apply_status preserves "listening" and no hook can move the bar again.
reset; "$script" start
mkdir -p "$XDG_RUNTIME_DIR/voxtype"; echo idle > "$XDG_RUNTIME_DIR/voxtype/state"
printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"x"}}' | "$script" hook tool
check "a recording voxtype has abandoned stops holding the bar" test "$(status)" != listening
rm -rf "$XDG_RUNTIME_DIR/voxtype"

# ---- an abandoned session stops holding the bar -----------------------------------
# Interrupting a turn fires neither Stop nor SessionEnd, so the record used to
# sit on "thinking" until the 24-hour prune and pinned the whole bar there.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
bash -c 'exit 0' & dead=$!; wait $dead 2>/dev/null
now=$(date +%s%3N)
jq --argjson pid "$dead" --argjson old "$((now - 200000))" \
  '.pid = $pid | .status = "thinking" | .updatedAt = $old' "$RT/sessions/abcd1234.json" > "$tmp/rec" \
  && mv "$tmp/rec" "$RT/sessions/abcd1234.json"
printf '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"elsewhere"}}' | "$script" hook tool || true
check "a session whose claude is gone is marked stopped" bash -c "jq -e '.status == \"stopped\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "an abandoned session keeps its prompt" bash -c "jq -e '.prompt == \"do a thing\"' '$RT/sessions/abcd1234.json' >/dev/null"
# With the session that did the reaping gone, the abandoned one is all that is
# left, and it must no longer hold the bar on "working".
rm -f "$RT/sessions/ffff1234.json"
"$script" pin abcd1234
check "an abandoned session stops holding the bar on working" test "$(status)" = idle

# Interrupting a turn leaves the process alive, so the pid says nothing: the
# record sat on "thinking" for as long as the terminal stayed open.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
now=$(date +%s%3N)
jq --argjson pid "$$" --argjson old "$((now - 1000000))" \
  '.pid = $pid | .status = "thinking" | .updatedAt = $old' "$RT/sessions/abcd1234.json" > "$tmp/rec" \
  && mv "$tmp/rec" "$RT/sessions/abcd1234.json"
printf '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"elsewhere"}}' | "$script" hook tool || true
check "an interrupted turn stops claiming to be working" bash -c "jq -e '.status == \"stopped\"' '$RT/sessions/abcd1234.json' >/dev/null"

# A session waiting on you may sit there for hours: it is not abandoned.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
now=$(date +%s%3N)
jq --argjson pid "$$" --argjson old "$((now - 1000000))" \
  '.pid = $pid | .status = "needs-input" | .updatedAt = $old' "$RT/sessions/abcd1234.json" > "$tmp/rec" \
  && mv "$tmp/rec" "$RT/sessions/abcd1234.json"
printf '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"elsewhere"}}' | "$script" hook tool || true
check "a long wait on you is never reaped" bash -c "jq -e '.status == \"needs-input\"' '$RT/sessions/abcd1234.json' >/dev/null"

# A live session must never be reaped, however quiet it has been.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
now=$(date +%s%3N)
jq --argjson pid "$$" --argjson old "$((now - 200000))" \
  '.pid = $pid | .status = "thinking" | .updatedAt = $old' "$RT/sessions/abcd1234.json" > "$tmp/rec" \
  && mv "$tmp/rec" "$RT/sessions/abcd1234.json"
printf '{"session_id":"ffff1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"elsewhere"}}' | "$script" hook tool || true
check "a quiet session with a live claude is left alone" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"

# A dead pid on a record that is still being updated is a stale pid, not a
# dead session: reaping on that alone flip-flopped every row it touched.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
bash -c 'exit 0' & dead=$!; wait $dead 2>/dev/null
jq --argjson pid "$dead" '.pid = $pid' "$RT/sessions/abcd1234.json" > "$tmp/rec" && mv "$tmp/rec" "$RT/sessions/abcd1234.json"
printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/a.md"}}' | "$script" hook tool || true
check "a fresh record with a stale pid keeps working" bash -c "jq -e '.status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"

# ---- hooks install on a broken settings file --------------------------------------
cp "$HOME/.claude/settings.json" "$tmp/settings.good"
printf '%s' '{ "theme": "dark", }' > "$HOME/.claude/settings.json"
check "hooks install fails loudly on unparseable settings" bash -c "! '$script' hooks install >/dev/null 2>&1"
check "hooks install leaves the broken file alone" bash -c "grep -q 'theme' '$HOME/.claude/settings.json'"
check "hooks install leaves no stray temp file" test ! -f "$HOME/.claude/settings.json.tmp"
check "hooks uninstall fails loudly too" bash -c "! '$script' hooks uninstall >/dev/null 2>&1"
cp "$tmp/settings.good" "$HOME/.claude/settings.json"

reset; VOXTYPE_TEXT="do a thing" "$script" stop
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"all done"}' | "$script" hook stop

# ---- a hook costs the same whatever the backlog ---------------------------------
# PreToolUse blocks the tool call, in every session on the machine, so its cost
# must not grow with the number of records lying around.
reset; VOXTYPE_TEXT="do a thing" "$script" stop
count_hook "$tmp/jq-one" '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/a.md"}}'
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  jq --arg s "extra0$i" '.shortId = $s | .startedAt = (.startedAt - 1000)' \
    "$RT/sessions/abcd1234.json" > "$RT/sessions/extra0$i.json"
done
count_hook "$tmp/jq-many" '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/b.md"}}'
check "a hook costs the same with 13 records as with one" \
  test "$(wc -l < "$tmp/jq-one")" = "$(wc -l < "$tmp/jq-many")"
check "a tool hook spends at most 4 jq calls" test "$(wc -l < "$tmp/jq-one")" -le 4
check "every record still reaches the feed" bash -c "jq -e 'length == 13' '$RT/sessions.json' >/dev/null"
rm -f "$RT"/sessions/extra0*.json
"$script" hook tool <<< '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/c.md"}}'
rm -f "$RT/sessions.json"
"$script" hook tool <<< '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/d.md"}}'
check "a missing feed still sets the bar status" test "$(status)" = thinking

# ---- the release path never waits on the session listing --------------------------
# claude --bg returns in about half a second and the session's own SessionStart
# hook fires half a second after that, under a process whose pid is the session.
reset; : > "$LOG"; VOXTYPE_TEXT="do a thing" "$script" stop
check "dispatch never asks claude for the session list" not_called $'claude\t.*\tagents'
check "dispatch records the session before its uuid is known" bash -c "jq -e '.shortId == \"abcd1234\" and .status == \"thinking\"' '$RT/sessions/abcd1234.json' >/dev/null"
: > "$LOG"
printf '%s' "{\"session_id\":\"abcd1234-0000-4000-8000-000000000000\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$HOME/Work\"}" \
  | "$tmp/bin/claude" wrap bash -c "'$script' hook start; sleep 30" &
wrapper=$!
for i in 1 2 3 4 5 6 7 8 9 10; do jq -e '.pid > 0' "$RT/sessions/abcd1234.json" >/dev/null 2>&1 && break; sleep 0.2; done
check "session start fills in the uuid of a voice session" bash -c "jq -e '.sessionId == \"abcd1234-0000-4000-8000-000000000000\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "session start remembers the pid of the process it runs under" bash -c "jq -e '.pid > 0 and (.pid | tostring | . as \$p | \"/proc/\" + \$p | test(\"^/proc/[0-9]+\$\"))' '$RT/sessions/abcd1234.json' >/dev/null && test -d /proc/\$(jq -r .pid '$RT/sessions/abcd1234.json')"
check "session start keeps the voice record's prompt and kind" bash -c "jq -e '.prompt == \"do a thing\" and .kind == \"voice\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "session start on a known session never asks claude for the list" not_called $'claude\t.*\tagents'
: > "$LOG"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Stop","last_assistant_message":"done"}' | "$script" hook stop
check "stop with a known pid never asks claude for the session list" not_called $'claude\t.*\tagents'
check "stop with a known pid still finishes the session" bash -c "jq -e '.status == \"done\"' '$RT/sessions/abcd1234.json' >/dev/null"
pkill -P "$wrapper" 2>/dev/null; kill "$wrapper" 2>/dev/null; wait "$wrapper" 2>/dev/null || true
: > "$tmp/jq-dispatch"
JQ_COUNT="$tmp/jq-dispatch" PATH="$tmp/countbin:$PATH" "$script" dispatch "budget check" >/dev/null 2>&1 || true
check "dispatch reads all its settings in one pass (at most 6 jq calls)" test "$(wc -l < "$tmp/jq-dispatch")" -le 6

# ---- the mic opens before any housekeeping -----------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
for i in $(seq 1 20); do
  jq --arg s "stale$i" '.shortId = $s' "$RT/sessions/abcd1234.json" > "$RT/sessions/stale$i.json"
  touch -d '2 days ago' "$RT/sessions/stale$i.json"
done
: > "$tmp/jq-start"
JQ_COUNT="$tmp/jq-start" PATH="$tmp/countbin:$PATH" "$script" start
check "the mic opens before any record is examined" test "$(cat "$tmp/jq-start.at-record-start" 2>/dev/null)" = 0
# One jq reads every stale record's pin, one rewrites the feed afterwards.
check "pruning 20 stale records costs two jq, not one per record" test "$(wc -l < "$tmp/jq-start")" -le 2
check "stale records are still pruned on the key" bash -c "! ls '$RT'/sessions/stale*.json >/dev/null 2>&1"
VOXTYPE_STOP_EXIT=3 "$script" stop

# ---- a hidden row stays hidden, but keeps working ----------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
"$script" forget abcd1234; : > "$LOG"
printf '%s' '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/y.md"}}' | "$script" hook tool || true
check "a hidden session stays hidden through its next hook" bash -c "jq -e '.hidden == true' '$RT/sessions/abcd1234.json' >/dev/null"
check "a hidden session keeps being tracked" bash -c "jq -e '.status == \"thinking\" and .step == \"Reading y.md\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "a hidden session's hooks never ask claude for the list" not_called $'claude\t.*\tagents'
# Hidden and blocked out of sight is worse than an unwanted row, so needs-input
# brings it back; visibleSessions is where that call lives.
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input
check "a hidden session still reports that it needs you" bash -c "jq -e '.status == \"needs-input\"' '$RT/sessions/abcd1234.json' >/dev/null"
reset; VOXTYPE_TEXT="do a thing" "$script" stop
jq '.shortId = "old00003"' "$RT/sessions/abcd1234.json" > "$RT/sessions/old00003.json"; : > "$RT/sessions/.old00003.lock"
touch -d '2 days ago' "$RT/sessions/old00003.json" "$RT/sessions/.old00003.lock"; rm -f "$RT/.pruned"
"$script" hook tool <<< '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/f.md"}}'
check "prune drops the lock file of a pruned record" test ! -f "$RT/sessions/.old00003.lock"

# ---- a session that cannot be placed is retried at most once a minute ------------
: > "$LOG"
for i in 1 2 3; do
  printf '%s' "{\"session_id\":\"deadbeef-0000-4000-8000-000000000000\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"x\"},\"cwd\":\"$HOME/Elsewhere\"}" | "$script" hook tool || true
done
check "an unplaceable session asks claude for the list once, not per tool call" test "$(grep -c 'agents' "$LOG")" = 1
check "an unplaceable session still gets no record" test ! -f "$RT/sessions/deadbeef.json"

# ---- sessions we never track cost nothing ----------------------------------------
: > "$LOG"
printf '%s' "{\"session_id\":\"aaaa1111-0000-4000-8000-000000000000\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$PWD\"}" \
  | "$tmp/bin/claude" -p wrap "$script" hook start || true
check "a one-shot session never asks claude for the session list" not_called 'agents'
check "a one-shot session is remembered as untracked" test -f "$RT/sessions/.ignore-aaaa1111"
: > "$LOG"
printf '%s' '{"session_id":"aaaa1111-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/y.md"}}' \
  | "$tmp/bin/claude" -p wrap "$script" hook tool || true
check "later hooks on an untracked session do no work" not_called 'agents'
check "an untracked session still gets no record" test ! -f "$RT/sessions/aaaa1111.json"

# ---- records are pruned without waiting for the next hold -------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
jq '.shortId = "old00001"' "$RT/sessions/abcd1234.json" > "$RT/sessions/old00001.json"
jq '.shortId = "old00002" | .pinned = true' "$RT/sessions/abcd1234.json" > "$RT/sessions/old00002.json"
touch -d '2 days ago' "$RT/sessions/old00001.json" "$RT/sessions/old00002.json"
rm -f "$RT/.pruned"
"$script" hook tool <<< '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/e.md"}}'
check "hooks drop day-old records without waiting for the key" test ! -f "$RT/sessions/old00001.json"
check "hooks keep pinned records" test -f "$RT/sessions/old00002.json"
check "hooks keep current records" test -f "$RT/sessions/abcd1234.json"
rm -f "$RT/sessions/old00001.json" "$RT/sessions/old00002.json"

# ---- list / attach --------------------------------------------------------
check "list --json prints the session records" bash -c "'$script' list --json | jq -e 'length == 1 and .[0].shortId == \"abcd1234\"' >/dev/null"
: > "$LOG"; "$script" attach latest
check "attach latest opens the newest session" called $'omarchy-launch-or-focus-tui\t.*claude attach abcd1234'
: > "$LOG"; "$script" attach abcd1234
check "attach by id opens that session" called 'claude attach abcd1234'

# "latest" has to mean what the widget calls the top row, or right-clicking the
# bar attaches to a different session than the tooltip just named. The order is
# Model.sortSessions': needs-input first, then pinned, then newest.
mkrec() { # <shortId> <status> <startedAt> <pinned>
  jq -n --arg id "$1" --arg st "$2" --argjson at "$3" --argjson pin "$4" \
    '{shortId:$id, sessionId:($id + "-0000-4000-8000-000000000000"), prompt:"p", cwd:"/tmp",
      startedAt:$at, updatedAt:$at, finishedAt:0, status:$st, step:"", reply:"", results:[],
      pinned:$pin, hidden:false, kind:"voice", window:null, pid:0}' > "$RT/sessions/$1.json"
}
reset; mkdir -p "$RT/sessions"
mkrec newest00 done 900 false
mkrec pinned00 done 500 true
mkrec blocked0 needs-input 100 false
: > "$LOG"; "$script" attach latest
check "attach latest takes the session that needs you first" called 'claude attach blocked0'
rm -f "$RT/sessions/blocked0.json"
: > "$LOG"; "$script" attach latest
check "attach latest then takes a pinned row over a newer one" called 'claude attach pinned00'
rm -f "$RT/sessions/pinned00.json"
mkrec hidden00 done 950 false
jq '.hidden = true' "$RT/sessions/hidden00.json" > "$tmp/h" && mv "$tmp/h" "$RT/sessions/hidden00.json"
: > "$LOG"; "$script" attach latest
check "attach latest never lands on a row you hid" called 'claude attach newest00'
reset

# ---- keybind ----------------------------------------------------------------
# The widget's hint must name the key the user actually bound, not the one the
# README suggests. Hyprland answers directly when the bind carries the command;
# Omarchy's Lua config compiles binds to an opaque "__lua" dispatcher, so the
# config file is the fallback.
hypr_conf="$HOME/.config/hypr"
mkdir -p "$hypr_conf"
keybind() { HYPR_BINDS="${1:-[]}" "$script" keybind; }

exec_binds='[{"modmask":64,"key":"D","release":false,"dispatcher":"exec","arg":"'"$script"' start"},
             {"modmask":64,"key":"D","release":true,"dispatcher":"exec","arg":"'"$script"' stop"}]'
check "keybind reads the live bind from hyprland" test "$(keybind "$exec_binds")" = "Super+D"

mods_binds='[{"modmask":65,"key":"space","release":false,"dispatcher":"exec","arg":"'"$script"' start"}]'
check "keybind spells out every modifier" test "$(keybind "$mods_binds")" = "Super+Shift+Space"

release_only='[{"modmask":64,"key":"D","release":true,"dispatcher":"exec","arg":"'"$script"' stop"}]'
check "keybind ignores a bind that is not the press" test -z "$(keybind "$release_only")"

lua_binds='[{"modmask":72,"key":"K","release":false,"dispatcher":"__lua","arg":"80"}]'
cat > "$hypr_conf/bindings.lua" <<'LUA'
local voxclaude = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude"
o.bind("SUPER + ALT + K", "Talk to Claude (hold)", voxclaude .. " start")
o.bind("SUPER + ALT + K", "Talk to Claude (release)", voxclaude .. " stop", { release = true })
LUA
check "keybind reads the lua config when hyprland hides the command" \
  test "$(keybind "$lua_binds")" = "Super+Alt+K"
rm -f "$hypr_conf/bindings.lua"

cat > "$hypr_conf/bindings.conf" <<'CONF'
bind = SUPER SHIFT, F9, exec, ~/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude start
bindr = SUPER SHIFT, F9, exec, ~/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude stop
CONF
check "keybind reads a hyprland.conf-style bind too" test "$(keybind)" = "Super+Shift+F9"
rm -f "$hypr_conf/bindings.conf"

# A rebind that leaves the old line commented out used to win, because the
# first matching line was taken whatever it was.
cat > "$hypr_conf/bindings.lua" <<'LUA'
local voxclaude = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude"
-- o.bind("SUPER + D", "Talk to Claude (hold)", voxclaude .. " start")
o.bind("SUPER + SHIFT + D", "Talk to Claude (hold)", voxclaude .. " start")
o.bind("SUPER + SHIFT + D", "Talk to Claude (release)", voxclaude .. " stop", { release = true })
LUA
check "keybind ignores a commented-out bind" test "$(keybind "$lua_binds")" = "Super+Shift+D"

# Wrapped over lines, the first quoted string on the matching line was " start",
# so the widget told the user to hold a key called "Start".
cat > "$hypr_conf/bindings.lua" <<'LUA'
local voxclaude = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude"
o.bind("SUPER + SHIFT + D", "Talk to Claude (hold)",
       voxclaude .. " start")
LUA
check "keybind reads a bind wrapped over lines" test "$(keybind "$lua_binds")" = "Super+Shift+D"

# The release bind may come first; only the press one names the hold key.
cat > "$hypr_conf/bindings.lua" <<'LUA'
local voxclaude = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude"
o.bind("SUPER + ALT + K", "Talk to Claude (release)", voxclaude .. " stop", { release = true })
o.bind("SUPER + ALT + K", "Talk to Claude (hold)", voxclaude .. " start")
LUA
check "keybind is not fooled by the release bind coming first" test "$(keybind "$lua_binds")" = "Super+Alt+K"
rm -f "$hypr_conf/bindings.lua"

# A stock hyprland.conf names its modifier through a variable, which used to be
# dropped, leaving the widget telling the user to hold "D" on its own.
cat > "$hypr_conf/bindings.conf" <<CONF
# bind = SUPER, X, exec, $script start
\$mainMod = SUPER
bind = \$mainMod, D, exec, $script start
bindr = \$mainMod, D, exec, $script stop
CONF
check "keybind expands a variable modifier" test "$(keybind)" = "Super+D"
rm -f "$hypr_conf/bindings.conf"

check "keybind says nothing when no key is bound" test -z "$(keybind)"

# ---- two hooks on one new session ---------------------------------------------
# Both bootstrap it, and they used to stage through the same "<short>.json.tmp",
# splicing a record that never parsed again and froze the whole feed.
reset
for i in 1 2 3 4 5 6; do
  printf '%s' "{\"session_id\":\"eeee9999-0000-4000-8000-000000000000\",\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$PWD\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x/a.md\"}}" \
    | "$tmp/bin/claude" wrap "$script" hook tool >/dev/null 2>&1 &
done
wait
check "racing hooks leave a record that still parses" bash -c "jq -e . '$RT/sessions/eeee9999.json' >/dev/null"
check "racing hooks leave no stray temp file" bash -c "! ls '$RT/sessions/'eeee9999.json.* >/dev/null 2>&1"
check "racing hooks leave a feed that still parses" bash -c "jq -e 'type == \"array\"' '$RT/sessions.json' >/dev/null"

# ---- uninstall ----------------------------------------------------------------
# The hooks name this script by absolute path, so they have to come out before
# the directory does, or every session on the machine runs a missing command.
reset
"$script" hooks install >/dev/null 2>&1 || true
jq '.hooks.PreToolUse += [{hooks:[{type:"command",command:"someone-elses-hook"}]}] | .theme = "dark"' \
  "$HOME/.claude/settings.json" > "$tmp/s" && mv "$tmp/s" "$HOME/.claude/settings.json"
VOXTYPE_TEXT="do a thing" "$script" stop
echo '{"bar":{"layout":{"right":[{"id":"io.github.nimbleaininja.voxclaude"},{"id":"other.widget"}]}}}' \
  > "$HOME/.config/omarchy/shell.json"
out=$("$script" uninstall 2>&1)
check "uninstall takes our hooks back out" bash -c "! jq -e --arg s '$script' '[(.hooks // {})[]?[]?.hooks[]?.command // \"\" | select(startswith(\$s))] | length > 0' '$HOME/.claude/settings.json' >/dev/null"
check "uninstall leaves other people's hooks alone" bash -c "jq -e '[(.hooks // {})[]?[]?.hooks[]?.command] | any(. == \"someone-elses-hook\")' '$HOME/.claude/settings.json' >/dev/null"
check "uninstall leaves the rest of the settings alone" bash -c "jq -e '.theme == \"dark\"' '$HOME/.claude/settings.json' >/dev/null"
check "uninstall clears the runtime state" test ! -d "$RT"
check "uninstall names the config files it will not touch" bash -c "grep -q 'yours to edit' <<< \"\$0\"" "$out"
check "uninstall says how to remove the plugin" bash -c "grep -q 'omarchy plugin remove io.github.nimbleaininja.voxclaude' <<< \"\$0\"" "$out"
check "uninstall points at the widget entry it will not touch" bash -c "grep -q 'shell.json' <<< \"\$0\"" "$out"
check "uninstall does not edit the widget entry itself" bash -c "grep -q 'io.github.nimbleaininja.voxclaude' '$HOME/.config/omarchy/shell.json'"
rm -f "$HOME/.config/omarchy/shell.json"
check "uninstall on a machine that never installed hooks is quiet" bash -c "'$script' uninstall 2>&1 | grep -q 'no hooks of ours'"

# ---- status -----------------------------------------------------------------
check "status prints idle when nothing is recorded" bash -c "rm -rf '$RT'; [[ \$('$script' status) == idle ]]"

echo
if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "voxclaude: all checks passed"
