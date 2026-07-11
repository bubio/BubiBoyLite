package tests

import "core:testing"
import core "bbl:core"

// T3-5: スプライト描画の単体テスト。
// DoD: 10個制限、X優先度、透明色、8x16のtile indexマスクを検証する。

@(private = "file")
tick_one_full_line :: proc(bus: ^core.Bus) {
	core.bus_tick(bus, core.CYCLES_PER_LINE)
}

// oam_write は OAM エントリ(4バイト: Y, X, tile, attr)を書き込む共通ヘルパー。
@(private = "file")
oam_write_entry :: proc(bus: ^core.Bus, index: int, y, x, tile, attr: u8) {
	base := u16(0xFE00 + index * 4)
	core.bus_write(bus, base + 0, y)
	core.bus_write(bus, base + 1, x)
	core.bus_write(bus, base + 2, tile)
	core.bus_write(bus, base + 3, attr)
}

@(test)
test_ppu_sprite_transparency_and_basic_draw :: proc(t: ^testing.T) {
	bus: core.Bus

	// タイル1(unsigned、0x8000起点): 左4列がcolor3、右4列は透明(color0)。
	core.bus_write(&bus, 0x8000 + 1 * 16 + 0, 0xF0) // low: 1111 0000
	core.bus_write(&bus, 0x8000 + 1 * 16 + 1, 0xF0) // high: 1111 0000 => 左4列color3、右4列color0

	core.bus_write(&bus, core.OBP0_ADDR, 0xE4) // 恒等変換
	// LY=0にスプライトを置く(OAM Y=16 => 画面Y=0)、X=8+8=16(画面X=8)。
	oam_write_entry(&bus, 0, 16, 16, 1, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x83) // LCD on, BG off(bit0=0), OBJ on(bit1)
	tick_one_full_line(&bus)

	got_opaque := bus.ppu.framebuffer[8]
	testing.expectf(t, got_opaque == core.DMG_SHADE_3, "x=8: スプライトのcolor3が見えるはず, got=%08X", got_opaque)

	got_transparent := bus.ppu.framebuffer[12]
	testing.expectf(
		t,
		got_transparent == core.DMG_SHADE_0,
		"x=12: スプライトのcolor0(透明)なのでBG(白)が見えるはず, got=%08X",
		got_transparent,
	)
}

@(test)
test_ppu_sprite_x_priority_smaller_x_wins :: proc(t: ^testing.T) {
	bus: core.Bus

	// タイル1: 全列color1。タイル2: 全列color2。
	core.bus_write(&bus, 0x8000 + 1 * 16 + 0, 0xFF)
	core.bus_write(&bus, 0x8000 + 1 * 16 + 1, 0x00)
	core.bus_write(&bus, 0x8000 + 2 * 16 + 0, 0x00)
	core.bus_write(&bus, 0x8000 + 2 * 16 + 1, 0xFF)

	core.bus_write(&bus, core.OBP0_ADDR, 0xE4)

	// OAM順で先に来るのはindex0(タイル2、X=20=画面X12)、次にindex1(タイル1、X=16=画面X8)。
	// 画面X8-15(タイル1)とX12-19(タイル2)が重なる(X12-15)。
	// 重なり領域ではX優先度により画面X座標が小さいスプライト(タイル1、X=8始まり)が勝つ。
	oam_write_entry(&bus, 0, 16, 20, 2, 0x00) // 画面X=12、タイル2(color2)
	oam_write_entry(&bus, 1, 16, 16, 1, 0x00) // 画面X=8、タイル1(color1)

	core.bus_write(&bus, core.LCDC_ADDR, 0x83) // BG off, OBJ on
	tick_one_full_line(&bus)

	// x=12(重なり領域): X座標がより小さいスプライト(タイル1、画面X=8始まり)が勝つはず。
	got_overlap := bus.ppu.framebuffer[12]
	testing.expectf(
		t,
		got_overlap == core.DMG_SHADE_1,
		"x=12: X座標の小さいスプライト(タイル1,color1)が勝つはず, got=%08X",
		got_overlap,
	)

	// x=18(タイル2のみが覆う領域): タイル2(color2)が見えるはず。
	got_only2 := bus.ppu.framebuffer[18]
	testing.expectf(t, got_only2 == core.DMG_SHADE_2, "x=18: タイル2のみの領域, got=%08X", got_only2)
}

