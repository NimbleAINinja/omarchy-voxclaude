import QtQuick
import QtTest
import "../.." as Plugin
import "../../Model.js" as Model

TestCase {
  id: suite
  name: "PixelSprite"
  width: 100
  height: 100
  when: windowShown
  visible: true

  Component {
    id: spriteComponent
    Plugin.PixelSprite { width: 26; height: 16 }
  }

  function test_draws_one_cell_per_lit_pixel() {
    var sprite = createTemporaryObject(spriteComponent, suite, { frame: ["X.X", ".X."] })
    verify(sprite !== null)
    compare(sprite.cellCount, 3)
    compare(sprite.columns, 3)
    compare(sprite.rows, 2)
  }

  function test_cells_snap_to_device_pixels() {
    // 14x12 box, 9x8 grid: 1.5 logical px per cell on a 2x screen (3 device px),
    // 4/3 on a 3x screen (4 device px), whole pixels on a 1x screen.
    var sprite = createTemporaryObject(spriteComponent, suite, { frame: Model.SPRITE_FRAMES.idle, width: 14, height: 12, dpr: 2 })
    compare(sprite.columns, 9)
    compare(sprite.cell, 1.5)
    // Counted, not collected: cellCount is re-evaluated on every animation
    // tick, so it must not allocate a list of pixel objects to do it.
    compare(sprite.cellCount, Model.litCount(Model.SPRITE_FRAMES.idle))
    var hidpi = createTemporaryObject(spriteComponent, suite, { frame: Model.SPRITE_FRAMES.idle, width: 14, height: 12, dpr: 3 })
    fuzzyCompare(hidpi.cell, 4 / 3, 0.001)
    var coarse = createTemporaryObject(spriteComponent, suite, { frame: Model.SPRITE_FRAMES.idle, width: 14, height: 12, dpr: 1 })
    compare(coarse.cell, 1)
  }

  function test_origin_lands_on_a_device_pixel() {
    var sprite = createTemporaryObject(spriteComponent, suite, { frame: Model.SPRITE_FRAMES.idle, width: 16, height: 16, dpr: 2 })
    var ox = sprite.originX * sprite.dpr, oy = sprite.originY * sprite.dpr
    compare(ox, Math.round(ox))
    compare(oy, Math.round(oy))
  }

  function test_frame_swap_changes_lit_cells() {
    var sprite = createTemporaryObject(spriteComponent, suite, { frame: Model.SPRITE_FRAMES.idle })
    var before = sprite.cellCount
    sprite.frame = Model.SPRITE_FRAMES.busyA
    verify(sprite.cellCount !== before)
  }

  function test_frame_swap_reuses_the_same_delegates() {
    // Animation must not tear down and rebuild the grid on every tick.
    var sprite = createTemporaryObject(spriteComponent, suite, { frame: Model.SPRITE_FRAMES.idle, width: 14, height: 12 })
    compare(sprite.delegateCount, sprite.rows * sprite.columns)
    var first = sprite.delegateAt(0)
    verify(first !== null)
    sprite.frame = Model.SPRITE_FRAMES.busyA
    compare(sprite.delegateCount, sprite.rows * sprite.columns)
    compare(sprite.delegateAt(0), first)
  }

  function test_lit_cells_are_the_visible_ones() {
    var sprite = createTemporaryObject(spriteComponent, suite, { frame: ["X.", ".X"], width: 8, height: 8 })
    compare(sprite.delegateCount, 4)
    verify(sprite.delegateAt(0).visible)
    verify(!sprite.delegateAt(1).visible)
    verify(!sprite.delegateAt(2).visible)
    verify(sprite.delegateAt(3).visible)
  }
}
