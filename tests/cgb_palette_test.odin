package tests

import "core:testing"
import core "bbl:core"

// T6-4: CGB パレットRAM(BCPS/BCPD, OCPS/OCPD)の単体テスト。
// DoD: BCPSオートインクリメント、RGB555→ARGB変換値、パレット別描画。

@(test)
test_bcps_autoincrement_advances_on_write_only :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.BCPS_ADDR, 0x80) // index0、オートインクリメント有効
	testing.expectf(t, core.bus_read(&bus, core.BCPS_ADDR) == 0xC0, "書込み直後のBCPSはbit7維持+bit6=1+index0のはず, got=%02X", core.bus_read(&bus, core.BCPS_ADDR))

	core.bus_write(&bus, core.BCPD_ADDR, 0x11) // データ書込みでインデックスが進む
	testing.expectf(t, core.bus_read(&bus, core.BCPS_ADDR) == 0xC1, "BCPD書込み後はindexが1進むはず, got=%02X", core.bus_read(&bus, core.BCPS_ADDR))

	// 読み出しではインデックスは進まない(落とし穴)。
	_ = core.bus_read(&bus, core.BCPD_ADDR)
	_ = core.bus_read(&bus, core.BCPD_ADDR)
	testing.expectf(t, core.bus_read(&bus, core.BCPS_ADDR) == 0xC1, "BCPD読み出しではindexが進まないはず, got=%02X", core.bus_read(&bus, core.BCPS_ADDR))
}

@(test)
test_bcps_autoincrement_disabled_when_bit7_clear :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.BCPS_ADDR, 0x05) // bit7=0、index5
	core.bus_write(&bus, core.BCPD_ADDR, 0x22)
	testing.expectf(t, core.bus_read(&bus, core.BCPS_ADDR) == 0x45, "bit7=0のときはindexが進まないはず(bit6は常に1), got=%02X", core.bus_read(&bus, core.BCPS_ADDR))
}

@(test)
test_bcps_autoincrement_wraps_at_64 :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.BCPS_ADDR, 0xBF) // bit7=1、index=0x3F(63、最終インデックス)
	core.bus_write(&bus, core.BCPD_ADDR, 0x01)
	testing.expectf(t, core.bus_read(&bus, core.BCPS_ADDR) == 0xC0, "index63から1進むと0にラップするはず, got=%02X", core.bus_read(&bus, core.BCPS_ADDR))
}

@(test)
test_ocps_ocpd_independent_from_bcps_bcpd :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.BCPS_ADDR, 0x80)
	core.bus_write(&bus, core.BCPD_ADDR, 0xAA)
	core.bus_write(&bus, core.OCPS_ADDR, 0x80)
	core.bus_write(&bus, core.OCPD_ADDR, 0x55)

	core.bus_write(&bus, core.BCPS_ADDR, 0x00)
	core.bus_write(&bus, core.OCPS_ADDR, 0x00)
	testing.expectf(t, core.bus_read(&bus, core.BCPD_ADDR) == 0xAA, "BGパレットRAMとOBJパレットRAMは別領域のはず")
	testing.expectf(t, core.bus_read(&bus, core.OCPD_ADDR) == 0x55, "BGパレットRAMとOBJパレットRAMは別領域のはず")
}

@(test)
test_bcps_bcpd_ignored_in_dmg_mode :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Dmg

	core.bus_write(&bus, core.BCPS_ADDR, 0x80)
	core.bus_write(&bus, core.BCPD_ADDR, 0x99)
	testing.expectf(t, core.bus_read(&bus, core.BCPS_ADDR) == 0xFF, "DMGモードのBCPS読み出しは未実装レジスタ扱いで0xFFのはず")
	testing.expectf(t, core.bus_read(&bus, core.BCPD_ADDR) == 0xFF, "DMGモードのBCPD読み出しは未実装レジスタ扱いで0xFFのはず")
}

@(test)
test_cgb_palette_color_rgb555_boundary_values :: proc(t: ^testing.T) {
	// architecture.md固定の変換式 (c<<3)|(c>>2): raw 0x7FFF(全bit1)は各チャンネル31 -> 0xFF、
	// raw 0x001F(R=31のみ)は赤のみ0xFFで他0。パレットRAM経由でPPU描画結果として確認する
	// (BG属性は書かずパレット番号0、タイル0のcolor1で検証)。
	bus: core.Bus
	bus.mode = .Cgb

	// BGパレット0のcolor1(index2-3)へ raw=0x7FFF を書く。
	core.bus_write(&bus, core.BCPS_ADDR, 0x82) // index2、オートインクリメント有効
	core.bus_write(&bus, core.BCPD_ADDR, 0xFF) // low
	core.bus_write(&bus, core.BCPD_ADDR, 0x7F) // high

	// タイル0 row0 を全ピクセルcolor1にする(low=0xFF, high=0x00)。
	core.bus_write(&bus, 0x8000, 0xFF)
	core.bus_write(&bus, 0x8001, 0x00)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91)

	core.bus_tick(&bus, core.CYCLES_PER_LINE)

	got := bus.ppu.framebuffer[0]
	testing.expectf(t, got == 0xFFFFFFFF, "raw 0x7FFFは白(0xFFFFFFFF)になるはず, got=%08X", got)
}
