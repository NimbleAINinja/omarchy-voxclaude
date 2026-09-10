import QtQuick
import QtTest
import "../.." as Plugin

// Headless checks for SessionList.qml: pure QtQuick, no Quickshell imports.
TestCase {
  id: suite
  name: "SessionList"
  width: 360
  height: 300
  when: windowShown
  visible: true

  Component {
    id: listComponent
    Plugin.SessionList {
      width: 360
      nowMs: 1000000000
    }
  }

  function sessions() {
    return [
      { shortId: "aaaa1111", status: "done", startedAt: 1000000000 - 3600000, prompt: "  first   thing ", reply: "ok" },
      { shortId: "bbbb2222", status: "needs-input", startedAt: 1000000000 - 120000, prompt: "second thing", reply: "" },
      { shortId: "cccc3333", status: "thinking", startedAt: 1000000000 - 5000, prompt: "third " + "x".repeat(200), reply: "" }
    ]
  }

  function makeList(props) {
    var list = createTemporaryObject(listComponent, suite, props || {})
    verify(list !== null)
    return list
  }

  function test_rows_follow_sort_order() {
    var list = makeList({ sessions: sessions() })
    compare(list.count, 3)
    compare(list.rowAt(0).shortId, "bbbb2222")
    compare(list.rowAt(1).shortId, "cccc3333")
    compare(list.rowAt(2).shortId, "aaaa1111")
  }

  function test_row_text_is_excerpt_label_and_time() {
    var list = makeList({ sessions: sessions() })
    var row = list.rowAt(2)
    compare(row.promptText, "first thing")
    compare(row.statusText, "Done")
    compare(row.timeText, "1h ago")
    compare(list.rowAt(1).promptText.length, 140)
  }

  function test_row_cap() {
    var many = []
    for (var i = 0; i < 20; i++) many.push({ shortId: "id" + i, status: "done", startedAt: i, prompt: "p" + i })
    var list = makeList({ sessions: many, maxRows: 8 })
    compare(list.count, 8)
    compare(list.rowAt(0).shortId, "id19")
  }

  function test_click_requests_attach() {
    var list = makeList({ sessions: sessions() })
    var seen = []
    list.attachRequested.connect(function(id) { seen.push(id) })
    var row = list.rowAt(1)
    mouseClick(row, row.width / 2, row.height / 2)
    compare(seen, ["cccc3333"])
  }

  function test_subtitle_reply_and_chips() {
    var list = makeList({ sessions: [
      { shortId: "run1", status: "thinking", startedAt: 1000000000 - 240000, prompt: "build it", step: "Editing App.jsx" },
      { shortId: "done1", status: "done", startedAt: 1000000000 - 3600000, finishedAt: 1000000000 - 3000000, prompt: "made it",
        reply: "Built it.   Open http://localhost:5173/ to see it.",
        results: [{ kind: "url", value: "http://localhost:5173/" }, { kind: "path", value: "/home/x/Work/plants/index.html" }] }
    ] })
    compare(list.rowAt(0).subtitleText, "Claude is working · 4m")
    compare(list.rowAt(0).replyText, "")
    compare(list.rowAt(0).chipCount, 0)
    compare(list.rowAt(1).subtitleText, "Done · 50m ago")
    compare(list.rowAt(1).replyText, "Built it. Open http://localhost:5173/ to see it.")
    // Turning that reply into prose is bin/voxclaude's job, checked there;
    // see test_reply_is_shown_as_stored.
    compare(list.rowAt(1).chipCount, 2)
    compare(list.rowAt(1).chipAt(0).label, "localhost:5173")
  }

  function test_chip_click_requests_open_not_attach() {
    var list = makeList({ sessions: [
      { shortId: "done1", status: "done", startedAt: 1, prompt: "p", reply: "r",
        results: [{ kind: "url", value: "http://localhost:5173/" }] }
    ] })
    var opened = [], attached = []
    list.openRequested.connect(function(v) { opened.push(v) })
    list.attachRequested.connect(function(id) { attached.push(id) })
    var chip = list.rowAt(0).chipAt(0)
    mouseClick(chip, chip.width / 2, chip.height / 2)
    compare(opened, ["http://localhost:5173/"])
    compare(attached, [])
  }

  function test_right_click_requests_forget() {
    var list = makeList({ sessions: sessions() })
    var forgotten = []
    list.forgetRequested.connect(function(id) { forgotten.push(id) })
    var row = list.rowAt(0)
    mouseClick(row, row.width / 2, 10, Qt.RightButton)
    compare(forgotten, ["bbbb2222"])
  }

  // The step used to share the status line, where it pushed the time aside
  // and elided as soon as Claude did anything worth reporting.
  function test_step_has_its_own_line_below_the_status() {
    var list = makeList({ sessions: [
      { shortId: "run1", status: "thinking", startedAt: 1000000000 - 240000, prompt: "build it", step: "Editing App.jsx" },
      { shortId: "done1", status: "done", startedAt: 1000000000 - 3600000, finishedAt: 1000000000 - 3000000, prompt: "made it", step: "Editing App.jsx" }
    ] })
    var running = list.rowAt(0)
    compare(running.stepText, "Editing App.jsx")
    verify(running.stepVisible)
    verify(running.stepY > running.statusY)
    // Indented to sit under the status word, past the kind glyph and the dot.
    verify(running.stepX > 0)
    var finished = list.rowAt(1)
    compare(finished.stepText, "")
    verify(!finished.stepVisible)
  }

  // A terminal session gets its record at SessionStart and its title at the
  // first prompt; until then there is nothing to show, so it is not listed.
  function test_rows_without_a_prompt_are_not_listed() {
    var list = makeList({ sessions: [
      { shortId: "blank1", status: "stopped", startedAt: 1000000000 - 60000, prompt: "" },
      { shortId: "real1", status: "done", startedAt: 1000000000 - 120000, prompt: "did a thing" }
    ] })
    compare(list.count, 1)
    compare(list.rowAt(0).shortId, "real1")
  }

  function test_cursor_follows_keyboard() {
    var list = makeList({ sessions: sessions() })
    compare(list.cursor, -1)
    list.moveCursor(1)
    compare(list.cursor, 0)
    list.moveCursor(1)
    compare(list.cursor, 1)
    list.moveCursor(-5)
    compare(list.cursor, 0)
    verify(list.rowAt(0).hasCursor)
    verify(!list.rowAt(1).hasCursor)
    compare(list.cursorId(), "bbbb2222")
  }

  function test_pin_is_the_only_hover_action() {
    var list = makeList({ sessions: [
      { shortId: "p1", status: "done", startedAt: 2, prompt: "pinned one", pinned: true },
      { shortId: "u1", status: "done", startedAt: 1, prompt: "plain one" }
    ] })
    var pinned = list.rowAt(0), plain = list.rowAt(1)
    verify(pinned.pinned)
    verify(!plain.pinned)
    verify(pinned.pinButton.shown)
    verify(!plain.pinButton.shown)
    // The slot is always laid out so the prompt never reflows on hover.
    verify(plain.pinButton.visible)
    var widthBefore = plain.promptWidth
    list.cursor = 1
    verify(plain.pinButton.shown)
    compare(plain.promptWidth, widthBefore)
    verify(plain.removeButton === undefined)
    verify(plain.openHint === undefined)
  }

  function test_pin_button_does_not_open_the_row() {
    var list = makeList({ sessions: sessions() })
    list.cursor = 0
    var pins = [], attaches = []
    list.pinRequested.connect(function(id) { pins.push(id) })
    list.attachRequested.connect(function(id) { attaches.push(id) })
    var row = list.rowAt(0)
    mouseClick(row.pinButton, row.pinButton.width / 2, row.pinButton.height / 2)
    compare(pins, ["bbbb2222"])
    compare(attaches, [])
  }

  function test_pin_hit_box_is_bigger_than_its_glyph() {
    var list = makeList({ sessions: [{ shortId: "bbbb2222", status: "done", startedAt: 2, prompt: "second" }] })
    var pin = list.rowAt(0).pinButton
    verify(pin.width >= 28, "width " + pin.width)
    verify(pin.height >= 24, "height " + pin.height)
    // Clicking at the corner of the box, well away from the glyph, still pins.
    var pins = []
    list.pinRequested.connect(function(id) { pins.push(id) })
    list.cursor = 0
    mouseClick(pin, 2, 2)
    compare(pins, ["bbbb2222"])
  }

  function test_hovering_the_pin_keeps_the_row_highlighted() {
    var list = makeList({ sessions: [{ shortId: "bbbb2222", status: "done", startedAt: 2, prompt: "second" }] })
    var row = list.rowAt(0), pin = row.pinButton
    verify(!row.hot)
    mouseMove(row, 10, row.height / 2)
    verify(row.hot, "row is hot under the pointer")
    verify(!row.pinHovered)
    var p = pin.mapToItem(row, pin.width / 2, pin.height / 2)
    mouseMove(row, p.x, p.y)
    verify(row.hot, "row stays hot while the pointer is on the pin")
    verify(row.pinHovered, "the pin knows it is hovered")
    verify(pin.shown)
    mouseMove(row, 10, row.height / 2)
    verify(row.hot)
    verify(!row.pinHovered)
  }

  function test_status_colour_follows_tone() {
    var list = makeList({ okColor: "#00ff00", busyColor: "#ffff00", urgent: "#ff0000", dim: "#808080", sessions: [
      { shortId: "d", status: "done", startedAt: 4, prompt: "a" },
      { shortId: "t", status: "thinking", startedAt: 3, prompt: "b" },
      { shortId: "n", status: "needs-input", startedAt: 2, prompt: "c" },
      { shortId: "s", status: "stopped", startedAt: 1, prompt: "d" }
    ] })
    compare(String(list.rowAt(0).toneColor), "#ff0000")
    compare(String(list.rowAt(1).toneColor), "#00ff00")
    compare(String(list.rowAt(2).toneColor), "#ffff00")
    compare(String(list.rowAt(3).toneColor), "#808080")
  }

  function test_terminal_rows_show_their_origin() {
    var list = makeList({ sessions: [
      { shortId: "t", status: "done", startedAt: 2, prompt: "from a terminal", kind: "terminal" },
      { shortId: "v", status: "done", startedAt: 1, prompt: "from voice" }
    ] })
    verify(list.rowAt(0).kindGlyph !== "")
    verify(list.rowAt(0).kindGlyph !== list.rowAt(1).kindGlyph)
  }

  function test_user_text_is_never_rendered_as_markup() {
    // Prompts and replies are arbitrary text; Text.AutoText would interpret
    // anything that looks like HTML (tags stripped, remote images fetched).
    var list = makeList({ sessions: [
      { shortId: "m", status: "done", startedAt: 1, prompt: "<b>drop</b> the <table> tag",
        reply: "wrote <img src=\"http://x/y.png\"> to disk",
        results: [{ kind: "path", value: "/tmp/<b>odd</b>/file.txt" }] }
    ] })
    var row = list.rowAt(0)
    compare(row.promptFormat, Text.PlainText)
    compare(row.replyFormat, Text.PlainText)
    compare(row.chipAt(0).labelFormat, Text.PlainText)
    compare(row.promptText, "<b>drop</b> the <table> tag")
  }

  function test_rows_stay_put_when_pinned_until_the_list_is_reactivated() {
    var list = makeList({ sessions: [
      { shortId: "new1", status: "done", startedAt: 3, prompt: "newest" },
      { shortId: "mid2", status: "done", startedAt: 2, prompt: "middle" },
      { shortId: "old3", status: "done", startedAt: 1, prompt: "oldest" }
    ], active: false })
    list.active = true
    compare(list.rows.map(function(s) { return s.shortId }), ["new1", "mid2", "old3"])
    // The feed comes back with the oldest row pinned: sorted, it would be first.
    list.sessions = [
      { shortId: "new1", status: "done", startedAt: 3, prompt: "newest" },
      { shortId: "mid2", status: "done", startedAt: 2, prompt: "middle" },
      { shortId: "old3", status: "done", startedAt: 1, prompt: "oldest", pinned: true }
    ]
    compare(list.rows.map(function(s) { return s.shortId }), ["new1", "mid2", "old3"])
    verify(list.rowAt(2).pinned)
    // Unpinning again: still no movement.
    list.sessions = [
      { shortId: "new1", status: "done", startedAt: 3, prompt: "newest" },
      { shortId: "mid2", status: "done", startedAt: 2, prompt: "middle", pinned: true },
      { shortId: "old3", status: "done", startedAt: 1, prompt: "oldest" }
    ]
    compare(list.rows.map(function(s) { return s.shortId }), ["new1", "mid2", "old3"])
    // Closing and reopening the popover shows the sorted order.
    list.active = false
    list.active = true
    compare(list.rows.map(function(s) { return s.shortId }), ["mid2", "new1", "old3"])
  }

  function test_new_rows_go_on_top_while_open_and_forgotten_rows_drop_out() {
    var list = makeList({ sessions: [
      { shortId: "b", status: "done", startedAt: 2, prompt: "b" },
      { shortId: "a", status: "done", startedAt: 1, prompt: "a" }
    ], active: false })
    list.active = true
    list.sessions = [
      { shortId: "c", status: "thinking", startedAt: 3, prompt: "c" },
      { shortId: "b", status: "done", startedAt: 2, prompt: "b" }
    ]
    compare(list.rows.map(function(s) { return s.shortId }), ["c", "b"])
  }

  function test_rows_are_not_built_while_the_list_is_inactive() {
    // The popover's content tree stays mounted while it is closed, and the
    // feed is rewritten on every hook of every tracked session. Rebuilding
    // every row delegate when nobody can see them is pure cost.
    var list = makeList({ sessions: sessions(), active: false })
    compare(list.count, 3)
    verify(!list.rowAt(0))
    list.active = true
    verify(list.rowAt(0))
    compare(list.rowAt(0).shortId, "bbbb2222")
  }

  function test_reply_is_shown_as_stored() {
    // bin/voxclaude already turned the reply into prose; stripping it a
    // second time here would eat characters the reply meant to keep.
    var list = makeList({ sessions: [
      { shortId: "r", status: "done", startedAt: 1, prompt: "p", reply: "Use `npm test` **first**" }
    ] })
    compare(list.rowAt(0).replyText, "Use `npm test` **first**")
  }

  function test_empty_state() {
    var list = makeList({ sessions: [] })
    compare(list.count, 0)
    verify(list.emptyVisible)
  }

  // The hint names the key that is actually bound, not the one the README
  // happens to suggest.
  function test_empty_state_names_the_bound_key() {
    var list = makeList({ sessions: [], keybind: "Ctrl+Alt+Space" })
    verify(list.emptyText.indexOf("Ctrl+Alt+Space") >= 0)
    list.keybind = "Super+K"
    verify(list.emptyText.indexOf("Super+K") >= 0)
    list.keybind = ""
    verify(/[Bb]ind a key/.test(list.emptyText))
  }
}
