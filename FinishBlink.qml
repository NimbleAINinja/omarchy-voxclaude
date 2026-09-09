import QtQuick

// Three blinks when a session finishes, spread over three seconds. The bar
// critter flashes green, so a finished task registers from the corner of your
// eye even when the toast is off screen or you were looking elsewhere. The
// flash is colour only and leaves the eyes where they are.
//
// A blink is short and the look back at you is long, which is what makes it
// read as blinking rather than pulsing. Pure QtQuick: Panel.qml owns the
// colours, this owns the timing.
Item {
  id: root

  property int blinks: 3
  property int litMs: 250
  property int gapMs: 750
  readonly property int duration: blinks * (litMs + gapMs)

  // Phase 0 is the first blink, odd phases are the gaps after each one; -1 is
  // "nothing to celebrate".
  property int phase: -1
  readonly property bool running: phase >= 0
  readonly property bool lit: phase >= 0 && phase % 2 === 0

  function trigger() {
    phase = 0
    timer.interval = litMs
    timer.restart()
  }

  function stop() {
    phase = -1
    timer.stop()
  }

  Timer {
    id: timer
    interval: root.litMs
    repeat: true
    onTriggered: {
      // Step straight from the last gap to "nothing to celebrate": landing on
      // an even phase first would light the critter for one extra frame.
      var next = root.phase + 1
      if (next >= root.blinks * 2) { root.stop(); return }
      root.phase = next
      timer.interval = root.lit ? root.litMs : root.gapMs
    }
  }
}
