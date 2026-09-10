# VoxClaude

**Push to talk to Claude Code.** Hold a key, say what you want, let go. Claude
does it in the background while you keep working, and every session you start
stays one click away in the Omarchy bar.

<p align="center"><img src="preview.png" width="340" alt="The VoxClaude popover: two sessions working, one done with links to its results"></p>

Built for the [Omarchy](https://omarchy.org) shell on top of
[voxtype](https://github.com/peteonrails/voxtype) and the
[Claude Code](https://code.claude.com) CLI.

## Why

**Talking is faster than a terminal.** Most of what you ask Claude to do fits in
a sentence: "run the tests and fix whatever fails", "make the gallery lazy-load
its images", "write release notes for 2.3 from the merged PRs". With VoxClaude
that sentence is the whole interaction. Hold Super+D, say it, release. No
window to find, no prompt to type into, no context switch away from whatever
you were doing.

**Agents run in the background. Drop in whenever you like.** Every request
starts a real `claude --bg` session that belongs to the Claude daemon, not to a
window. You get a toast when it starts and a toast with the reply when it is
done, and in between the bar shows what Claude is doing right now: "Running:
npm test", "Editing Gallery.tsx". Want to watch, steer, or take over? Click the
row and a terminal opens attached to the live session. Close it again and the
work carries on. If Claude needs you, for a permission, a question, or a tool
that wants input, VoxClaude opens that terminal for you and says so. Say
"terminal" anywhere in your request and it opens the window from the start.

**Your recent sessions, in one place.** Left-click the bar icon for a list of
what Claude has been doing: the prompt, its status, how long it has been
running, the current step, and the reply once it is done, with clickable chips
for any file or URL the reply points at. Anything waiting on you sorts to the
top. Click a row to open it in a terminal, done or not, so you can follow up on
a finished task or pick up one that is still going. Pin the ones you want to
keep, hide the ones you don't. Install the optional hooks and sessions you
start yourself in a terminal show up here too, so the popover becomes the one
list of every Claude session on the machine.

## A session, start to finish

1. Hold Super+D. The bar critter blinks: it is listening.
2. Say what you want and release the key. voxtype transcribes it, Claude Code
   starts in the background in your working directory, and a toast says
   "Working on it".
3. The critter swings its arms while Claude works. Hover it for the prompt and
   the current step; open the popover for the full list.
4. If Claude needs you, the critter turns urgent, a toast says "Claude needs
   you", and a terminal opens on the session. Answer, then close the window or
   leave it open. The session does not care.
5. When Claude finishes, the critter blinks green three times and a toast shows
   the reply. Click the toast to open the result, or the conversation if there
   is nothing to open.

Voice sessions get a short appended system prompt telling Claude it was
started from a widget the user cannot see, so replies stay short and name
where the result is. That line is what feeds the chips.

## The popover

Each row shows the prompt, then a status dot and word, the elapsed time, and
the current step on its own line. Green means done; yellow means Claude is
working or waiting on a background command it started (a build, a dev server);
red means it needs you or something failed; grey means stopped. A finished
session that wakes up again, because a background task reported back or you
typed a follow-up after attaching, goes back to yellow. A small glyph on the
status line marks sessions started from a terminal apart from voice ones.

| Action | Effect |
|---|---|
| Left-click the bar icon | Open / close the popover |
| Hover the bar icon | Tooltip with the current prompt and step |
| Click a row, or `Enter` | Open the session in a terminal, done or not (voice: `claude attach`; terminal rows: focus their window, or resume if it is gone) |
| Click a chip | Open the file or URL in your default app |
| Hover a row and click the pin, or `p` | Keep the row near the top and exempt from the daily prune |
| Right-click a row, or `Delete` | Hide the row (the session keeps running) |
| Arrows | Move between rows |
| `r` | Refresh |

## Requirements

- Omarchy 4 shell with voxtype installed and its daemon running
  (`systemctl --user status voxtype`). voxtype ≥ 1.0 is needed for
  `record start --file` and `record stop --wait`.
- Claude Code CLI ≥ 2.1.260 (`claude --bg`, `claude attach`, session-scoped hooks).
- `jq`, `flock` and `setsid` (util-linux), `pgrep` (procps), `hyprctl`,
  `xdg-open`, and Omarchy's own `omarchy-notification-send` and
  `omarchy-launch-tui`. All ship with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/NimbleAINinja/omarchy-voxclaude.git --enable
```

That clones the plugin and adds the widget to the bar. (Without `--enable`, add
it later from Omarchy menu → Setup → Bar, or put
`{"id": "io.github.nimbleaininja.voxclaude"}` into a `bar.layout` section of
`~/.config/omarchy/shell.json`.)

Then bind the key in `~/.config/hypr/bindings.lua`. The plugin cannot install
binds for you:

```lua
-- Hold Super+D to talk to Claude (VoxClaude plugin). Release D before Super.
local voxclaude = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude"
o.bind("SUPER + D", "Talk to Claude (hold)", voxclaude .. " start")
o.bind("SUPER + D", "Talk to Claude (release)", voxclaude .. " stop", { release = true })
```

Terminals that VoxClaude opens on a session should float and centre, so they
never land as a tile hidden behind a floating (Super+T) or maximized window.
Add to `~/.config/hypr/hyprland.lua`:

```lua
-- VoxClaude: sessions opened from the bar float on top of whatever you are doing.
o.window("org\\.omarchy\\.voxclaude.*", { float = true })
o.window("org\\.omarchy\\.voxclaude.*", { center = true })
o.window("org\\.omarchy\\.voxclaude.*", { size = { 1260, 850 } })  -- pixels; percentages are ignored here
```

`hyprctl reload`, then hold Super+D, talk, release. Plain voxtype dictation on
its own key keeps typing into the focused window; VoxClaude never touches the
voxtype config.

Bind a different key and the widget follows: its hint names the key you
actually bound. Bind nothing and it asks you to, rather than naming a key that
does nothing. (`voxclaude keybind` is what resolves it, from `hyprctl binds`
when the bind carries its command and from the files in `~/.config/hypr` when
Omarchy's Lua config hides the command behind a `__lua` dispatcher. It runs
when the shell starts and whenever the popover opens, so `hyprctl reload` is
enough to update it.)

### Optional: track every Claude session, not only voice ones

```bash
~/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude hooks install
```

That merges VoxClaude's hooks into `~/.claude/settings.json` (a backup is kept
beside it; `hooks uninstall` removes only VoxClaude's entries, `hooks status`
says which). From then on every Claude Code session you start in a terminal
gets a row once you type something: the first prompt is the title, and the
status and step follow the session. Claude reloads its settings live, so
sessions already running pick the hooks up at their next tool call. `claude -p`
one-shots are ignored.

Terminal rows remember their window. Clicking one focuses it, or resumes the
conversation in a fresh floating terminal if the window is gone. Toasts for
these fire only when the window is not in front: "Claude needs you" (with the
window brought forward) and the reply when a turn finishes.

## Settings

Set on the widget's entry in `shell.json`, or from the bar settings UI:

| key | default | meaning |
|---|---|---|
| `cwd` | `~/Work` | Directory voice-launched Claude sessions start in |
| `permissionMode` | `auto` | `claude --permission-mode`; anything that would prompt opens a terminal instead |
| `terminalWords` | `terminal` | Comma-separated words that also open a terminal window on the session |
| `waitSeconds` | `60` | How long to wait for voxtype's transcript |

## How it works

```
Super+D down   voxclaude start     voxtype record start --file=$RT/prompt.txt
Super+D up     voxclaude stop      voxtype record stop --wait  →  transcript
                                   claude --bg --settings $RT/hooks.json -- "<text>"
                                   └─ said a terminal word → foot window: claude attach <shortId>
Claude hooks   SessionStart       → voxclaude hook start       → record + window for terminal sessions
               PreToolUse         → voxclaude hook tool        → progress line; done → busy again
               UserPromptSubmit   → voxclaude hook prompt      → new turn: done → busy again
               Notification (permission_prompt, agent_needs_input, elicitation_*)
                                   → voxclaude hook needs-input → terminal attached to the session
               Stop                → voxclaude hook stop        → reply, result chips, toast
               SessionEnd          → voxclaude hook end         → unanswered sessions marked stopped
```

`$RT` is `$XDG_RUNTIME_DIR/voxclaude`. It holds `status` (one word the widget
watches), `sessions/<shortId>.json` (one record per session), `sessions.json`
(all records, newest first, rewritten on every change and watched by the
widget), `hooks.json` (the session-scoped Claude hooks) and voxtype's
`prompt.txt`.

A `PreToolUse` hook blocks the tool call that fired it, in every session on
the machine, so the script keeps that path cheap: four `jq` calls per hook
whatever the backlog. One reads the payload, one checks the record, one
updates it with the progress note computed inside the same filter, and one
sorts the whole set into the feed while deciding the bar word. The session's
Claude pid is remembered on the record instead of asked for (`claude agents
--json` costs a process launch), and a marker beside the records says which
sessions are not tracked: a `claude -p` one-shot or a hidden row for good, a
session that could not be placed for a minute before it is tried again.

The two paths you can feel are kept short too. On the key press the
microphone opens before any housekeeping. On the release, once the transcript
is in, one `jq` reads every setting and the record is written the moment
`claude --bg` returns; the session's uuid and pid arrive with its own
`SessionStart` hook about half a second later, so nothing between letting go
of the key and "Working on it" waits on the session listing.

Findings from the CLI this was built against (Claude Code 2.1.266):

- `claude --bg` ignores `--session-id`; the short id it prints is the first 8
  characters of the session UUID, which is what the hooks receive.
- Session-scoped hooks passed with `--settings` do fire inside background
  sessions. `AskUserQuestion` shows up as `permission_prompt`.
- `claude agents --json` reports `status` (`busy`, `waiting`, `idle`), `state`
  (`blocked`, `done`, `stopped`) and `waitingFor`; the widget does not depend
  on these because they are undocumented.

## The bar critter

A pixel-art invader with Claude's eyes keeps the status readable at a glance
without a word of text. It sits still when idle, blinks while listening,
swings its arms and legs while Claude works, waves faster in the urgent colour
when Claude needs you, and turns red when something failed. When a session
finishes it blinks green three times over three seconds, so a finished task
registers even if you missed the toast. The popover has a larger cousin who
pulls a laptop out from behind his back and types while Claude works.

## Recovery and edge cases

- Let go of Super before D and the release bind never fires; recording keeps
  going. Press Super+D again: `start` notices the recording marker and stops.
- Closing a window VoxClaude opened never stops the work: every session it
  starts belongs to the Claude daemon, and the window is only a `claude attach`
  onto it ("The session keeps running either way", says `claude attach --help`).
  A session you started yourself in your own terminal is an ordinary
  interactive one and does end with its window.
- Nothing heard (voxtype exit 3) → quiet toast, back to idle.
- voxtype daemon down or Claude not logged in → error glyph plus a toast with
  the first line of stderr. `voxclaude status` prints the current word.
- Records older than a day are pruned (with their lock files), both after the
  microphone opens when you hold the key and, at most once an hour, from the
  hooks themselves, so a machine that only tracks terminal sessions does not
  pile them up. Pinned rows are exempt. The bar status is recomputed from the
  records on every hook, so a lost notification cannot wedge the glyph.
- Hiding a row takes it out of the list and nothing else: the session keeps
  running, and because it keeps its record it never returns untitled. The
  daily prune clears it in the end, like any other row. One exception: a
  hidden session that ends up needing you is listed again, because waiting out
  of sight for someone who cannot see it is worse than an unwanted row.
- A reply that says only that there is no file or URL to point at ("No file or
  URL for this one.") has that sentence dropped before it reaches a toast or a
  row.
- Clicking a row seems to do nothing: the attach window opened as a tile
  behind your floating or maximized terminal. Add the window rules from the
  Install section.
- If your home directory path contains spaces, the hook commands in
  `hooks.json` need quoting; open an issue.

## Removing it

VoxClaude puts three things outside its own directory: hooks in
`~/.claude/settings.json` if you ran `hooks install`, a widget entry in
`shell.json`, and the binds and window rules in your Hyprland config. Run this
first, while the plugin is still there:

```bash
~/.config/omarchy/plugins/io.github.nimbleaininja.voxclaude/bin/voxclaude uninstall
```

It takes its own hooks back out of `~/.claude/settings.json`, leaving anything
else in there untouched, and clears the runtime state. That has to happen
before the directory goes: those hooks name the script by absolute path, and
left behind they would make every Claude Code session on the machine run a
command that is not there, once per tool call.

It then prints the lines to delete from your own config files, with line
numbers, and leaves them to you:

- the `io.github.nimbleaininja.voxclaude` entry in a `bar.layout` section of
  `~/.config/omarchy/shell.json` (or Omarchy menu → Setup → Bar)
- the two `o.bind` lines in `~/.config/hypr/bindings.lua`
- the three `o.window` rules for `org.omarchy.voxclaude` in
  `~/.config/hypr/hyprland.lua`

Then remove the plugin and reload:

```bash
omarchy plugin remove io.github.nimbleaininja.voxclaude
hyprctl reload && omarchy restart shell
```

Nothing else is left: session records live only in `$XDG_RUNTIME_DIR`, and
voxtype is never reconfigured, so plain dictation on its own key is unaffected.

## Development

```bash
tests/run          # manifest, node unit tests, bash stub tests, QML tests, qmllint
omarchy restart shell   # plugin QML does not hot-reload on Omarchy 4
omarchy-shell io.github.nimbleaininja.voxclaude toggle
omarchy-shell io.github.nimbleaininja.voxclaude status
bin/voxclaude dispatch "reply with pong"   # exercise the pipeline without a microphone
bin/voxclaude list | jq                    # the session records
bin/voxclaude keybind                      # the hold key the widget will name
```

`Model.js` is pure ES5 shared by QML and node. `bin/voxclaude` is the only
thing that runs processes; `tests/voxclaude.test.sh` drives it with stub
`voxtype`, `claude` and `omarchy-*` binaries on `PATH`. The pixel renderer is
`PixelSprite.qml`, not `Sprite.qml`: QtQuick has a built-in `Sprite` type that
shadows a same-named file.

## License

MIT
