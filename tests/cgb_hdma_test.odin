package tests

import "core:testing"
import core "bbl:core"

// T6-7: HDMA/GDMA(VRAM DMA)の単体テスト。
// DoD: 「GDMA全量転送」「HDMAがHBlank毎に16バイト進む」「中断とFF55読み値」。

@(private = "file")
tick_one_line_hdma :: proc(bus: ^core.Bus) {
	core.bus_tick(bus, core.CYCLES_PER_LINE)
}

// setup_hdma_source は WRAM(0xC000起点)に既知のパターン(offset値そのもの)を書き、
// HDMA1/HDMA2でそこをソースに設定する。
@(private = "file")
setup_hdma_source_pattern :: proc(bus: ^core.Bus, source_base: u16, length_bytes: int) {
	for i in 0 ..< length_bytes {
		core.bus_write(bus, source_base + u16(i), u8(i & 0xFF))
	}
	core.bus_write(bus, core.HDMA1_ADDR, u8(source_base >> 8))
	core.bus_write(bus, core.HDMA2_ADDR, u8(source_base & 0xFF))
}

@(test)
test_gdma_transfers_all_blocks_immediately :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	setup_hdma_source_pattern(&bus, 0xC000, 48) // 3ブロック分(48バイト)

	// 宛先: VRAM 0x8000起点。
	core.bus_write(&bus, core.HDMA3_ADDR, 0x80)
	core.bus_write(&bus, core.HDMA4_ADDR, 0x00)

	before := bus.cycles
	core.bus_write(&bus, core.HDMA5_ADDR, 0x02) // bit7=0(GDMA)、(2+1)*16=48バイト
	elapsed := bus.cycles - before

	testing.expect(t, !bus.hdma_active, "GDMAは即時完了するのでhdma_activeはfalseのはず")
	testing.expectf(t, core.bus_read(&bus, core.HDMA5_ADDR) == 0xFF, "GDMA完了後のFF55読み出しは0xFFのはず, got=%02X", core.bus_read(&bus, core.HDMA5_ADDR))

	// VRAM 0x8000-0x802Fに0..47のパターンがコピーされているはず。
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	for i in 0 ..< 48 {
		got := core.bus_read(&bus, 0x8000 + u16(i))
		testing.expectf(t, got == u8(i & 0xFF), "VRAM[0x%04X]は%dのはず, got=%d", 0x8000 + i, i & 0xFF, got)
	}

	testing.expectf(t, elapsed >= 24, "GDMAはCPU停止時間を消費するはず(3ブロック*8=24 T-cycle以上), got=%d", elapsed)
}

@(test)
test_hdma_advances_16_bytes_per_hblank :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	setup_hdma_source_pattern(&bus, 0xC000, 32) // 2ブロック分

	core.bus_write(&bus, core.HDMA3_ADDR, 0x80)
	core.bus_write(&bus, core.HDMA4_ADDR, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x91) // LCD on(HBlankへ遷移させるため)
	core.bus_write(&bus, core.HDMA5_ADDR, 0x81) // bit7=1(HDMA)、(1+1)*16=32バイト

	testing.expect(t, bus.hdma_active, "HDMA開始直後はhdma_activeのはず(GDMAと異なり即時転送しない)")
	testing.expectf(t, core.bus_read(&bus, core.HDMA5_ADDR) == 0x01, "開始直後のFF55は残り2ブロック-1=1のはず, got=%02X", core.bus_read(&bus, core.HDMA5_ADDR))

	// VRAMはまだ転送されていないはず。
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	testing.expectf(t, core.bus_read(&bus, 0x8000) == 0x00, "HDMA開始直後はまだ転送されていないはず")

	tick_one_line_hdma(&bus) // 1ライン進める(HBlankへ1回遷移)

	testing.expect(t, bus.hdma_active, "1ブロック目転送後もまだ2ブロック目が残っているはず")
	// offset0はパターン値も0なので転送有無を区別できない。offset5(パターン値5)で確認する。
	testing.expectf(t, core.bus_read(&bus, 0x8005) == 0x05, "1ブロック目の途中(offset5)が転送されたはず, got=%02X", core.bus_read(&bus, 0x8005))
	testing.expectf(t, core.bus_read(&bus, 0x800F) == 0x0F, "1ブロック目の末尾も転送されたはず")
	testing.expectf(t, core.bus_read(&bus, 0x8010) == 0x00, "2ブロック目はまだ転送されていないはず(パターン値16=0x10だが未転送で0のまま)")

	tick_one_line_hdma(&bus) // もう1ライン進める(2ブロック目)

	testing.expect(t, !bus.hdma_active, "2ブロック目転送で完了しhdma_activeはfalseになるはず")
	testing.expectf(t, core.bus_read(&bus, 0x8010) == 0x10, "2ブロック目が転送されたはず")
	testing.expectf(t, core.bus_read(&bus, core.HDMA5_ADDR) == 0xFF, "完了後のFF55読み出しは0xFFのはず")
}

