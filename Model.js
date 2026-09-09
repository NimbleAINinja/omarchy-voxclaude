// Pure helpers shared by Panel.qml and the node tests. No Qt, no I/O.
// Loaded by QML as `import "Model.js" as Model` and by node via module.exports.

var STATUSES = ["idle", "listening", "transcribing", "thinking", "needs-input", "terminal", "error", "done"]

function toList(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object" || typeof value.length !== "number") return null
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

function escapeRegex(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// Comma-separated trigger words -> "a|b|c" alternation usable from both JS and
// bash's [[ =~ ]] (ERE). Blank entries are dropped.
function terminalPattern(words) {
  var parts = String(words || "").split(",")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var word = parts[i].trim()
    if (word !== "") out.push(escapeRegex(word))
  }
  return out.join("|")
}

function wantsTerminal(text, words) {
  var pattern = terminalPattern(words)
  if (pattern === "" || !text) return false
  var re = new RegExp("(^|[^A-Za-z0-9_])(" + pattern + ")([^A-Za-z0-9_]|$)", "i")
  return re.test(String(text))
}

// `claude --bg` prints "backgrounded · <shortId> · <name>".
function parseBgOutput(stdout) {
  var match = /backgrounded\s*[·:-]?\s*([0-9a-f]{6,})/i.exec(String(stdout || ""))
  return match ? match[1] : ""
}

function glyphFor(status) {
  var mic = String.fromCodePoint(0xF036C)
  var hourglass = String.fromCodePoint(0xF051F)
  var robot = String.fromCodePoint(0xF16A3)
  var alert = String.fromCodePoint(0xF05D6)
  switch (status) {
  case "listening": return { glyph: mic, active: true, urgent: false }
  case "transcribing": return { glyph: hourglass, active: true, urgent: false }
  case "thinking": return { glyph: robot, active: true, urgent: false }
  case "needs-input": return { glyph: robot, active: true, urgent: true }
  case "error": return { glyph: alert, active: false, urgent: true }
  case "waiting": return { glyph: mic, active: true, urgent: false }
  default: return { glyph: mic, active: false, urgent: false }
  }
}

function statusLabel(status) {
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
  default: return "Hold Super+D and talk"
  }
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

// Markdown → prose for excerpts: code fences and inline code lose their
// ticks, links keep their text, headings, bullets and emphasis markers go.
// Lone asterisks ("2 * 3") and snake_case survive.
function plainText(markdown) {
  var text = String(markdown || "")
  text = text.replace(/^\s*```.*$/gm, "")
  text = text.replace(/`([^`]*)`/g, "$1")
  text = text.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
  text = text.replace(/^\s*#{1,6}\s+/gm, "")
  text = text.replace(/^\s*(?:[-*+]|\d+\.)\s+/gm, "")
  text = text.replace(/(\*\*|__)(\S(?:[\s\S]*?\S)?)\1/g, "$2")
  text = text.replace(/(^|[\s(])[*_](\S(?:[^*_\n]*?\S)?)[*_](?=[\s).,;:!?]|$)/g, "$1$2")
  return text.replace(/\s+/g, " ").trim()
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

function overallStatus(list) {
  var items = toList(list) || []
  var thinking = false, waiting = false
  for (var i = 0; i < items.length; i++) {
    var status = items[i] && items[i].status
    if (status === "needs-input") return "needs-input"
    if (status === "thinking") thinking = true
    if (status === "waiting") waiting = true
  }
  return thinking ? "thinking" : (waiting ? "waiting" : "idle")
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

function spritePixels(frame) {
  var rows = toList(frame) || []
  var out = []
  for (var y = 0; y < rows.length; y++) {
    var row = String(rows[y])
    for (var x = 0; x < row.length; x++) if (row.charAt(x) === "X") out.push({ x: x, y: y })
  }
  return out
}

function spriteFrame(status, tick) {
  switch (status) {
  case "thinking":
  case "transcribing":
  case "needs-input":
    return tick % 2 === 0 ? SPRITE_FRAMES.busyA : SPRITE_FRAMES.busyB
  case "listening":
    return tick % 4 === 3 ? SPRITE_FRAMES.blink : SPRITE_FRAMES.idle
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
  if (isRunning(s.status)) {
    parts.push(elapsed(s.startedAt, nowMs))
    parts.push(String(s.step || ""))
  } else {
    parts.push(relativeTime(s.finishedAt || s.startedAt, nowMs))
  }
  var out = []
  for (var i = 0; i < parts.length; i++) if (parts[i] !== "") out.push(parts[i])
  return out.join(" · ")
}

function resultLabel(result) {
  var value = String(result && result.value || "")
  if (result && result.kind === "url") {
    return value.replace(/^[a-z]+:\/\//i, "").replace(/[?#].*$/, "").replace(/\/+$/, "")
  }
  var segments = value.replace(/\/+$/, "").split("/")
  return segments.slice(-2).join("/")
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    STATUSES: STATUSES, toList: toList, terminalPattern: terminalPattern, wantsTerminal: wantsTerminal,
    parseBgOutput: parseBgOutput, glyphFor: glyphFor, statusLabel: statusLabel, statusTone: statusTone, kindGlyph: kindGlyph, plainText: plainText, escapeHtml: escapeHtml, excerpt: excerpt,
    sortSessions: sortSessions, relativeTime: relativeTime, overallStatus: overallStatus,
    SPRITE_FRAMES: SPRITE_FRAMES, spritePixels: spritePixels, spriteFrame: spriteFrame, spriteInterval: spriteInterval,
    elapsed: elapsed, isRunning: isRunning, rowSubtitle: rowSubtitle, resultLabel: resultLabel
  }
}
