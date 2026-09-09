const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("wantsTerminal matches the word terminal anywhere, case-insensitively", () => {
  assert.equal(Model.wantsTerminal("open a terminal and show git status", "terminal"), true)
  assert.equal(Model.wantsTerminal("Terminal, please: run the tests", "terminal"), true)
  assert.equal(Model.wantsTerminal("fix the failing test", "terminal"), false)
})

test("wantsTerminal needs a whole word, not a substring", () => {
  assert.equal(Model.wantsTerminal("the patient is terminally ill", "terminal"), false)
  assert.equal(Model.wantsTerminal("check the terminals array", "terminal"), false)
})

test("wantsTerminal honours extra comma-separated trigger words", () => {
  assert.equal(Model.wantsTerminal("show me interactively", "terminal, interactively"), true)
  assert.equal(Model.wantsTerminal("show me interactively", "terminal"), false)
  assert.equal(Model.wantsTerminal("anything", ""), false)
  assert.equal(Model.wantsTerminal("", "terminal"), false)
})

test("terminalPattern is a POSIX-safe alternation for the bash mirror", () => {
  assert.equal(Model.terminalPattern("terminal"), "terminal")
  assert.equal(Model.terminalPattern(" terminal , shell,, console "), "terminal|shell|console")
  assert.equal(Model.terminalPattern("a.b"), "a\\.b")
})

test("parseBgOutput extracts the short id from claude --bg output", () => {
  const out = "Starting background service…\nbackgrounded · f7a2edcf · voxspike\n  claude agents             list sessions\n"
  assert.equal(Model.parseBgOutput(out), "f7a2edcf")
  assert.equal(Model.parseBgOutput("backgrounded · 39182b7e"), "39182b7e")
  assert.equal(Model.parseBgOutput("warning: nope\n"), "")
  assert.equal(Model.parseBgOutput(null), "")
})

test("glyphFor maps every status to a glyph and an emphasis", () => {
  const mic = String.fromCodePoint(0xF036C)
  const hourglass = String.fromCodePoint(0xF051F)
  const robot = String.fromCodePoint(0xF16A3)
  const alert = String.fromCodePoint(0xF05D6)
  assert.deepEqual(Model.glyphFor("idle"), { glyph: mic, active: false, urgent: false })
  assert.deepEqual(Model.glyphFor("listening"), { glyph: mic, active: true, urgent: false })
  assert.deepEqual(Model.glyphFor("transcribing"), { glyph: hourglass, active: true, urgent: false })
  assert.deepEqual(Model.glyphFor("thinking"), { glyph: robot, active: true, urgent: false })
  assert.deepEqual(Model.glyphFor("needs-input"), { glyph: robot, active: true, urgent: true })
  assert.deepEqual(Model.glyphFor("error"), { glyph: alert, active: false, urgent: true })
  assert.deepEqual(Model.glyphFor("bogus"), Model.glyphFor("idle"))
})

test("statusLabel is a short human phrase per status", () => {
  assert.equal(Model.statusLabel("idle", "Super+D"), "Hold Super+D and talk")
  assert.equal(Model.statusLabel("listening"), "Listening…")
  assert.equal(Model.statusLabel("transcribing"), "Transcribing…")
  assert.equal(Model.statusLabel("thinking"), "Claude is working")
  assert.equal(Model.statusLabel("needs-input"), "Claude needs you")
  assert.equal(Model.statusLabel("terminal"), "Running in a terminal")
  assert.equal(Model.statusLabel("error"), "Something went wrong")
  assert.equal(Model.statusLabel("done"), "Done")
})

test("statusLabel names whatever key is actually bound", () => {
  assert.equal(Model.statusLabel("idle", "Ctrl+Alt+Space"), "Hold Ctrl+Alt+Space and talk")
  assert.equal(Model.statusLabel("bogus", "Super+K"), "Hold Super+K and talk")
})

test("statusLabel asks for a bind when nothing is bound", () => {
  assert.equal(Model.statusLabel("idle", ""), "Bind a key to talk to Claude")
  assert.equal(Model.statusLabel("idle"), "Bind a key to talk to Claude")
})

