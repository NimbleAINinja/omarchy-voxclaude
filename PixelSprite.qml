import QtQuick
import QtQuick.Window
import "Model.js" as Model

// Pixel-art frame renderer: `frame` is a list of equal-length strings where
// "." is empty and any other character is a painted cell. Cells paint in
// `color` unless `palette` maps their character to another colour (the
// laptop critter's shading, eyes and laptop). Cell size and origin are snapped to whole device pixels
// (not logical pixels), so on a 2x screen a 1.5px cell is exactly 3 device
// pixels and the critter stays crisp at bar scale.
//
// The grid is one delegate per cell, not one per lit pixel, so swapping
// frames only toggles `visible` on existing Rectangles instead of tearing
// the whole grid down and rebuilding it on every animation tick.
Item {
  id: root

  property var frame: []
  property color color: "#cacccc"
  // Character → colour overrides, e.g. ({ S: "#b86848", E: "#000000" }).
  property var palette: ({})
  property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1

  readonly property int rows: frame ? frame.length : 0
  readonly property int columns: rows > 0 ? String(frame[0]).length : 0
  readonly property real cell: rows > 0 && columns > 0
    ? Math.max(1 / dpr, Math.floor(Math.min(width / columns, height / rows) * dpr) / dpr)
    : 1
  readonly property real gridWidth: columns * cell
  readonly property real gridHeight: rows * cell
  readonly property real originX: Math.round((width - gridWidth) / 2 * dpr) / dpr
  readonly property real originY: Math.round((height - gridHeight) / 2 * dpr) / dpr
  readonly property int cellCount: Model.litCount(frame)
  readonly property int delegateCount: rows * columns

  function cellAt(row, column) {
    var line = frame && frame[row]
    return line === undefined ? "." : String(line).charAt(column)
  }

  function lit(row, column) {
    return Model.isLit(cellAt(row, column))
  }

  function colorFor(ch) {
    var override = palette ? palette[ch] : undefined
    return override === undefined ? color : override
  }

  function delegateAt(index) { return cells.itemAt(index) }

  Item {
    x: root.originX
    y: root.originY
    width: root.gridWidth
    height: root.gridHeight

    Repeater {
      id: cells
      model: root.delegateCount

      Rectangle {
        required property int index
        readonly property int column: root.columns > 0 ? index % root.columns : 0
        readonly property int row: root.columns > 0 ? Math.floor(index / root.columns) : 0

        x: column * root.cell
        y: row * root.cell
        width: root.cell
        height: root.cell
        readonly property string cell: root.cellAt(row, column)
        color: root.colorFor(cell)
        visible: Model.isLit(cell)
        antialiasing: false
      }
    }
  }
}
