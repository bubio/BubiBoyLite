package tests

import "core:testing"
import core "bbl:core"

// T6-5: CGB の BG/OBJ 優先度制御の単体テスト。
// DoD: 「LCDC bit0=0でOBJ最前面」「BG属性bit7の勝ち」。加えてOAM属性bit7の勝ちと
// デフォルト(OBJ勝ち)、OAM順優先度(X座標無視)も検証する。
//
// 色の区別のため、BGパレット0のcolor1=赤、OBJパレット0のcolor1=緑に設定して使う
// (ppu_cgb_vram_test.odinと同じ考え方だが、このファイルは独立してヘルパーを持つ)。

@(private = "file")
tick_one_line_priority :: proc(bus: ^core.Bus) {
	core.bus_tick(bus, core.CYCLES_PER_LINE)
}

@(private = "file")
oam_write_entry_priority :: proc(bus: ^core.Bus, index: int, y, x, tile, attr: u8) {
	base := u16(0xFE00 + index * 4)
	core.bus_write(bus, base + 0, y)
	core.bus_write(bus, base + 1, x)
	core.bus_write(bus, base + 2, tile)
	core.bus_write(bus, base + 3, attr)
}

@(private = "file")
PRIORITY_TEST_RED :: 0xFFFF0000 // BGパレット0のcolor1
@(private = "file")
PRIORITY_TEST_GREEN :: 0xFF00FF00 // OBJパレット0のcolor1

// setup_bg_and_obj_palette0 は BG/OBJ 両方のパレット0を color1=赤/緑に設定する。
@(private = "file")
setup_bg_and_obj_palette0 :: proc(bus: ^core.Bus) {
	core.bus_write(bus, core.BCPS_ADDR, 0x82) // BGパレット0のcolor1(index2)から
	core.bus_write(bus, core.BCPD_ADDR, 0x1F) // raw低byte(R=31)
	core.bus_write(bus, core.BCPD_ADDR, 0x00) // raw高byte

	core.bus_write(bus, core.OCPS_ADDR, 0x82) // OBJパレット0のcolor1(index2)から
	core.bus_write(bus, core.OCPD_ADDR, 0xE0) // raw低byte(G=31 => low=0xE0)
	core.bus_write(bus, core.OCPD_ADDR, 0x03) // raw高byte
}

// setup_common_tiles_and_sprite はBGタイル0(row0全ピクセルcolor1)とスプライトタイル1
// (row0全ピクセルcolor1)を用意し、OAM index0にスプライトを置く(画面x=0-7を覆う)。
// bg_priority_bit/oam_priority_bit で各属性のbit7を制御する。
@(private = "file")
setup_common_tiles_and_sprite :: proc(bus: ^core.Bus, bg_priority_bit: bool, oam_priority_bit: bool) {
	// BGタイル0(0x8000)row0: color1(low=0xFF, high=0x00)。
	core.bus_write(bus, 0x8000, 0xFF)
	core.bus_write(bus, 0x8001, 0x00)

	// BG属性(バンク1の0x9800、タイルマップ(0,0)と同アドレス): bit7=bg_priority_bit。
	attr: u8 = 0
	if bg_priority_bit {
		attr = core.CGB_ATTR_BG_PRIORITY
	}
	core.bus_write(bus, core.VBK_ADDR, 0x01)
	core.bus_write(bus, 0x9800, attr)
	core.bus_write(bus, core.VBK_ADDR, 0x00)

	// スプライトタイル1(0x8010)row0: color1(low=0xFF, high=0x00)。
	core.bus_write(bus, 0x8010, 0xFF)
	core.bus_write(bus, 0x8011, 0x00)

	oam_attr: u8 = 0
	if oam_priority_bit {
		oam_attr |= core.OAM_ATTR_BG_PRIORITY
	}
	// OAM Y=16(画面y=0)、X=8(画面x=0)、tile=1。
	oam_write_entry_priority(bus, 0, 16, 8, 1, oam_attr)
}