test("emptyHint names the bound key, or asks for one", () => {
  assert.equal(Model.emptyHint("Super+D"), "Nothing yet. Hold Super+D and say what you need.")
  assert.equal(Model.emptyHint("Alt+F9"), "Nothing yet. Hold Alt+F9 and say what you need.")
  assert.match(Model.emptyHint(""), /[Bb]ind a key/)
})

test("excerpt trims, collapses whitespace and adds an ellipsis when cut", () => {
  assert.equal(Model.excerpt("  hello   world \n again ", 100), "hello world again")
  assert.equal(Model.excerpt("abcdefghij", 5), "abcd…")
  assert.equal(Model.excerpt("", 5), "")
  assert.equal(Model.excerpt(null, 5), "")
})

test("sortSessions puts needs-input first, then newest first", () => {
  const list = [
    { shortId: "a", status: "done", startedAt: 100 },
    { shortId: "b", status: "needs-input", startedAt: 50 },
    { shortId: "c", status: "thinking", startedAt: 200 },
    { shortId: "d", status: "done", startedAt: 300 }
  ]
  assert.deepEqual(Model.sortSessions(list).map(s => s.shortId), ["b", "d", "c", "a"])
  assert.deepEqual(Model.sortSessions(null), [])
  assert.deepEqual(Model.sortSessions("junk"), [])
})

test("stableOrder keeps known rows where they were and puts new ones first", () => {
  const a = { shortId: "a", pinned: true }, b = { shortId: "b" }, c = { shortId: "c" }, n = { shortId: "n" }
  // Sorted would put the newly pinned "a" first; the frozen order says b, a, c.
  assert.deepEqual(Model.stableOrder(["b", "a", "c"], [a, b, c]).map(s => s.shortId), ["b", "a", "c"])
  // A row that has gone (forgotten) simply drops out.
  assert.deepEqual(Model.stableOrder(["b", "a", "c"], [a, c]).map(s => s.shortId), ["a", "c"])
  // A row not in the frozen order goes first, in sorted order.
  assert.deepEqual(Model.stableOrder(["b", "a"], [n, a, b]).map(s => s.shortId), ["n", "b", "a"])
  assert.deepEqual(Model.stableOrder(["a"], [b, n, a]).map(s => s.shortId), ["b", "n", "a"])
  // Nothing frozen: sorted order as is.
  assert.deepEqual(Model.stableOrder([], [a, b]).map(s => s.shortId), ["a", "b"])
  assert.deepEqual(Model.stableOrder(null, [a, b]).map(s => s.shortId), ["a", "b"])
  assert.deepEqual(Model.stableOrder(["a"], null), [])
  assert.deepEqual(Model.sessionIds([a, b, { }]), ["a", "b", ""])
  assert.deepEqual(Model.sessionIds(null), [])
})

test("sortSessions accepts array-like lists from Qt", () => {
  const qtList = { length: 2, 0: { shortId: "x", status: "done", startedAt: 1 }, 1: { shortId: "y", status: "done", startedAt: 2 } }
  assert.deepEqual(Model.sortSessions(qtList).map(s => s.shortId), ["y", "x"])
})

test("relativeTime renders seconds, minutes, hours and days", () => {
  const now = 1_000_000_000
  assert.equal(Model.relativeTime(now - 5_000, now), "just now")
  assert.equal(Model.relativeTime(now - 90_000, now), "1m ago")
  assert.equal(Model.relativeTime(now - 3 * 3600_000, now), "3h ago")
  assert.equal(Model.relativeTime(now - 2 * 86400_000, now), "2d ago")
  assert.equal(Model.relativeTime(0, now), "")
})

test("overallStatus derives the bar state from session records", () => {
  assert.equal(Model.overallStatus([{ status: "done" }, { status: "needs-input" }]), "needs-input")
  assert.equal(Model.overallStatus([{ status: "done" }, { status: "thinking" }]), "thinking")
  assert.equal(Model.overallStatus([{ status: "done" }]), "idle")
  assert.equal(Model.overallStatus([]), "idle")
})

test("statusLabel and glyphFor know about stopped sessions", () => {
  assert.equal(Model.statusLabel("stopped"), "Stopped")
  assert.deepEqual(Model.glyphFor("stopped"), Model.glyphFor("idle"))
})

