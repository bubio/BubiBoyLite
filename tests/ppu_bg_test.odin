package tests

import "core:testing"
import core "bbl:core"

// T3-3: BG スキャンライン描画の単体テスト。
// DoD: VRAM に既知のタイルを書き、1ライン描画後の framebuffer ピクセルを検証
// (signed/unsigned 両モード、SCX ラップ)。

// tick_one_full_line は現在のラインを最後まで(456 T-cycle)進める共通ヘルパー。
// モード3→0遷移でppu_render_scanlineが呼ばれ、そのラインのframebufferが確定する。
@(private = "file")
tick_one_full_line :: proc(bus: ^core.Bus) {
	core.bus_tick(bus, core.CYCLES_PER_LINE)
}

@(test)
test_ppu_bg_unsigned_tile_mode :: proc(t: ^testing.T) {
	bus: core.Bus

	// タイル0(unsignedモードでは0x8000起点)の row0 を「カラー番号1」で埋める:
	// low=0xFF(全bit1), high=0x00 => color = low_bit|high_bit<<1 = 1
	core.bus_write(&bus, 0x8000, 0xFF)
	core.bus_write(&bus, 0x8001, 0x00)
	// タイルマップ(0x9800、デフォルト)のtile(0,0)は書かなければ0のままなのでタイル0を指す。

	core.bus_write(&bus, core.BGP_ADDR, 0xE4) // 恒等変換(color N -> shade N)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91) // LCD on, BG on, unsigned tile mode, map=0x9800

	tick_one_full_line(&bus)

	for x in 0 ..< 8 {
		got := bus.ppu.framebuffer[x]
		testing.expectf(
			t,
			got == core.DMG_SHADE_1,
			"x=%d: expected DMG_SHADE_1(color1), got=%08X",
			x,
			got,
		)
	}
}

@(test)
test_ppu_bg_scx_wraps_around_256 :: proc(t: ^testing.T) {
	bus: core.Bus

	// タイル1: row0 を color3 で埋める(low=0xFF, high=0xFF)
	core.bus_write(&bus, 0x8010, 0xFF)
	core.bus_write(&bus, 0x8011, 0xFF)
	// タイル2: row0 を color2 で埋める(low=0x00, high=0xFF)
	core.bus_write(&bus, 0x8020, 0x00)
	core.bus_write(&bus, 0x8021, 0xFF)

	// タイルマップ: tile_col=31(右端) にタイル1、tile_col=0(左端) にタイル2。
	core.bus_write(&bus, 0x9800 + 31, 1)
	core.bus_write(&bus, 0x9800 + 0, 2)

	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	core.bus_write(&bus, core.SCX_ADDR, 255)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91) // unsigned tile mode, map=0x9800

	tick_one_full_line(&bus)

	// x=0: source_x=(0+255)&0xFF=255 => tile_col=31 => タイル1(color3)
	got0 := bus.ppu.framebuffer[0]
	testing.expectf(t, got0 == core.DMG_SHADE_3, "x=0: SCXラップ前(tile_col31)はDMG_SHADE_3のはず、got=%08X", got0)

	// x=8: source_x=(8+255)&0xFF=7 => tile_col=0 => タイル2(color2)
	got8 := bus.ppu.framebuffer[8]
	testing.expectf(t, got8 == core.DMG_SHADE_2, "x=8: SCXラップ後(tile_col0)はDMG_SHADE_2のはず、got=%08X", got8)
}

@(test)
test_ppu_bg_signed_tile_mode :: proc(t: ^testing.T) {
	bus: core.Bus

	// signedモードでタイルインデックス0xFF(=-1)は 0x9000 + (-1)*16 = 0x8FF0 起点。
	// row0をcolor1で埋める(low=0xFF, high=0x00)。
	core.bus_write(&bus, 0x8FF0, 0xFF)
	core.bus_write(&bus, 0x8FF1, 0x00)
	core.bus_write(&bus, 0x9800 + 0, 0xFF) // tile(0,0) = インデックス0xFF(=-1)

	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	core.bus_write(&bus, core.LCDC_ADDR, 0x81) // LCD on, BG on, signed tile mode(bit4=0), map=0x9800

	tick_one_full_line(&bus)

	for x in 0 ..< 8 {
		got := bus.ppu.framebuffer[x]
		testing.expectf(
			t,
			got == core.DMG_SHADE_1,
			"signedモード x=%d: expected DMG_SHADE_1(color1), got=%08X",
			x,
			got,
		)
	}
}

@(test)
test_ppu_bg_disabled_is_white :: proc(t: ^testing.T) {
	bus: core.Bus

	// タイルにcolor3を仕込んでおいても、LCDC bit0=0ならBGは白一色になるべき。
	core.bus_write(&bus, 0x8000, 0xFF)
	core.bus_write(&bus, 0x8001, 0xFF)
	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	core.bus_write(&bus, core.LCDC_ADDR, 0x90) // LCD on, BG off(bit0=0)

	tick_one_full_line(&bus)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == core.DMG_SHADE_0, "LCDC bit0=0のときBGは白であるべき, got=%08X", got)
}
