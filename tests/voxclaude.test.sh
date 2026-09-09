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
  "record start") exit "$VOXTYPE_START_EXIT" ;;
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
  "clients -j") [[ ${HYPR_NO_WINDOWS:-} == 1 ]] && echo "[]" || echo "[{\"address\":\"0xabc\",\"pid\":${HYPR_WINDOW_PID:-0},\"class\":\"org.omarchy.agent\",\"title\":\"work\"}]" ;;
  "activewindow -j") echo "{\"address\":\"${HYPR_ACTIVE:-0xother}\"}" ;;
esac'

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
check "session record carries prompt, uuid and status" bash -c "jq -e '.shortId == \"abcd1234\" and .prompt == \"create hello.txt with hi\" and .status == \"thinking\" and .sessionId == \"abcd1234-0000-4000-8000-000000000000\" and (.startedAt > 0)' '$RT/sessions/abcd1234.json' >/dev/null"
check "headless sets status thinking" test "$(status)" = thinking
check "headless toast names the prompt" called $'omarchy-notification-send\t.*create hello.txt'
check "headless tells Claude it was launched by voice" called -- '--append-system-prompt .*cannot see'
check "dispatch publishes the sessions feed" bash -c "jq -e 'length == 1 and .[0].shortId == \"abcd1234\" and .[0].step == \"\"' '$RT/sessions.json' >/dev/null"

# ---- dispatch: terminal ---------------------------------------------------
reset; VOXTYPE_TEXT="open a terminal and run the tests" "$script" stop
check "terminal word launches an interactive claude" called $'omarchy-launch-tui\t'"$HOME/Work"$'\t--app-id=org.omarchy.voxclaude claude --permission-mode auto -- open a terminal and run the tests'
check "terminal path starts no background session" not_called $'^claude\t'
check "terminal path returns to idle" test "$(status)" = idle

# ---- settings from shell.json ---------------------------------------------
cat > "$HOME/.config/omarchy/shell.json" <<JSON
{"bar":{"layout":{"right":[{"id":"io.github.nimbleaininja.voxclaude","cwd":"~/Proj","permissionMode":"acceptEdits","terminalWords":"terminal, shell","waitSeconds":25}]}}}
JSON
reset; VOXTYPE_TEXT="in a shell please" "$script" stop
check "extra trigger words route to the terminal" called $'omarchy-launch-tui\t'"$HOME/Proj"$'\t.*--permission-mode acceptEdits'
reset; "$script" start; : > "$LOG"; VOXTYPE_TEXT="plain task" "$script" stop
check "waitSeconds setting reaches voxtype" called $'record stop --wait --timeout 25'
check "cwd and permissionMode settings reach claude" called $'claude\t'"$HOME/Proj"$'\t--bg .*--permission-mode acceptEdits'
rm "$HOME/.config/omarchy/shell.json"

# ---- hooks ----------------------------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop; : > "$LOG"
echo '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$script" hook needs-input
check "needs-input attaches a terminal to the session" called $'omarchy-launch-or-focus-tui\t.*\t--app-id=org.omarchy.voxclaude.abcd1234 claude attach abcd1234'
check "needs-input marks the session" bash -c "jq -e '.status == \"needs-input\"' '$RT/sessions/abcd1234.json' >/dev/null"
check "needs-input sets the bar status" test "$(status)" = needs-input

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

# ---- forget -------------------------------------------------------------------
: > "$LOG"; "$script" forget abcd1234
check "forget removes the record" test ! -f "$RT/sessions/abcd1234.json"
check "forget removes the background session" called $'claude\t.*\trm abcd1234'
check "forget updates the feed" bash -c "jq -e 'length == 0' '$RT/sessions.json' >/dev/null"
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

# ---- recording states are not clobbered -------------------------------------------
reset; VOXTYPE_TEXT="do a thing" "$script" stop
"$script" start
check "recording sets listening" test "$(status)" = listening
printf '{"session_id":"abcd1234-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"noise"}}' | "$script" hook tool
check "another session's hook does not cancel listening" test "$(status)" = listening
VOXTYPE_STOP_EXIT=3 "$script" stop
check "nothing heard returns to idle" test "$(status)" = idle

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

# ---- list / attach --------------------------------------------------------
check "list --json prints the session records" bash -c "'$script' list --json | jq -e 'length == 1 and .[0].shortId == \"abcd1234\"' >/dev/null"
: > "$LOG"; "$script" attach latest
check "attach latest opens the newest session" called $'omarchy-launch-or-focus-tui\t.*claude attach abcd1234'
: > "$LOG"; "$script" attach abcd1234
check "attach by id opens that session" called 'claude attach abcd1234'

# ---- status -----------------------------------------------------------------
check "status prints idle when nothing is recorded" bash -c "rm -rf '$RT'; [[ \$('$script' status) == idle ]]"

echo
if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "voxclaude: all checks passed"