test("sprite frames are 9x8 grids of X and dots that use the full width", () => {
  for (const name of ["idle", "busyA", "busyB", "blink"]) {
    const frame = Model.SPRITE_FRAMES[name]
    assert.equal(frame.length, 8, name + " rows")
    for (const row of frame) {
      assert.equal(row.length, 9, name + " cols")
      assert.match(row, /^[.X]+$/)
    }
    // No frame wastes a column: something is lit in column 0 and column 8.
    assert.ok(frame.some(row => row[0] === "X"), name + " left edge")
    assert.ok(frame.some(row => row[8] === "X"), name + " right edge")
  }
  // Every busy frame differs from every other and from idle, so the animation
  // reads no matter which two frames the cycle happens to show.
  assert.notDeepEqual(Model.SPRITE_FRAMES.busyA, Model.SPRITE_FRAMES.busyB)
  assert.notDeepEqual(Model.SPRITE_FRAMES.busyA, Model.SPRITE_FRAMES.idle)
  assert.notDeepEqual(Model.SPRITE_FRAMES.busyB, Model.SPRITE_FRAMES.idle)
  // Arms: the busy frames light the outer columns on the arm row (5), idle does not.
  assert.equal(Model.SPRITE_FRAMES.busyA[5][0], "X")
  assert.equal(Model.SPRITE_FRAMES.busyA[5][8], "X")
  assert.equal(Model.SPRITE_FRAMES.idle[5][0], ".")
  // Legs: the bottom row differs between the two busy frames, so they step.
  assert.notEqual(Model.SPRITE_FRAMES.busyA[7], Model.SPRITE_FRAMES.busyB[7])
  // Blink only changes the eye row.
  const idle = Model.SPRITE_FRAMES.idle, blink = Model.SPRITE_FRAMES.blink
  assert.equal(idle.filter((row, i) => row !== blink[i]).length, 1)
})

test("spritePixels lists lit cells with coordinates", () => {
  const pixels = Model.spritePixels(["X.X", ".X."])
  assert.deepEqual(pixels, [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 1, y: 1 }])
  assert.deepEqual(Model.spritePixels(null), [])
})

test("spriteFrame animates only while busy", () => {
  assert.equal(Model.spriteFrame("idle", 0), Model.SPRITE_FRAMES.idle)
  assert.equal(Model.spriteFrame("idle", 7), Model.SPRITE_FRAMES.idle)
  assert.equal(Model.spriteFrame("error", 3), Model.SPRITE_FRAMES.idle)
  assert.equal(Model.spriteFrame("thinking", 0), Model.SPRITE_FRAMES.busyA)
  assert.equal(Model.spriteFrame("thinking", 1), Model.SPRITE_FRAMES.busyB)
  assert.equal(Model.spriteFrame("transcribing", 2), Model.SPRITE_FRAMES.busyA)
  assert.equal(Model.spriteFrame("needs-input", 3), Model.SPRITE_FRAMES.busyB)
  assert.equal(Model.spriteFrame("listening", 0), Model.SPRITE_FRAMES.idle)
  assert.equal(Model.spriteFrame("listening", 3), Model.SPRITE_FRAMES.blink)
})

test("laptop frames are 17x11 grids in the gif's four colours", () => {
  const names = Object.keys(Model.LAPTOP_FRAMES)
  assert.equal(names.length, 19)
  for (const name of names) {
    const frame = Model.LAPTOP_FRAMES[name]
    assert.equal(frame.length, 11, name + " rows")
    for (const row of frame) {
      assert.equal(row.length, 17, name + " cols")
      assert.match(row, /^[.XSEL]+$/)
    }
    // Every frame has eyes.
    assert.ok(frame.some(row => row.includes("E")), name + " eyes")
  }
  // The laptop is out of sight while idle and on screen while typing.
  assert.ok(!Model.LAPTOP_FRAMES.idle.some(row => row.includes("L")))
  for (const frame of Model.LAPTOP_TYPING) assert.ok(frame.some(row => row.includes("L")))
  // Typing frames all differ, so the loop reads as motion.
  assert.notDeepEqual(Model.LAPTOP_FRAMES.typeA, Model.LAPTOP_FRAMES.typeB)
  assert.notDeepEqual(Model.LAPTOP_FRAMES.typeB, Model.LAPTOP_FRAMES.typeC)
  assert.notDeepEqual(Model.LAPTOP_FRAMES.typeA, Model.LAPTOP_FRAMES.typeC)
  // Idle: wide-set eyes, no shading, laptop hidden.
  assert.equal(Model.LAPTOP_FRAMES.idle[4], "..XEXXXXEX.......")
})