@(test)
test_ppu_sprite_line_limit_is_ten_by_oam_order :: proc(t: ^testing.T) {
	bus: core.Bus

	// タイル1: 全列color1。
	core.bus_write(&bus, 0x8000 + 1 * 16 + 0, 0xFF)
	core.bus_write(&bus, 0x8000 + 1 * 16 + 1, 0x00)
	// タイル2: 全列color2(11番目以降に使われるはずのタイル)。
	core.bus_write(&bus, 0x8000 + 2 * 16 + 0, 0x00)
	core.bus_write(&bus, 0x8000 + 2 * 16 + 1, 0xFF)

	core.bus_write(&bus, core.OBP0_ADDR, 0xE4)

	// OAM順で0-9番目(10個)を画面外X(X=0、つまり画面X=-8で完全に画面外)のタイル1で埋め、
	// 「画面外Xでも10個の枠を消費する」ことを検証する。
	for i in 0 ..< 10 {
		oam_write_entry(&bus, i, 16, 0, 1, 0x00) // X=0 => 画面X=-8(完全に画面外)
	}
	// 11番目(index10)は画面内(X=16=画面X8)のタイル2。10個の枠を使い切っているため
	// このラインには描画されないはず。
	oam_write_entry(&bus, 10, 16, 16, 2, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x83)
	tick_one_full_line(&bus)

	got := bus.ppu.framebuffer[8]
	testing.expectf(
		t,
		got == core.DMG_SHADE_0,
		"11番目のスプライトは10個制限で描画されないはず(白のまま), got=%08X",
		got,
	)
}

@(test)
test_ppu_sprite_8x16_tile_index_masks_low_bit :: proc(t: ^testing.T) {
	bus: core.Bus

	// 8x16モードでは奇数タイルindexの下位bitは無視される。タイルindex5(奇数)を指定しても
	// 実際にはタイル4(偶数、下位bitマスク後)の上半分、タイル5の下半分が使われる。
	// タイル4(上半分、row0-7): color1で埋める。
	core.bus_write(&bus, 0x8000 + 4 * 16 + 0, 0xFF)
	core.bus_write(&bus, 0x8000 + 4 * 16 + 1, 0x00)
	// タイル5(下半分、8x16の2枚目): color3で埋める。
	core.bus_write(&bus, 0x8000 + 5 * 16 + 0, 0xFF)
	core.bus_write(&bus, 0x8000 + 5 * 16 + 1, 0xFF)

	core.bus_write(&bus, core.OBP0_ADDR, 0xE4)
	// Y=16 => 画面Y=0-15の16行にまたがる8x16スプライト。tile indexは奇数の5を指定。
	oam_write_entry(&bus, 0, 16, 16, 5, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x87) // LCD on, BG off, OBJ on, OBJ size=8x16(bit2)

	tick_one_full_line(&bus) // LY=0(スプライト上半分、タイル4=color1)
	got_top := bus.ppu.framebuffer[8]
	testing.expectf(
		t,
		got_top == core.DMG_SHADE_1,
		"8x16スプライトの上半分(LY=0)は下位bitマスク後のタイル4(color1)のはず, got=%08X",
		got_top,
	)

	for _ in 0 ..< 8 {
		tick_one_full_line(&bus) // LY=1..8まで進める
	}
	got_bottom := bus.ppu.framebuffer[8 * core.SCREEN_WIDTH + 8]
	testing.expectf(
		t,
		got_bottom == core.DMG_SHADE_3,
		"8x16スプライトの下半分(LY=8)はタイル5(color3)のはず, got=%08X",
		got_bottom,
	)
}

@(test)
test_ppu_sprite_bg_priority_bit_hides_behind_opaque_bg :: proc(t: ^testing.T) {
	bus: core.Bus

	// BGタイル1(0x9800マップ、unsigned): 全列color2(不透明なBG)。
	core.bus_write(&bus, 0x8000 + 1 * 16 + 0, 0x00)
	core.bus_write(&bus, 0x8000 + 1 * 16 + 1, 0xFF)
	core.bus_write(&bus, 0x9800 + 0, 1) // tile(0,0) -> タイル1

	// スプライトタイル2: 全列color3。
	core.bus_write(&bus, 0x8000 + 2 * 16 + 0, 0xFF)
	core.bus_write(&bus, 0x8000 + 2 * 16 + 1, 0xFF)

	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	core.bus_write(&bus, core.OBP0_ADDR, 0xE4)

	// index0: attr bit7=1(BG優先)、X=8(画面X=0)。BGが不透明(color2)なのでスプライトは隠れる。
	oam_write_entry(&bus, 0, 16, 8, 2, core.OAM_ATTR_BG_PRIORITY)
	// index1: attr bit7=0、X=24(画面X=16)。同じBGだが通常優先度なのでスプライトが見える。
	oam_write_entry(&bus, 1, 16, 24, 2, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x91 | core.LCDC_BIT_OBJ_ENABLE) // LCD on, BG on, unsigned, OBJ on

	tick_one_full_line(&bus)

	got_hidden := bus.ppu.framebuffer[0]
	testing.expectf(
		t,
		got_hidden == core.DMG_SHADE_2,
		"attr bit7=1のスプライトはBGカラー1-3の上に描かれないはず(BGのcolor2が見える), got=%08X",
		got_hidden,
	)

	got_visible := bus.ppu.framebuffer[16]
	testing.expectf(
		t,
		got_visible == core.DMG_SHADE_3,
		"attr bit7=0のスプライトは通常どおりBGの上に描かれるはず(スプライトのcolor3), got=%08X",
		got_visible,
	)
}
