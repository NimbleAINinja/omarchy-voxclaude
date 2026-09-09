import QtQuick
import QtTest
import "../.." as Plugin

// FinishBlink.qml: the three green blinks the critter gives when a session
// finishes. Pure QtQuick, so it runs headlessly like the rest.
TestCase {
  id: suite
  name: "FinishBlink"
  when: windowShown

  Component {
    id: blinkComponent
    Plugin.FinishBlink { interval: 15 }
  }

  SignalSpy { id: spy }

  function makeBlink() {
    var b = createTemporaryObject(blinkComponent, suite)
    verify(b !== null)
    return b
  }

  function test_idle_until_triggered() {
    var b = makeBlink()
    verify(!b.running)
    verify(!b.lit)
  }

  function test_blinks_three_times_then_stops() {
    var b = makeBlink()
    spy.target = b
    spy.signalName = "litChanged"
    spy.clear()
    b.trigger()
    verify(b.lit)
    verify(b.running)
    tryVerify(function() { return !b.running }, 2000)
    verify(!b.lit)
    // lit on, off, on, off, on, off
    compare(spy.count, 6)
  }

  function test_a_second_finish_restarts_the_burst() {
    var b = makeBlink()
    b.trigger()
    tryVerify(function() { return !b.running }, 2000)
    b.trigger()
    verify(b.lit)
    verify(b.running)
  }
}