test("every non-dot cell is lit, so eyes, shading and laptop all paint", () => {
  assert.deepEqual(Model.spritePixels(["XL", ".E"]), [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }])
  assert.equal(Model.litCount(["XSEL", "...."]), 4)
  for (const ch of ["X", "S", "E", "L"]) assert.ok(Model.isLit(ch), ch)
  for (const ch of [".", "", " "]) assert.ok(!Model.isLit(ch), JSON.stringify(ch))
})

test("the laptop critter pulls the laptop out once, then types", () => {
  const intro = Model.LAPTOP_INTRO, typing = Model.LAPTOP_TYPING
  assert.equal(intro.length, 8)
  assert.equal(intro[0], Model.LAPTOP_FRAMES.reach)
  assert.equal(intro[intro.length - 1], Model.LAPTOP_FRAMES.sit)
  for (let tick = 0; tick < intro.length; tick++) {
    assert.equal(Model.laptopFrame("thinking", tick), intro[tick], "intro tick " + tick)
    assert.equal(Model.laptopFrame("transcribing", tick), intro[tick])
  }
  for (let tick = intro.length; tick < intro.length + 9; tick++) {
    assert.equal(Model.laptopFrame("thinking", tick), typing[(tick - intro.length) % 3], "loop tick " + tick)
  }
  // Needs-input plays the intro, then bounces between the hop and typing.
  assert.equal(Model.laptopFrame("needs-input", 0), intro[0])
  assert.equal(Model.laptopFrame("needs-input", 8), Model.LAPTOP_FRAMES.hop)
  assert.equal(Model.laptopFrame("needs-input", 9), Model.LAPTOP_FRAMES.typeA)
  // Waiting keeps the laptop open and still; listening blinks; the rest sit idle.
  assert.equal(Model.laptopFrame("waiting", 5), Model.LAPTOP_FRAMES.pause)
  assert.ok(Model.LAPTOP_FRAMES.pause.some(row => row.includes("L")))
  assert.equal(Model.laptopFrame("listening", 0), Model.LAPTOP_FRAMES.idle)
  assert.equal(Model.laptopFrame("listening", 3), Model.LAPTOP_FRAMES.blinkA)
  assert.equal(Model.laptopFrame("idle", 7), Model.LAPTOP_FRAMES.idle)
  assert.equal(Model.laptopFrame("error", 7), Model.LAPTOP_FRAMES.idle)
  assert.equal(Model.laptopFrame("done", 7), Model.LAPTOP_FRAMES.idle)
  // Faster ticks than the invader, since one gesture is many frames.
  assert.equal(Model.laptopInterval("thinking"), 150)
  assert.equal(Model.laptopInterval("transcribing"), 150)
  assert.equal(Model.laptopInterval("needs-input"), 200)
  assert.equal(Model.laptopInterval("listening"), 400)
  assert.equal(Model.laptopInterval("waiting"), 0)
  assert.equal(Model.laptopInterval("idle"), 0)
  // The bar's invader is untouched by all of this.
  assert.equal(Model.spriteFrame("thinking", 0), Model.SPRITE_FRAMES.busyA)
  assert.equal(Model.spriteInterval("thinking"), 500)
})

test("the laptop tick restarts on status changes unless the laptop stays open", () => {
  assert.equal(Model.keepsTick("transcribing", "thinking"), true)
  assert.equal(Model.keepsTick("thinking", "needs-input"), true)
  assert.equal(Model.keepsTick("needs-input", "thinking"), true)
  assert.equal(Model.keepsTick("thinking", "waiting"), true)
  assert.equal(Model.keepsTick("idle", "thinking"), false)
  assert.equal(Model.keepsTick("listening", "transcribing"), false)
  assert.equal(Model.keepsTick("thinking", "idle"), false)
  assert.equal(Model.keepsTick("thinking", "done"), false)
  assert.equal(Model.keepsTick("idle", "listening"), false)
})

