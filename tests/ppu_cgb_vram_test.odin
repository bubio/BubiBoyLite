package tests

import "core:testing"
import core "bbl:core"

// T6-2: VRAM バンク切替(VBK)と BG 属性(バンク1のタイルマップ同アドレス)の単体テスト。
// DoD: 「VBK 切替で別データが読めること」「属性の flip がピクセルに反映されること」。
//
// T6-4以降、CGBモードのピクセル色はBGP(グレー4階調)ではなくパレットRAMから決まるため、
// このファイルのテストは検証用にBGパレット0を既知の原色(黒/赤/緑/青)へ設定してから
// 描画結果を比較する(setup_identity_bg_palette0参照)。

@(private = "file")
tick_one_line_cgb :: proc(bus: ^core.Bus) {
	core.bus_tick(bus, core.CYCLES_PER_LINE)
}

// setup_identity_bg_palette0 はBGパレット0の4色を color0=黒,1=赤,2=緑,3=青(RGB555の単色)に
// 設定する。BCPSのオートインクリメントを使って8バイト連続で書く(T6-4の機能を使う側のテストでも
// 活用する土台)。期待ARGB値は呼び出し側で core.rgb555系の定数の代わりに直接書く
// (0xFFRRGGBB、architecture.md固定の変換式 `(c<<3)|(c>>2)` で 31 は 0xFF になる)。
@(private = "file")
setup_identity_bg_palette0 :: proc(bus: ^core.Bus) {
	core.bus_write(bus, core.BCPS_ADDR, 0x80) // index0、オートインクリメント有効
	bytes := [8]u8{0x00, 0x00, 0x1F, 0x00, 0xE0, 0x03, 0x00, 0x7C}
	for b in bytes {
		core.bus_write(bus, core.BCPD_ADDR, b)
	}
}

@(private = "file")
CGB_PALETTE0_BLACK :: 0xFF000000
@(private = "file")
CGB_PALETTE0_RED :: 0xFFFF0000
@(private = "file")
CGB_PALETTE0_GREEN :: 0xFF00FF00
@(private = "file")
CGB_PALETTE0_BLUE :: 0xFF0000FF

@(test)
test_vbk_switches_vram_bank_for_cpu_access :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	// バンク0に0xAA、バンク1に0x55を同じCPUアドレス(0x8000)へ書く。
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	core.bus_write(&bus, 0x8000, 0xAA)
	core.bus_write(&bus, core.VBK_ADDR, 0x01)
	core.bus_write(&bus, 0x8000, 0x55)

	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	testing.expectf(t, core.bus_read(&bus, 0x8000) == 0xAA, "バンク0の値が読めるはず")
	testing.expectf(t, core.bus_read(&bus, core.VBK_ADDR) == 0xFE, "VBK読み出しは0xFE|bank, bank=0")

	core.bus_write(&bus, core.VBK_ADDR, 0x01)
	testing.expectf(t, core.bus_read(&bus, 0x8000) == 0x55, "バンク1の値が読めるはず")
	testing.expectf(t, core.bus_read(&bus, core.VBK_ADDR) == 0xFF, "VBK読み出しは0xFE|bank, bank=1")
}

@(test)
test_vbk_write_ignored_in_dmg_mode :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Dmg

	core.bus_write(&bus, 0x8000, 0xAA) // バンク0(固定)に書く
	core.bus_write(&bus, core.VBK_ADDR, 0x01) // DMGモードでは無視されるはず
	got := core.bus_read(&bus, 0x8000)
	testing.expectf(t, got == 0xAA, "DMGモードではVBK書き込みが無視されバンク0固定のはず, got=%02X", got)
	testing.expectf(t, core.bus_read(&bus, core.VBK_ADDR) == 0xFF, "DMGモードのVBK読み出しは未実装レジスタ扱いで0xFFのはず")
}

@(test)
test_cgb_bg_attribute_y_flip_reflected_in_pixel :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_identity_bg_palette0(&bus)

	// タイル0の row0 を color1(low=0xFF,high=0x00)、row7 を color3(low=0xFF,high=0xFF)にする
	// (バンク0のタイルデータ)。
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	core.bus_write(&bus, 0x8000, 0xFF) // row0 low
	core.bus_write(&bus, 0x8001, 0x00) // row0 high
	core.bus_write(&bus, 0x800E, 0xFF) // row7 low
	core.bus_write(&bus, 0x800F, 0xFF) // row7 high

	// バンク1(0x9800の同アドレス)にBG属性: bit6=Yフリップを立てる(パレット番号は0のまま)。
	core.bus_write(&bus, core.VBK_ADDR, 0x01)
	core.bus_write(&bus, 0x9800, 0x40) // Y flip

	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91) // LCD on, BG on, unsigned tile mode, map=0x9800

	tick_one_line_cgb(&bus)

	// Yフリップにより、LY=0はタイルのrow7(color3=青)を表示するはず。
	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == CGB_PALETTE0_BLUE, "Yフリップでrow7(color3=青)が見えるはず, got=%08X", got)
}

@(test)
test_cgb_bg_attribute_x_flip_reflected_in_pixel :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_identity_bg_palette0(&bus)

	// タイル0のrow0: 左端(bit7)をcolor1、右端(bit0)をcolor3にする。
	// low = 1000_0001, high = 0000_0001 => bit7:00(low1,high0)->color1, bit0:11->color3
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	core.bus_write(&bus, 0x8000, 0x81) // low: 1000 0001
	core.bus_write(&bus, 0x8001, 0x01) // high: 0000 0001

	// バンク1にBG属性: bit5=Xフリップを立てる。
	core.bus_write(&bus, core.VBK_ADDR, 0x01)
	core.bus_write(&bus, 0x9800, 0x20) // X flip

	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91)

	tick_one_line_cgb(&bus)

	// Xフリップにより、x=0(本来は左端=color1=赤)がフリップ後は右端(color3=青)になるはず。
	got0 := bus.ppu.framebuffer[0]
	testing.expectf(t, got0 == CGB_PALETTE0_BLUE, "Xフリップでx=0はcolor3(元の右端、青)のはず, got=%08X", got0)
	got7 := bus.ppu.framebuffer[7]
	testing.expectf(t, got7 == CGB_PALETTE0_RED, "Xフリップでx=7はcolor1(元の左端、赤)のはず, got=%08X", got7)
}

@(test)
test_cgb_bg_attribute_bank_selects_vram_bank_for_tile_data :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb
	setup_identity_bg_palette0(&bus)

	// バンク0のタイル0のrow0はcolor0のまま(何も書かない)。
	// バンク1のタイル0のrow0をcolor2にする(low=0x00,high=0xFF)。
	core.bus_write(&bus, core.VBK_ADDR, 0x01)
	core.bus_write(&bus, 0x8000, 0x00)
	core.bus_write(&bus, 0x8001, 0xFF)

	// BG属性(バンク1の0x9800)にbit3(タイルデータバンク=1)を立てる。
	core.bus_write(&bus, 0x9800, 0x08)

	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91)

	tick_one_line_cgb(&bus)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == CGB_PALETTE0_GREEN, "属性bit3でバンク1のタイルデータ(color2=緑)が読まれるはず, got=%08X", got)
}
