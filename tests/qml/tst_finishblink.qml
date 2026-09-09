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
    // Sped up so the suite does not sit through three real seconds.
    Plugin.FinishBlink { litMs: 60; gapMs: 200 }
  }

  Component {
    id: defaultComponent
    Plugin.FinishBlink {}
  }

  SignalSpy { id: spy }

  function makeBlink() {
    var b = createTemporaryObject(blinkComponent, suite)
    verify(b !== null)
    return b
  }

  // Three blinks spread over three seconds: a short shut-eye, then a long look
  // back at you, three times over.
  function test_the_burst_is_three_blinks_across_three_seconds() {
    var b = createTemporaryObject(defaultComponent, suite)
    verify(b !== null)
    compare(b.blinks, 3)
    compare(b.duration, 3000)
    verify(b.gapMs > b.litMs)
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

  // The gaps are really waited out: a burst takes about as long as it says,
  // not the three quick flashes you would get if every phase were a blink.
  function test_the_burst_lasts_about_as_long_as_it_says() {
    var b = makeBlink()
    var t0 = Date.now()
    b.trigger()
    tryVerify(function() { return !b.running }, 4000)
    var took = Date.now() - t0
    verify(took >= b.duration * 0.7)
    verify(took <= b.duration * 2)
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