test("spriteInterval is faster when Claude needs you and off when idle", () => {
  assert.equal(Model.spriteInterval("thinking"), 500)
  assert.equal(Model.spriteInterval("transcribing"), 500)
  assert.equal(Model.spriteInterval("needs-input"), 250)
  assert.equal(Model.spriteInterval("listening"), 400)
  assert.equal(Model.spriteInterval("idle"), 0)
  assert.equal(Model.spriteInterval("error"), 0)
})

test("elapsed renders a compact duration", () => {
  const now = 1_000_000_000
  assert.equal(Model.elapsed(now - 12_000, now), "12s")
  assert.equal(Model.elapsed(now - 4 * 60_000, now), "4m")
  assert.equal(Model.elapsed(now - 3 * 3600_000 - 5 * 60_000, now), "3h 5m")
  assert.equal(Model.elapsed(0, now), "")
})

test("rowSubtitle is the status and the time, without the step", () => {
  const now = 1_000_000_000
  const running = { status: "thinking", startedAt: now - 4 * 60_000, step: "Editing App.jsx" }
  assert.equal(Model.rowSubtitle(running, now), "Claude is working · 4m")
  const waiting = { status: "needs-input", startedAt: now - 60_000, step: "Running: rm -rf build" }
  assert.equal(Model.rowSubtitle(waiting, now), "Claude needs you · 1m")
  const done = { status: "done", startedAt: now - 3600_000, finishedAt: now - 3000_000, step: "Editing App.jsx" }
  assert.equal(Model.rowSubtitle(done, now), "Done · 50m ago")
  const stopped = { status: "stopped", startedAt: now - 120_000 }
  assert.equal(Model.rowSubtitle(stopped, now), "Stopped · 2m ago")
})

test("rowStep is the live step, and only while the session is running", () => {
  assert.equal(Model.rowStep({ status: "thinking", step: "Editing App.jsx" }), "Editing App.jsx")
  assert.equal(Model.rowStep({ status: "needs-input", step: "Running: rm -rf build" }), "Running: rm -rf build")
  assert.equal(Model.rowStep({ status: "thinking" }), "")
  assert.equal(Model.rowStep({ status: "done", step: "Editing App.jsx" }), "")
  assert.equal(Model.rowStep({ status: "stopped", step: "Editing App.jsx" }), "")
  assert.equal(Model.rowStep(null), "")
})

test("visibleSessions drops rows with no prompt, unless they need you", () => {
  const rows = [
    { shortId: "blank", status: "stopped", prompt: "", startedAt: 4 },
    { shortId: "titled", status: "done", prompt: "did a thing", startedAt: 3 },
    { shortId: "asking", status: "needs-input", prompt: "", startedAt: 2 },
    { shortId: "spaces", status: "ready", prompt: "   ", startedAt: 1 }
  ]
  assert.deepEqual(Model.visibleSessions(rows).map(r => r.shortId), ["titled", "asking"])
  assert.deepEqual(Model.visibleSessions([]), [])
  assert.deepEqual(Model.visibleSessions(null), [])
})

test("latestFinish is the newest finish among the sessions that are done", () => {
  assert.equal(Model.latestFinish([
    { status: "done", finishedAt: 100 },
    { status: "done", finishedAt: 300 },
    { status: "thinking", finishedAt: 0 }
  ]), 300)
  // A turn that ended but left a background command running has not finished.
  assert.equal(Model.latestFinish([{ status: "waiting", finishedAt: 900 }]), 0)
  assert.equal(Model.latestFinish([{ status: "stopped" }, { status: "thinking" }]), 0)
  assert.equal(Model.latestFinish([]), 0)
  assert.equal(Model.latestFinish(null), 0)
})

test("resultLabel shortens urls and paths for chips", () => {
  assert.equal(Model.resultLabel({ kind: "url", value: "http://localhost:5173/" }), "localhost:5173")
  assert.equal(Model.resultLabel({ kind: "url", value: "https://example.com/some/long/path?x=1" }), "example.com/some/long/path")
  assert.equal(Model.resultLabel({ kind: "path", value: "/home/hydrox/Work/plants/index.html" }), "plants/index.html")
  assert.equal(Model.resultLabel({ kind: "path", value: "/home/hydrox/Work/plants" }), "Work/plants")
})

