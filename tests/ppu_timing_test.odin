package tests

import "core:testing"
import core "bbl:core"

// T3-2: モードタイミングと割り込みの単体テスト。
// DoD: 「70224 T-cycle で LY が一巡し VBlank 割り込みが1回。LYC 一致で STAT bit2」。
// 加えて STAT blocking(条件のORの立ち上がりエッジでのみ発火)も検証する。

@(test)
test_ppu_frame_completes_one_vblank :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.LCDC_ADDR, 0x91) // LCD on(LYはライン先頭0へリセットされる)

	core.bus_tick(&bus, core.CYCLES_PER_FRAME)

	testing.expectf(
		t,
		core.bus_read(&bus, core.LY_ADDR) == 0,
		"70224 T-cycle 後は LY が一巡して 0 に戻るべき: got=%d",
		core.bus_read(&bus, core.LY_ADDR),
	)

	interrupt_flags := core.bus_read(&bus, core.IF_ADDR)
	testing.expectf(
		t,
		interrupt_flags & core.INT_VBLANK_BIT != 0,
		"1フレームの間にVBlank割り込み(IF bit0)が要求されるべき: IF=%02X",
		interrupt_flags,
	)
}

@(test)
test_ppu_lyc_equal_tracks_ly_during_tick :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.LCDC_ADDR, 0x91)
	core.bus_write(&bus, core.LYC_ADDR, 5)

	// ちょうど5ライン分進めるとLY=5, dot=0(モード2の先頭)になる。
	core.bus_tick(&bus, 5 * core.CYCLES_PER_LINE)

	testing.expectf(t, core.bus_read(&bus, core.LY_ADDR) == 5, "LY should be 5")
	stat := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, stat & 0x04 != 0, "LY==LYC(5)のときSTAT bit2が立つべき: STAT=%02X", stat)
	testing.expectf(t, stat & 0x03 == 2, "dot=0はモード2(OamScan)であるべき: STAT=%02X", stat)

	// もう1ライン進めるとLY=6になりLYC(5)と不一致になる。
	core.bus_tick(&bus, core.CYCLES_PER_LINE)
	stat2 := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, stat2 & 0x04 == 0, "LY(6)!=LYC(5)のときSTAT bit2は立たないべき: STAT=%02X", stat2)
}

@(test)
test_ppu_stat_interrupt_fires_only_on_rising_edge :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.STAT_ADDR, 0x08) // bit3: HBlank(モード0)割り込み有効化のみ
	core.bus_write(&bus, core.LCDC_ADDR, 0x91) // LY=0, dot=0, モード2から開始

	// モード2(80) + モード3(172) = 252 T-cycle でHBlank(モード0)に入る。
	core.bus_tick(&bus, 80 + 172)

	stat := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, stat & 0x03 == 0, "252 T-cycle後はモード0(HBlank)であるべき: STAT=%02X", stat)

	interrupt_flags := core.bus_read(&bus, core.IF_ADDR)
	testing.expectf(
		t,
		interrupt_flags & core.INT_STAT_BIT != 0,
		"HBlank突入の立ち上がりでSTAT割り込み(IF bit1)が要求されるべき: IF=%02X",
		interrupt_flags,
	)

	// IF の STAT ビットだけをクリアして、モード0のまま(条件がtrueのまま)数サイクル進めても
	// 再発火しない(STAT blocking)ことを確認する。
	core.bus_write(&bus, core.IF_ADDR, interrupt_flags & ~u8(core.INT_STAT_BIT))
	core.bus_tick(&bus, 10) // まだモード0の範囲内(dot=252+10=262 < 456)

	stat_after := core.bus_read(&bus, core.STAT_ADDR)
	testing.expectf(t, stat_after & 0x03 == 0, "まだモード0であるべき(テスト前提の確認): STAT=%02X", stat_after)

	interrupt_flags_after := core.bus_read(&bus, core.IF_ADDR)
	testing.expectf(
		t,
		interrupt_flags_after & core.INT_STAT_BIT == 0,
		"条件が真のまま変化していない間はSTAT割り込みが再発火しないべき(blocking): IF=%02X",
		interrupt_flags_after,
	)
}
