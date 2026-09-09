import QtQuick

// Three blinks when a session finishes. The bar critter shuts its eyes and
// goes green, so a finished task registers from the corner of your eye even
// when the toast is off screen or you were looking elsewhere.
//
// Pure QtQuick: Panel.qml owns the colours, this owns the timing.
Item {
  id: root

  property int blinks: 3
  property int interval: 160

  // Phase 0 is the first blink, odd phases are the gaps between them; -1 is
  // "nothing to celebrate".
  property int phase: -1
  readonly property bool running: phase >= 0
  readonly property bool lit: phase >= 0 && phase % 2 === 0

  function trigger() {
    phase = 0
    timer.restart()
  }

  function stop() {
    phase = -1
    timer.stop()
  }

  Timer {
    id: timer
    interval: root.interval
    repeat: true
    onTriggered: {
      // Step straight from the last gap to "nothing to celebrate": landing on
      // an even phase first would light the critter for one extra frame.
      var next = root.phase + 1
      if (next >= root.blinks * 2) root.stop()
      else root.phase = next
    }
  }
}