test("sortSessions puts needs-input first, then pinned, then newest", () => {
  const list = [
    { shortId: "old-pin", status: "done", startedAt: 10, pinned: true },
    { shortId: "new", status: "done", startedAt: 400 },
    { shortId: "wait", status: "needs-input", startedAt: 50 },
    { shortId: "new-pin", status: "done", startedAt: 300, pinned: true },
    { shortId: "mid", status: "thinking", startedAt: 200 }
  ]
  assert.deepEqual(Model.sortSessions(list).map(s => s.shortId), ["wait", "new-pin", "old-pin", "new", "mid"])
})

test("statusTone groups statuses into ok, busy, alert and muted", () => {
  assert.equal(Model.statusTone("done"), "ok")
  assert.equal(Model.statusTone("thinking"), "busy")
  assert.equal(Model.statusTone("transcribing"), "busy")
  assert.equal(Model.statusTone("listening"), "busy")
  assert.equal(Model.statusTone("needs-input"), "alert")
  assert.equal(Model.statusTone("error"), "alert")
  assert.equal(Model.statusTone("stopped"), "muted")
  assert.equal(Model.statusTone("idle"), "muted")
})

test("escapeHtml neutralises markup for StyledText", () => {
  assert.equal(Model.escapeHtml("a <b> & c"), "a &lt;b&gt; &amp; c")
  assert.equal(Model.escapeHtml(null), "")
})

test("waiting is a busy-toned status with its own label and a still sprite", () => {
  assert.equal(Model.statusLabel("waiting"), "Waiting on a background task")
  assert.equal(Model.statusTone("waiting"), "busy")
  assert.equal(Model.spriteFrame("waiting", 5), Model.SPRITE_FRAMES.idle)
  assert.equal(Model.spriteInterval("waiting"), 0)
  assert.deepEqual(Model.glyphFor("waiting"), { glyph: Model.glyphFor("idle").glyph, active: true, urgent: false })
  const now = 1_000_000_000
  const polling = { status: "waiting", startedAt: now - 60_000, step: "Running: poll build" }
  assert.equal(Model.rowSubtitle(polling, now), "Waiting on a background task · 1m")
  assert.equal(Model.rowStep(polling), "Running: poll build")
  assert.equal(Model.overallStatus([{ status: "done" }, { status: "waiting" }]), "waiting")
  assert.equal(Model.overallStatus([{ status: "waiting" }, { status: "thinking" }]), "thinking")
})

test("plainText strips markdown so replies read as prose", () => {
  assert.equal(Model.plainText("**Root cause:** the VM `freezes` while *sleeping*"), "Root cause: the VM freezes while sleeping")
  assert.equal(Model.plainText("## Done\n- first item\n- second item\n1. third"), "Done first item second item third")
  assert.equal(Model.plainText("See [the docs](https://example.com/x) and ~/Work/`a.txt`"), "See the docs and ~/Work/a.txt")
  assert.equal(Model.plainText("```bash\nnpm test\n```\nAll green."), "npm test All green.")
  assert.equal(Model.plainText("2 * 3 = 6 and a_b_c stays"), "2 * 3 = 6 and a_b_c stays")
  assert.equal(Model.plainText(null), "")
})

test("ready is a muted status for a terminal session with no prompt yet", () => {
  assert.equal(Model.statusLabel("ready"), "Ready")
  assert.equal(Model.statusTone("ready"), "muted")
  const now = 1_000_000_000
  assert.equal(Model.rowSubtitle({ status: "ready", startedAt: now - 5000 }, now), "Ready · just now")
  assert.equal(Model.overallStatus([{ status: "ready" }]), "idle")
})

test("kindGlyph tells terminal rows from voice rows", () => {
  assert.notEqual(Model.kindGlyph("terminal"), "")
  assert.notEqual(Model.kindGlyph("voice"), "")
  assert.notEqual(Model.kindGlyph("terminal"), Model.kindGlyph("voice"))
  assert.equal(Model.kindGlyph(undefined), Model.kindGlyph("voice"))
})

test("litCount counts lit cells without building a list of them", () => {
  assert.equal(Model.litCount([".X.", "XX."]), 3)
  assert.equal(Model.litCount([]), 0)
  assert.equal(Model.litCount(null), 0)
  for (const name of Object.keys(Model.SPRITE_FRAMES)) {
    assert.equal(Model.litCount(Model.SPRITE_FRAMES[name]),
                 Model.spritePixels(Model.SPRITE_FRAMES[name]).length, name)
  }
})
