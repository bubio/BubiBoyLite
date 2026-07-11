package tests

import "core:testing"
import core "bbl:core"

// T3-1: LCD レジスタ群の読み書きマスクを検証する。
// モードタイミング(T3-2以降)はここではまだ扱わない。

@(test)
test_ppu_register_roundtrip :: proc(t: ^testing.T) {
	bus: core.Bus

	core.bus_write(&bus, core.LCDC_ADDR, 0x91)
	testing.expect(t, core.bus_read(&bus, core.LCDC_ADDR) == 0x91)

	core.bus_write(&bus, core.SCY_ADDR, 0x12)
	testing.expect(t, core.bus_read(&bus, core.SCY_ADDR) == 0x12)

	core.bus_write(&bus, core.SCX_ADDR, 0x34)
	testing.expect(t, core.bus_read(&bus, core.SCX_ADDR) == 0x34)

	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	testing.expect(t, core.bus_read(&bus, core.BGP_ADDR) == 0xE4)

	core.bus_write(&bus, core.OBP0_ADDR, 0xD2)
	testing.expect(t, core.bus_read(&bus, core.OBP0_ADDR) == 0xD2)

	core.bus_write(&bus, core.OBP1_ADDR, 0xD3)
	testing.expect(t, core.bus_read(&bus, core.OBP1_ADDR) == 0xD3)

	core.bus_write(&bus, core.WY_ADDR, 0x10)
	testing.expect(t, core.bus_read(&bus, core.WY_ADDR) == 0x10)

	core.bus_write(&bus, core.WX_ADDR, 0x27)
	testing.expect(t, core.bus_read(&bus, core.WX_ADDR) == 0x27)
}

@(test)
test_ppu_ly_write_ignored :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.LY_ADDR, 0x50)
	testing.expectf(
		t,
		core.bus_read(&bus, core.LY_ADDR) == 0,
		"LY への書き込みは無視されるべき(リセットではない)",
	)
}

@(test)
test_ppu_stat_bit7_and_writable_mask :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.STAT_ADDR, 0xFF)
	got := core.bus_read(&bus, core.STAT_ADDR)
	// bit7は常に1、bit6-3は書き込みどおり1。bit2(LYC==LY)はLYC書き込み時にのみ再評価される
	// ため、LYCへ一度も書いていないこの時点では初期値false(この単体テストの対象外)。
	// bit1-0(モード、初期HBlank=0)は0 => 0x80|0x78|0 = 0xF8
	testing.expectf(
		t,
		got == 0xF8,
		"STAT read = %02X, expected 0xF8 (bit7固定1, bit6-3書込反映, bit2/bit1-0はPPU管理でこの時点では初期値)",
		got,
	)
}

@(test)
test_ppu_stat_write_does_not_affect_mode_or_lyc_bits :: proc(t: ^testing.T) {
	bus: core.Bus
	// LYC を LY(初期値0)と不一致にしておき、STAT へ 0x00 を書いても
	// bit2/bit1-0 は PPU 管理のまま変化しないことを確認する。
	core.bus_write(&bus, core.LYC_ADDR, 0x99)
	core.bus_write(&bus, core.STAT_ADDR, 0x00)
	got := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, got & 0x04 == 0, "LYC(0x99)!=LY(0)なのでSTAT bit2は立たないべき: got=%02X", got)
	testing.expectf(t, got & 0x80 != 0, "STAT bit7は常に1であるべき: got=%02X", got)
}

@(test)
test_ppu_lyc_equal_flag :: proc(t: ^testing.T) {
	bus: core.Bus
	// LY=0(初期値)のとき LYC=0 を書くと一致フラグ(STAT bit2)が立つ。
	core.bus_write(&bus, core.LYC_ADDR, 0x00)
	got := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, got & 0x04 != 0, "LYC==LY のとき STAT bit2 が立つべき: got=%02X", got)

	core.bus_write(&bus, core.LYC_ADDR, 0x99)
	got2 := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, got2 & 0x04 == 0, "LYC(0x99) != LY(0) のとき STAT bit2 は立たないべき: got=%02X", got2)
}