@(test)
test_cgb_master_priority_off_forces_obj_on_top :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_bg_and_obj_palette0(&bus)
	// BG属性bit7・OAM属性bit7の両方を立てても、LCDC bit0=0(マスタープライオリティ無効)なら
	// OBJが常に勝つはず。
	setup_common_tiles_and_sprite(&bus, true, true)

	core.bus_write(&bus, core.LCDC_ADDR, 0x92) // LCD on, unsigned tile mode(bit4), bit0=0, OBJ on
	tick_one_line_priority(&bus)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == PRIORITY_TEST_GREEN, "LCDC bit0=0ならOBJが最前面(緑)のはず, got=%08X", got)
}

@(test)
test_cgb_bg_attribute_priority_wins_over_obj :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_bg_and_obj_palette0(&bus)
	setup_common_tiles_and_sprite(&bus, true, false) // BG属性bit7のみ

	core.bus_write(&bus, core.LCDC_ADDR, 0x93) // マスタープライオリティ有効(bit0=1)、unsigned tile mode(bit4)
	tick_one_line_priority(&bus)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == PRIORITY_TEST_RED, "BG属性bit7が立っていればBGが勝つ(赤)はず, got=%08X", got)
}

@(test)
test_cgb_oam_attribute_priority_wins_over_obj_when_bg_attribute_clear :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_bg_and_obj_palette0(&bus)
	setup_common_tiles_and_sprite(&bus, false, true) // OAM属性bit7のみ

	core.bus_write(&bus, core.LCDC_ADDR, 0x93) // unsigned tile mode(bit4)
	tick_one_line_priority(&bus)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == PRIORITY_TEST_RED, "BG属性bit7=0でもOAM属性bit7が立っていればBGが勝つ(赤)はず, got=%08X", got)
}

@(test)
test_cgb_obj_wins_when_neither_priority_bit_set :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_bg_and_obj_palette0(&bus)
	setup_common_tiles_and_sprite(&bus, false, false) // どちらも立てない

	core.bus_write(&bus, core.LCDC_ADDR, 0x93) // unsigned tile mode(bit4)
	tick_one_line_priority(&bus)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == PRIORITY_TEST_GREEN, "優先度ビットが両方0ならOBJが勝つ(緑)はず, got=%08X", got)
}

@(test)
test_cgb_sprite_priority_uses_oam_order_not_x_coordinate :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.OCPS_ADDR, 0x82) // OBJパレット0のcolor1(index2)から連続書き込み
	bytes := [4]u8{0x1F, 0x00, 0xE0, 0x03} // color1(赤、index2-3), color2(緑、index4-5)
	for b in bytes {
		core.bus_write(&bus, core.OCPD_ADDR, b)
	}

	// タイル1: 全ピクセルcolor1(赤)。タイル2: 全ピクセルcolor2(緑)。
	core.bus_write(&bus, 0x8010, 0xFF) // tile1 row0 low
	core.bus_write(&bus, 0x8011, 0x00) // tile1 row0 high (color1)
	core.bus_write(&bus, 0x8020, 0x00) // tile2 row0 low
	core.bus_write(&bus, 0x8021, 0xFF) // tile2 row0 high (color2)

	// OAM index0(先に描画されるはず): X=画面12(OAM X=20)、tile2(緑)。
	// OAM index1: X=画面8(OAM X=16、より小さいX)、tile1(赤)。
	// DMGならX優先度でindex1(x=8)が勝つが、CGBはOAM順優先度なのでindex0(x=12,緑)が勝つ。
	oam_write_entry_priority(&bus, 0, 16, 20, 2, 0x00)
	oam_write_entry_priority(&bus, 1, 16, 16, 1, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x83)
	tick_one_line_priority(&bus)

	// 重なり合う x=12..15(index0の描画範囲12-19とindex1の描画範囲8-15の共通部分)を確認。
	got := bus.ppu.framebuffer[12]
	testing.expectf(t, got == PRIORITY_TEST_GREEN, "CGBはOAM順優先度なのでindex0(緑)が重なりで勝つはず, got=%08X", got)
}
