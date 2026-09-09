import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// VoxClaude bar widget: one glyph that follows the voice pipeline
// (idle → listening → transcribing → thinking → needs-input) and a popover
// listing recent voice sessions to reattach. All state comes from files that
// bin/voxclaude writes under $XDG_RUNTIME_DIR/voxclaude.
Panel {
  id: root
  moduleName: "io.github.nimbleaininja.voxclaude"
  ipcTarget: "io.github.nimbleaininja.voxclaude"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color okColor: "#7bbf6a"
  // The finish blink fills the whole critter, so it wants a deeper green than
  // the status dots, which are 7px across and need the brightness to read.
  readonly property color blinkColor: "#40782f"
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/voxclaude"
  readonly property string tool: Qt.resolvedUrl("bin/voxclaude").toString().replace(/^file:\/\//, "")

  property string status: "idle"
  // The key the user actually bound, resolved by bin/voxclaude from Hyprland
  // (or the hypr config). Empty until it answers, and empty for good if no
  // bind exists, which the hint text says out loud.
  property string keybind: ""
  property var sessions: []
  property double nowMs: Date.now()
  // -1 until the feed has been read once, so a shell restart does not blink
  // for work that finished before it started.
  property double lastFinish: -1
  readonly property bool finishing: finishBlink.lit
  property int tick: 0

  readonly property var look: Model.glyphFor(status)
  readonly property color spriteColor: finishing ? blinkColor
                                     : look.urgent ? urgent : foreground
  // SessionList has already sorted them; sorting the same array again here
  // just to read its head is work for nothing.
  readonly property var latest: list.count > 0 ? list.rows[0] : null
  readonly property string tooltip: {
    var text = Model.statusLabel(status, keybind)
    if (latest && status !== "idle") {
      text += "\n" + Model.excerpt(latest.prompt, 80)
      if (latest.step) text += "\n" + Model.excerpt(latest.step, 80)
    }
    return text
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    statusFile.reload()
    feedFile.reload()
    keybindProc.running = true
  }

  function attach(shortId) {
    Quickshell.execDetached([root.tool, "attach", shortId || "latest"])
    root.close()
  }

  function openResult(value) {
    if (value === "") return
    Quickshell.execDetached([root.tool, "open", value])
    root.close()
  }

  function forget(shortId) {
    if (shortId === "") return
    Quickshell.execDetached([root.tool, "forget", shortId])
  }

  function pin(shortId) {
    if (shortId === "") return
    Quickshell.execDetached([root.tool, "pin", shortId])
  }

  onOpenedChanged: if (opened) { nowMs = Date.now(); refresh() }

  // Asked once at startup and again on every refresh, so rebinding the key
  // and reloading Hyprland is enough to correct the hint.
  Process {
    id: keybindProc
    command: [root.tool, "keybind"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.keybind = text.trim()
    }
  }

  // status is one word, rewritten atomically by bin/voxclaude.
  FileView {
    id: statusFile
    path: root.runtimeDir + "/status"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var word = text().trim()
      root.status = word.length ? word : "idle"
      if (root.status === "idle") root.tick = 0
    }
    onLoadFailed: root.status = "idle"
  }

  // sessions.json is rewritten atomically by bin/voxclaude on every change, so
  // progress lines land in the popover without polling.
  FileView {
    id: feedFile
    path: root.runtimeDir + "/sessions.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.sessions = Array.isArray(parsed) ? parsed : []
      } catch (error) {
        root.sessions = []
      }
      root.nowMs = Date.now()
      // Something finished since the last time the feed was written.
      var finish = Model.latestFinish(root.sessions)
      if (root.lastFinish >= 0 && finish > root.lastFinish) finishBlink.trigger()
      root.lastFinish = finish
    }
    onLoadFailed: root.sessions = []
  }

  // Three green blinks when a session finishes.
  FinishBlink { id: finishBlink }

  // Keep "4m" and "2m ago" honest while the popover sits open.
  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Sprite animation: only ticks while there is something to animate.
  Timer {
    interval: Math.max(50, Model.spriteInterval(root.status))
    running: Model.spriteInterval(root.status) > 0
    repeat: true
    onTriggered: root.tick = (root.tick + 1) % 1000
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function attach(): string { root.attach("latest"); return "ok" }
    function status(): string { return root.status }
    function keybind(): string { return root.keybind }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.look.urgent
    tooltipText: root.tooltip
    // The icon canvas is 16px; the critter is 9x8 cells in a 14x12 box
    // (1.5px cells on a 2x screen, 4/3 on 3x), close to the width of the
    // glyph icons beside it.
    iconComponent: Component {
      Item {
        id: iconSlot
        anchors.fill: parent
        PixelSprite {
          id: barSprite
          width: 14
          height: 12
          // Centred by hand rather than by anchor: an odd icon canvas would
          // otherwise put the sprite on a half pixel and undo its own snapping.
          x: Math.round((iconSlot.width - width) / 2 * dpr) / dpr
          y: Math.round((iconSlot.height - height) / 2 * dpr) / dpr
          // The flash is colour only: the critter's eyes are unlit cells, so
          // borrowing the eyes-shut frame for it filled them in.
          frame: Model.spriteFrame(root.status, root.tick)
          color: root.spriteColor
          opacity: root.status === "idle" && !root.finishing ? 0.85 : 1
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.attach("latest")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        list.moveCursor(dy)
        var row = list.rowAt(list.cursor)
        if (row) panelFlick.contentY = Math.max(0, Math.min(row.y + list.y - Style.space(8),
                                                          Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }
      onActivateRequested: root.attach(list.cursorId() || "latest")
      onDeleteRequested: root.forget(list.cursorId())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "p" || t === "P") root.pin(list.cursorId())
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "VoxClaude"
          meta: Model.statusLabel(root.status, root.keybind)
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            PixelSprite {
              width: Style.font.display * 1.15
              height: Style.font.display
              // The hero stays mounted while the popover is closed, so only
              // follow the animation tick when someone can see it.
              frame: root.opened ? Model.spriteFrame(root.status, root.tick)
                                 : Model.spriteFrame(root.status, 0)
              color: root.spriteColor
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          width: parent.width
          text: "RECENT"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        SessionList {
          id: list
          width: parent.width
          sessions: root.sessions
          active: root.opened
          keybind: root.keybind
          nowMs: root.nowMs
          foreground: root.foreground
          dim: root.dim
          urgent: root.urgent
          okColor: root.okColor
          busyColor: "#d9b44a"
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          captionSize: Style.font.caption
          rowHeight: Style.space(40)
          radius: Style.cornerRadius
          onAttachRequested: function(shortId) { root.attach(shortId) }
          onOpenRequested: function(value) { root.openResult(value) }
          onForgetRequested: function(shortId) { root.forget(shortId) }
          onPinRequested: function(shortId) { root.pin(shortId) }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Click a row to open it in a terminal, done or not. Chips open the result. Hover a row to pin it (p); right-click or Delete forgets it. Say “terminal” to start Claude in a window instead."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
      }
    }
  }
}
