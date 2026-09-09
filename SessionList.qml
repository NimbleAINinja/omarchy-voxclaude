import QtQuick
import "Model.js" as Model

// Recent voice sessions, needs-input first then newest first. Pure QtQuick so
// tests can drive it headlessly; Panel.qml supplies colours and fonts.
//
// Each row: prompt, a subtitle (status · elapsed · current step, or status ·
// finished-ago), the reply excerpt once done, and one chip per result found in
// the reply. Click a row to open it in a terminal, right-click to forget it,
// click a chip to open that URL or file.
Column {
  id: root

  property var sessions: []
  property double nowMs: Date.now()
  property int maxRows: 8
  property int cursor: -1
  property color foreground: "#cacccc"
  property color dim: "#8a8c8c"
  property color urgent: "#a55555"
  property color okColor: "#7bbf6a"
  property color busyColor: "#d9b44a"
  property string fontFamily: ""
  property real fontSize: 13
  property real captionSize: 11
  property real rowHeight: 40
  property real radius: 6
  // The feed is rewritten on every hook of every tracked session, and a
  // Repeater over a plain array rebuilds every delegate when it changes.
  // Panel.qml turns this off while the popover is closed.
  property bool active: true
  // Panel.qml passes the key bin/voxclaude resolved; empty means none is bound.
  property string keybind: ""
  property string emptyText: Model.emptyHint(keybind)

  signal attachRequested(string shortId)
  signal openRequested(string value)
  signal forgetRequested(string shortId)
  signal pinRequested(string shortId)

  readonly property string pinGlyph: String.fromCodePoint(0xF0403)     // nf-md-pin

  readonly property var rows: Model.sortSessions(Model.visibleSessions(sessions)).slice(0, maxRows)
  readonly property int count: rows.length
  readonly property bool emptyVisible: count === 0

  function rowAt(index) { return repeater.itemAt(index) }
  function moveCursor(delta) {
    if (count === 0) { cursor = -1; return }
    cursor = Math.max(0, Math.min(count - 1, cursor + delta))
  }
  function cursorId() {
    return cursor >= 0 && cursor < count ? String(rows[cursor].shortId || "") : ""
  }

  onRowsChanged: if (cursor >= count) cursor = count - 1

  spacing: 4

  Text {
    textFormat: Text.PlainText
    visible: root.emptyVisible
    width: parent.width
    text: root.emptyText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    wrapMode: Text.WordWrap
  }

  Repeater {
    id: repeater
    model: root.active ? root.rows : []

    Item {
      id: row
      required property var modelData
      required property int index

      readonly property string shortId: String(modelData.shortId || "")
      readonly property string status: String(modelData.status || "")
      readonly property string promptText: Model.excerpt(modelData.prompt, 140)
      readonly property string statusText: Model.statusLabel(status)
      readonly property string timeText: Model.relativeTime(modelData.startedAt, root.nowMs)
      readonly property string subtitleText: Model.rowSubtitle(modelData, root.nowMs)
      readonly property string stepText: Model.rowStep(modelData)
      readonly property bool stepVisible: stepLabel.visible
      readonly property real stepX: stepLabel.x
      readonly property real stepY: stepLabel.y
      readonly property real statusY: statusRow.y
      // bin/voxclaude stores the reply as prose already; stripping markdown a
      // second time here would only eat characters it meant to keep.
      readonly property string replyText: status === "done" ? Model.excerpt(modelData.reply, 160) : ""
      readonly property var results: Model.toList(modelData.results) || []
      readonly property int chipCount: results.length
      readonly property bool needsInput: status === "needs-input"
      readonly property string tone: Model.statusTone(status)
      readonly property color toneColor: tone === "ok" ? root.okColor
                                       : tone === "busy" ? root.busyColor
                                       : tone === "alert" ? root.urgent : root.dim
      readonly property string kindGlyph: Model.kindGlyph(modelData.kind)
      readonly property bool pinned: !!modelData.pinned
      readonly property bool hasCursor: index === root.cursor
      readonly property bool hot: hover.containsMouse || hasCursor
      // The pin's hover is derived from the row's own pointer position
      // instead of a second hover-enabled MouseArea on top. A nested one
      // took the hover away from the row, which dropped the highlight and
      // hid the pin, which handed the hover back, which showed it again:
      // a flicker for as long as the pointer sat on the pin.
      readonly property bool pinHovered: hover.containsMouse
        && pinButton.contains(pinButton.mapFromItem(hover, hover.mouseX, hover.mouseY))
      readonly property int promptFormat: promptLabel.textFormat
      readonly property int replyFormat: replyLabel.textFormat
      property alias pinButton: pinButton
      readonly property real promptWidth: promptLabel.width

      function chipAt(i) { return chipRepeater.itemAt(i) }

      width: parent.width
      height: Math.max(root.rowHeight, content.implicitHeight + 12)

      Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: hover.containsMouse || row.hasCursor
          ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
        border.width: row.needsInput ? 1 : 0
        border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.6)
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.forgetRequested(row.shortId)
          else root.attachRequested(row.shortId)
        }
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 2

        Item {
          width: parent.width
          height: promptLabel.implicitHeight

          Text {
            id: promptLabel
            // Prompts and replies are arbitrary text: Text.AutoText would
            // treat anything tag-shaped as rich text and even fetch remote
            // images, so every user-supplied string is rendered verbatim.
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: pinButton.left
            anchors.rightMargin: 6
            text: row.promptText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }

          // The pin's slot is always laid out; only the glyph fades in on hover
          // (or keyboard cursor) and stays once set, so the prompt never reflows.
          // Forgetting a row is right-click or Delete; the row itself opens.
          HoverAction {
            id: pinButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            shown: row.hot || row.pinned
            hovered: row.pinHovered
            glyph: root.pinGlyph
            tint: row.pinned ? root.foreground : root.dim
            tip: row.pinned ? "Unpin" : "Pin to the top"
            onTriggered: root.pinRequested(row.shortId)
          }
        }

        // Status dot and word in the tone colour, the rest of the line dim.
        Row {
          id: statusRow
          width: parent.width
          spacing: 5

          Text {
            text: row.kindGlyph
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.captionSize
            anchors.verticalCenter: parent.verticalCenter
          }

          Rectangle {
            width: 7
            height: 7
            radius: 3.5
            color: row.toneColor
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            width: parent.width - 12 - root.captionSize - 5
            textFormat: Text.StyledText
            text: "<font color=\"" + row.toneColor + "\">" + Model.escapeHtml(row.statusText) + "</font>"
                  + Model.escapeHtml(row.subtitleText.slice(row.statusText.length))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.captionSize
            elide: Text.ElideRight
          }
        }

        // Indented to start under the status word rather than the kind glyph,
        // with the same arithmetic the status line uses for its own width.
        Text {
          id: stepLabel
          textFormat: Text.PlainText
          visible: row.stepText !== ""
          x: root.captionSize + 17
          width: parent.width - x
          text: row.stepText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.captionSize
          elide: Text.ElideRight
        }

        Text {
          id: replyLabel
          textFormat: Text.PlainText
          visible: row.replyText !== ""
          width: parent.width
          text: row.replyText
          color: root.foreground
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: root.captionSize
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Flow {
          visible: row.chipCount > 0
          width: parent.width
          spacing: 4

          Repeater {
            id: chipRepeater
            model: row.results

            Rectangle {
              id: chip
              required property var modelData
              readonly property string value: String(modelData.value || "")
              readonly property string label: Model.resultLabel(modelData)
              readonly property int labelFormat: chipLabel.textFormat

              width: chipLabel.implicitWidth + 14
              height: chipLabel.implicitHeight + 6
              radius: height / 2
              color: chipHover.containsMouse
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

              Text {
                id: chipLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: (chip.modelData.kind === "url" ? "🌐 " : "📄 ") + chip.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.captionSize
              }

              MouseArea {
                id: chipHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openRequested(chip.value)
              }
            }
          }
        }
      }
    }
  }

  // A small clickable glyph; swallows its click so the row underneath does
  // not open. `tip` is exposed for tooltips; the list itself draws none.
  // The hit box is a good deal larger than the glyph, which is about 13px
  // across; the owner says when it is hovered (see pinHovered).
  component HoverAction: Item {
    id: action
    property string glyph: ""
    property color tint: root.dim
    property string tip: ""
    property bool shown: true
    property bool hovered: false
    signal triggered()

    width: Math.max(28, actionLabel.implicitWidth + 6)
    height: Math.max(24, actionLabel.implicitHeight)

    Text {
      id: actionLabel
      anchors.centerIn: parent
      text: action.glyph
      opacity: action.shown ? 1 : 0
      color: action.hovered ? root.foreground : action.tint
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // Clicks only: with hover left to the row's MouseArea, the row stays
    // highlighted while the pointer is on the pin.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: false
      enabled: action.shown
      cursorShape: action.shown ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: action.triggered()
    }
  }
}
