// Pure helpers shared by Panel.qml and the node tests. No Qt, no I/O.
// Loaded by QML as `import "Model.js" as Model` and by node via module.exports.

function toList(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object" || typeof value.length !== "number") return null
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

// The hold key is whatever the user bound; bin/voxclaude keybind resolves it
// from Hyprland (or the hypr config) and the widget passes it in here. An
// empty keybind means no bind was found, so ask for one instead of naming a
// key that would do nothing.
function statusLabel(status, keybind) {
  switch (status) {
  case "listening": return "Listening…"
  case "transcribing": return "Transcribing…"
  case "thinking": return "Claude is working"
  case "needs-input": return "Claude needs you"
  case "waiting": return "Waiting on a background task"
  case "ready": return "Ready"
  case "terminal": return "Running in a terminal"
  case "error": return "Something went wrong"
  case "done": return "Done"
  case "stopped": return "Stopped"
  default: return keybind ? "Hold " + keybind + " and talk" : "Bind a key to talk to Claude"
  }
}

function emptyHint(keybind) {
  return keybind ? "Nothing yet. Hold " + keybind + " and say what you need."
                 : "Nothing yet. Bind a key to VoxClaude \u2014 see the README."
}

// Colour family for a status: ok (green), busy (yellow), alert (red), muted.
function statusTone(status) {
  switch (status) {
  case "done": return "ok"
  case "listening": case "transcribing": case "thinking": case "waiting": return "busy"
  case "needs-input": case "error": return "alert"
  default: return "muted"
  }
}

// Origin marker for a row: terminal-started sessions vs voice ones.
function kindGlyph(kind) {
  return kind === "terminal" ? String.fromCodePoint(0xF018D) : String.fromCodePoint(0xF036C)
}

function escapeHtml(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function excerpt(text, max) {
  var clean = String(text || "").replace(/\s+/g, " ").trim()
  if (clean.length <= max) return clean
  return clean.slice(0, Math.max(0, max - 1)) + "…"
}

// A terminal session gets its record at SessionStart and its title at the
// first prompt, so a row with no prompt has nothing to say yet. A row the user
// hid is out too. One that needs you is listed regardless: saying so is what
// the widget is for, an injected turn can reach that state without ever
// setting a title, and a hidden session blocked on a prompt nobody can see
// would wait for good.
function visibleSessions(list) {
  var items = toList(list)
  if (!items) return []
  var out = []
  for (var i = 0; i < items.length; i++) {
    var s = items[i] || {}
    if (s.status !== "needs-input" && s.hidden) continue
    if (String(s.prompt || "").trim() !== "" || s.status === "needs-input") out.push(items[i])
  }
  return out
}

// The session the bar word is describing. The bar takes needs-input over
// thinking over waiting across every record (STATUS_FILTER in bin/voxclaude),
// so pairing that word with the top row could label one session and name
// another. Nothing matching means the word is about capture, not a session.
function sessionForStatus(list, status) {
  var items = toList(list)
  if (!items) return null
  for (var i = 0; i < items.length; i++) {
    if (items[i] && items[i].status === status) return items[i]
  }
  return null
}

function sortSessions(list) {
  var items = toList(list)
  if (!items) return []
  var out = items.slice()
  // Attention first, bookmarks second, then newest.
  out.sort(function(a, b) {
    var aNeeds = a && a.status === "needs-input" ? 1 : 0
    var bNeeds = b && b.status === "needs-input" ? 1 : 0
    if (aNeeds !== bNeeds) return bNeeds - aNeeds
    var aPin = a && a.pinned ? 1 : 0
    var bPin = b && b.pinned ? 1 : 0
    if (aPin !== bPin) return bPin - aPin
    return Number(b && b.startedAt || 0) - Number(a && a.startedAt || 0)
  })
  return out
}

// Re-sorting the list under the pointer is jarring: pinning a row would
// send it to the top mid-click. While the popover is open the rows keep the
// order they had when it opened (`ids`); rows that have since disappeared
// drop out, and rows not yet seen go first, in sorted order, which is where
// the next open would put them anyway. `sorted` is already sorted.
function stableOrder(ids, sorted) {
  var items = toList(sorted) || []
  var seen = toList(ids) || []
  var byId = {}
  for (var i = 0; i < items.length; i++) byId[String(items[i] && items[i].shortId || "")] = items[i]
  var out = []
  var placed = {}
  for (var n = 0; n < items.length; n++) {
    var id = String(items[n] && items[n].shortId || "")
    if (seen.indexOf(id) < 0 && !placed[id]) { out.push(items[n]); placed[id] = true }
  }
  for (var k = 0; k < seen.length; k++) {
    var known = String(seen[k])
    if (byId[known] !== undefined && !placed[known]) { out.push(byId[known]); placed[known] = true }
  }
  return out
}

function sessionIds(list) {
  var items = toList(list) || []
  var out = []
  for (var i = 0; i < items.length; i++) out.push(String(items[i] && items[i].shortId || ""))
  return out
}

function relativeTime(thenMs, nowMs) {
  var then = Number(thenMs)
  if (!(then > 0)) return ""
  var seconds = Math.max(0, Math.floor((Number(nowMs) - then) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}

// ---------------------------------------------------------------- sprite
//
// A 9x8 pixel critter: an invader silhouette with wide-set eyes.
// Busy frames swing the arms out and swap the legs; listening blinks.
var SPRITE_FRAMES = {
  // 9x8. Eyes one cell in from the edge; arms and feet use the outer columns
  // so no frame is wider than the box, and every frame lights columns 0 and 8.
  idle: [
    ".XXXXXXX.",
    "XXXXXXXXX",
    "X.XXXXX.X",
    "XXXXXXXXX",
    ".XXXXXXX.",
    "..X...X..",
    ".X.....X.",
    "X.......X"
  ],
  busyA: [
    ".XXXXXXX.",
    "XXXXXXXXX",
    "X.XXXXX.X",
    "XXXXXXXXX",
    "XXXXXXXXX",
    "X.X...X.X",
    "..X...X..",
    "..X...X.."
  ],
  busyB: [
    ".XXXXXXX.",
    "XXXXXXXXX",
    "X.XXXXX.X",
    "XXXXXXXXX",
    ".XXXXXXX.",
    ".X.....X.",
    "..X...X..",
    ".X.....X."
  ],
  blink: [
    ".XXXXXXX.",
    "XXXXXXXXX",
    "XXXXXXXXX",
    "XXXXXXXXX",
    ".XXXXXXX.",
    "..X...X..",
    ".X.....X.",
    "X.......X"
  ]
}

// The laptop critter, traced cell for cell from claude-laptop.gif (a 19x19
// pixel-art gif, cropped to the 17x11 cells the critter and laptop use) and
// drawn in the popover hero in the gif's own colours: "X" body, "S" the
// darker shading, "E" eyes, "L" laptop. Idle, blink, pull the laptop out
// from behind, open it, hop, type, then close it and tuck it away.
var LAPTOP_FRAMES = {
  idle: [
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "..XEXXXXEX.......",
    "XXXXXXXXXXXX.....",
    "XXXXXXXXXXXX.....",
    "..XXXXXXXX.......",
    "..XXXXXXXX.......",
    "..X.X..X.X.......",
    "..X.X..X.X......."
  ],
  blinkA: [
    ".................",
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "XXXXXXXXXX.......",
    "XXXESXXXEX.......",
    "..XXXXXXXXXX.....",
    "..XXXXXXXXX......",
    "..XXXXXXXX.......",
    "..X.X..X.X......."
  ],
  blinkB: [
    ".................",
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "XXXXXXXXXX.......",
    "XXXESXXXEX.......",
    "..XXXXXXXXXX.....",
    "..XXXXXXXXXX.....",
    "..XXXXXXXX.......",
    "..X.X..X.X......."
  ],
  reach: [
    ".................",
    ".................",
    "..........LLL....",
    "..XXXXXXXX..LL...",
    "..XEXXXXEXXX.....",
    "..XXXXXXXXXX.....",
    "XXXXXXXXXXXX.....",
    "XXXXXXXXXX.......",
    "..XXXXXXXX.......",
    "..X.X..X.X.......",
    "..X.X..X.X......."
  ],
  pull: [
    ".............L...",
    ".............L...",
    "..........LLLL...",
    "..XXXXXXXXXX.....",
    "..XEXXXXEXXX.....",
    "..XXXXXXXX.......",
    "XXXXXXXXXX.......",
    "XXXXXXXXXX.......",
    "..XXXXXXXX.......",
    "..X.X..X.X.......",
    "..X.X..X.X......."
  ],
  swing: [
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "..XXXXXXXX.......",
    "XXXEXXXXEX....LLL",
    "XXXXXXXXXXXX..LL.",
    "..XXXXXXXXXLLLL..",
    "..XXXXXXXXXX.....",
    "..X.X..X.X.......",
    "..X.X..X.X......."
  ],
  lower: [
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "..XXXXXXXX.......",
    "..XEXXXXEX.......",
    "XXXXXXXXXX.......",
    "XXXXXXXXXX.......",
    "..XXXXXXXXXX....L",
    "..X.X..X.XXX...L.",
    "..X.X..X.X....L.."
  ],
  set: [
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "..XXXXXXXX.......",
    "XXXEXXXXEXXX.....",
    "XXXXXXXXXXXX.....",
    "..XXXXXXXX.......",
    "..XXXXXXXX.......",
    "..X.X..X.X......L",
    "..X.X..X.X....L.."
  ],
  hop: [
    ".................",
    "....XX...XX......",
    "...XXX...XXX.....",
    "..SXXXXXXXXX.....",
    "..SXXXXXXXX......",
    "..SXEXXXXEX......",
    "..SXXXXXXXX......",
    "..SXXXXXXXX......",
    "..SXXXXXXXX.....L",
    "..SX.X..X.X...LL.",
    "..SX.X..X.X.LLL.."
  ],
  sit: [
    ".................",
    ".................",
    ".................",
    ".................",
    "...SSXXXXXXS.....",
    "...SSXEXXXESX....",
    "...SSXEXXXESX....",
    "...SSXXXXXXSS....",
    "...SSXXXXXXXX...L",
    "...S.X..X.XXX..L.",
    "..SS.X..X.XXX.L.."
  ],
  typeA: [
    ".................",
    ".................",
    ".................",
    ".................",
    "...SSXXXXXX......",
    "...SSXXXXXX......",
    "...SSXEXXXE......",
    "...SSXXXXXXXX....",
    "...SSXXXXXXXX...L",
    "...SSXXXXXXSS.LL.",
    "..SS.X..X.X.LLL.."
  ],
  typeB: [
    ".................",
    ".................",
    ".................",
    ".................",
    "...SSXXXXXX......",
    "...SSXXXXXX......",
    "...SSXEXXXE......",
    "...SSXXXXXXXX....",
    "...SSXXXXXXXX...L",
    "...SSXXXXXXSS..L.",
    "..SS.X..X.XSS.L.."
  ],
  typeC: [
    ".................",
    ".................",
    ".................",
    ".................",
    "...SSXXXXXX......",
    "...SSXXXXXX......",
    "...SSXEXXXE......",
    "...SSXXXXXXSS....",
    "...SSXXXXXXXX...L",
    "...SSXXXXXXXX..L.",
    "..SS.X..X.X...L.."
  ],
  pause: [
    ".................",
    ".................",
    ".................",
    ".................",
    "...SSXXXXXX......",
    "...SSXXXXXX......",
    "...SSXEXXXE......",
    "...SSXXXXXXSS....",
    "...SSXXXXXXXX...L",
    "...SSXXXXXXXX..L.",
    "..SS.X..X.XXX.L.."
  ],
  close: [
    ".................",
    ".................",
    ".................",
    ".................",
    "..SSSXXXXXS......",
    "..SSSSEXXSSXX....",
    "..SSSSEXXSSSX....",
    "..SSSXXXXXSSS.LL.",
    "..SSSXXXXXXXX.L..",
    "...S.X..X.XXX....",
    "..SS.X..X.XXX...."
  ],
  tuck: [
    ".................",
    ".................",
    ".................",
    "..SXXXXXXX.......",
    "..SXXXXXXX.......",
    "..SSEXXXXE.......",
    ".XXSXXXXXXXXL....",
    ".XXSXXXXXXXXXL...",
    "..SXXXXXXXSLLL...",
    "..S.X..X.X.......",
    "..S.X..X.X......."
  ],
  settleBlink: [
    ".................",
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "XXXXXXXXXX.......",
    "XXXEXXXXEX.......",
    "..XXXXXXXXXX.....",
    "..XXXXXXXXXX.....",
    "..XXXXXXXX.......",
    "..X.X..X.X......."
  ],
  settleA: [
    ".................",
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "XXXXXXXXXX.......",
    "XXXEXXXXEX.......",
    "..XXXXXXXXX......",
    "..XXXXXXXXX......",
    "..XXXXXXXX.......",
    "..X.X..X.X......."
  ],
  settleB: [
    ".................",
    ".................",
    ".................",
    "..XXXXXXXX.......",
    "..XEXXXXEX.......",
    "..XXXXXXXX.......",
    "XXXXXXXXXXXX.....",
    "XXXXXXXXXXXX.....",
    "..XXXXXXXX.......",
    "..X.X..X.X.......",
    "..X.X..X.X......."
  ]
}

// Any cell that is not a dot is painted; the renderer picks the colour.
function isLit(ch) {
  return ch !== "" && ch !== "." && ch !== " "
}

// Just the count: a list of lit cells would mean an object per cell, which is
// a lot of garbage for a property re-read on every animation tick.
function litCount(frame) {
  var rows = toList(frame) || []
  var total = 0
  for (var y = 0; y < rows.length; y++) {
    var row = String(rows[y])
    for (var x = 0; x < row.length; x++) if (isLit(row.charAt(x))) total++
  }
  return total
}

// The bar's invader.
function spriteFrame(status, tick) {
  switch (status) {
  case "thinking":
  case "transcribing":
  case "needs-input":
    return tick % 2 === 0 ? SPRITE_FRAMES.busyA : SPRITE_FRAMES.busyB
  case "listening":
    return tick % 4 === 3 ? SPRITE_FRAMES.blink : SPRITE_FRAMES.idle
  // Claude's turn is over but a command it started will wake it: alive, not
  // working. A slow blink says so without competing with the busy frames.
  case "waiting":
    return tick % 2 === 0 ? SPRITE_FRAMES.idle : SPRITE_FRAMES.blink
  default:
    return SPRITE_FRAMES.idle
  }
}

// Milliseconds between frames; 0 means hold still.
function spriteInterval(status) {
  switch (status) {
  case "thinking":
  case "transcribing": return 500
  case "needs-input": return 250
  case "listening": return 400
  case "waiting": return 900
  default: return 0
  }
}

// Statuses during which the laptop critter has its laptop out.
function laptopOpen(status) {
  return status === "thinking" || status === "transcribing" || status === "needs-input" || status === "waiting"
}

// The laptop animation restarts on a status change unless the laptop stays
// open across it: transcribing → thinking must not pull the laptop out twice.
function keepsTick(from, to) {
  return laptopOpen(from) && laptopOpen(to)
}

// Pulling the laptop out and opening it plays once from tick 0, then the
// typing loop runs for as long as the status lasts.
var LAPTOP_INTRO = [
  LAPTOP_FRAMES.reach, LAPTOP_FRAMES.pull, LAPTOP_FRAMES.pull, LAPTOP_FRAMES.swing,
  LAPTOP_FRAMES.lower, LAPTOP_FRAMES.set, LAPTOP_FRAMES.hop, LAPTOP_FRAMES.sit
]
var LAPTOP_TYPING = [LAPTOP_FRAMES.typeA, LAPTOP_FRAMES.typeB, LAPTOP_FRAMES.typeC]

// The popover's laptop critter.
function laptopFrame(status, tick) {
  switch (status) {
  case "thinking":
  case "transcribing":
    return tick < LAPTOP_INTRO.length ? LAPTOP_INTRO[tick]
                                      : LAPTOP_TYPING[(tick - LAPTOP_INTRO.length) % LAPTOP_TYPING.length]
  case "needs-input":
    return tick < LAPTOP_INTRO.length ? LAPTOP_INTRO[tick]
                                      : (tick % 2 === 0 ? LAPTOP_FRAMES.hop : LAPTOP_FRAMES.typeA)
  case "waiting":
    return LAPTOP_FRAMES.pause
  case "listening":
    return tick % 4 === 3 ? LAPTOP_FRAMES.blinkA : LAPTOP_FRAMES.idle
  default:
    return LAPTOP_FRAMES.idle
  }
}

// One gesture is many frames, so the laptop critter ticks faster than the
// invader. The gif itself runs at about 86ms a frame.
function laptopInterval(status) {
  switch (status) {
  case "thinking":
  case "transcribing": return 150
  case "needs-input": return 200
  case "listening": return 400
  default: return 0
  }
}

// ---------------------------------------------------------------- rows

function elapsed(startMs, nowMs) {
  var start = Number(startMs)
  if (!(start > 0)) return ""
  var seconds = Math.max(0, Math.floor((Number(nowMs) - start) / 1000))
  if (seconds < 60) return seconds + "s"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
}

function isRunning(status) {
  return status === "thinking" || status === "waiting" || status === "needs-input" || status === "listening" || status === "transcribing"
}

function rowSubtitle(session, nowMs) {
  var s = session || {}
  var parts = [statusLabel(s.status)]
  parts.push(isRunning(s.status) ? elapsed(s.startedAt, nowMs)
                                 : relativeTime(s.finishedAt || s.startedAt, nowMs))
  var out = []
  for (var i = 0; i < parts.length; i++) if (parts[i] !== "") out.push(parts[i])
  return out.join(" · ")
}

// What Claude is doing right now. It gets a line of its own under the status:
// it is the longest part of the row and the part that changes every few
// seconds, so sharing a line with the clock made both of them elide.
function rowStep(session) {
  var s = session || {}
  return isRunning(s.status) ? String(s.step || "") : ""
}

// The newest moment a session finished, for the widget's three green blinks.
// Only sessions that are done count: a turn that ended while a command it
// started is still running has not finished, and gets no toast either.
function latestFinish(list) {
  var items = toList(list)
  if (!items) return 0
  var max = 0
  for (var i = 0; i < items.length; i++) {
    var s = items[i] || {}
    if (s.status !== "done") continue
    var at = Number(s.finishedAt || 0)
    if (at > max) max = at
  }
  return max
}

function resultLabel(result) {
  var value = String(result && result.value || "")
  if (result && result.kind === "url") {
    var clean = value.replace(/^[a-z]+:\/\//i, "").replace(/[?#].*$/, "").replace(/\/+$/, "")
    if (clean.length <= 34) return clean
    // A chip is sized to its label, so a deep link ran off the popover and was
    // cut without an ellipsis. The host and the last segment are the parts
    // that say what it is; the middle is what makes it long.
    var parts = clean.split("/")
    var folded = parts[0] + "/…/" + parts[parts.length - 1]
    return folded.length < clean.length ? excerpt(folded, 40) : excerpt(clean, 34)
  }
  var segments = value.replace(/\/+$/, "").split("/")
  return segments.slice(-2).join("/")
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    toList: toList, statusLabel: statusLabel, emptyHint: emptyHint, statusTone: statusTone,
    kindGlyph: kindGlyph, escapeHtml: escapeHtml, excerpt: excerpt,
    sortSessions: sortSessions, visibleSessions: visibleSessions, stableOrder: stableOrder,
    sessionIds: sessionIds, sessionForStatus: sessionForStatus, relativeTime: relativeTime, latestFinish: latestFinish,
    SPRITE_FRAMES: SPRITE_FRAMES, LAPTOP_FRAMES: LAPTOP_FRAMES, LAPTOP_INTRO: LAPTOP_INTRO, LAPTOP_TYPING: LAPTOP_TYPING,
    isLit: isLit, litCount: litCount,
    spriteFrame: spriteFrame, spriteInterval: spriteInterval,
    laptopOpen: laptopOpen, keepsTick: keepsTick, laptopFrame: laptopFrame, laptopInterval: laptopInterval,
    elapsed: elapsed, isRunning: isRunning, rowSubtitle: rowSubtitle, rowStep: rowStep, resultLabel: resultLabel
  }
}