@(test)
test_hdma_write_bit7_zero_while_active_cancels_and_readback :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	setup_hdma_source_pattern(&bus, 0xC000, 64) // 4ブロック分
	core.bus_write(&bus, core.HDMA3_ADDR, 0x80)
	core.bus_write(&bus, core.HDMA4_ADDR, 0x00)
	core.bus_write(&bus, core.LCDC_ADDR, 0x91)

	core.bus_write(&bus, core.HDMA5_ADDR, 0x83) // (3+1)*16=64バイト、HDMA
	tick_one_line_hdma(&bus) // 1ブロック転送、残り3ブロック

	testing.expectf(t, core.bus_read(&bus, core.HDMA5_ADDR) == 0x02, "1ブロック後は残り3-1=2のはず, got=%02X", core.bus_read(&bus, core.HDMA5_ADDR))

	// 中断: bit7=0を書く。
	core.bus_write(&bus, core.HDMA5_ADDR, 0x00)
	testing.expect(t, !bus.hdma_active, "中断後はhdma_activeがfalseになるはず")
	testing.expectf(t, core.bus_read(&bus, core.HDMA5_ADDR) == 0x82, "中断直後のFF55は残りブロック数-1にbit7=1が付いた値のはず(残り3ブロックなので3-1=2|0x80=0x82), got=%02X", core.bus_read(&bus, core.HDMA5_ADDR))

	// 中断後はもうラインを進めても転送されない。
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	before := core.bus_read(&bus, 0x8010)
	tick_one_line_hdma(&bus)
	after := core.bus_read(&bus, 0x8010)
	testing.expectf(t, before == after, "中断後は転送が進まないはず, before=%02X after=%02X", before, after)
}

@(test)
test_hdma_does_not_advance_while_lcd_off :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	setup_hdma_source_pattern(&bus, 0xC000, 16)
	core.bus_write(&bus, core.HDMA3_ADDR, 0x80)
	core.bus_write(&bus, core.HDMA4_ADDR, 0x00)

	core.bus_write(&bus, core.LCDC_ADDR, 0x00) // LCD off
	core.bus_write(&bus, core.HDMA5_ADDR, 0x80) // HDMA、1ブロックのみ

	testing.expect(t, bus.hdma_active, "HDMA開始直後はhdma_activeのはず")

	core.bus_tick(&bus, core.CYCLES_PER_LINE * 2) // LCD offなのでHBlankへ遷移しない

	testing.expect(t, bus.hdma_active, "LCD off中はHDMAが進まない(hdma_activeのままの)はず")
	core.bus_write(&bus, core.VBK_ADDR, 0x00)
	testing.expectf(t, core.bus_read(&bus, 0x8000) == 0x00, "LCD off中は転送が進まないはず")
}

@(test)
test_hdma_registers_ignored_in_dmg_mode :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Dmg

	core.bus_write(&bus, core.HDMA5_ADDR, 0x80)
	testing.expect(t, !bus.hdma_active, "DMGモードではHDMA5書き込みが無視されるはず")
	testing.expectf(t, core.bus_read(&bus, core.HDMA5_ADDR) == 0xFF, "DMGモードのHDMA5読み出しは未実装レジスタ扱いで0xFFのはず")
}
