package tests

import "core:testing"
import core "bbl:core"

// OAM DMA(0xFF46)の単体テスト(T2-5)。

@(test)
test_dma_copies_160_bytes_from_source :: proc(t: ^testing.T) {
	bus: core.Bus
	for i in 0 ..< 256 {
		core.bus_write(&bus, 0xC000 + u16(i), u8(i))
	}

	core.bus_write(&bus, 0xFF46, 0xC0) // source = 0xC000

	// 1 M-cycleの開始遅延 + 160 M-cycleの転送 = 161 M-cycle = 644 T-cycle
	core.bus_tick(&bus, 644)

	ok := true
	for i in 0 ..< 160 {
		if core.bus_read(&bus, 0xFE00 + u16(i)) != u8(i) {
			ok = false
			break
		}
	}
	testing.expect(t, ok, "160バイトが転送元から正しくコピーされる")
}

@(test)
test_dma_takes_160_mcycles_after_1_mcycle_delay :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xC000, 0xAB)
	core.bus_write(&bus, 0xFF46, 0xC0)

	// bus.oam を直接見る(bus_read はDMA中0xFFを返すため、転送そのものの進み方を
	// 検査するにはバックストアを直接読む必要がある)。
	core.bus_tick(&bus, 4) // M1: まだ開始しない
	testing.expect(t, bus.oam[0] != 0xAB, "1 M-cycle目はまだ転送が始まらない")
	testing.expect(t, !bus.dma_active, "1 M-cycle目はまだ dma_active にならない")

	core.bus_tick(&bus, 4) // M2: 転送開始、1バイト目がコピーされる
	testing.expect(t, bus.dma_active, "2 M-cycle目でdma_activeになる")
	testing.expect(t, bus.oam[0] == 0xAB, "2 M-cycle目で1バイト目がコピーされる")
}

@(test)
test_dma_blocks_non_hram_reads_while_active :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xC000, 0x11)
	core.bus_write(&bus, 0xFF80, 0x22) // HRAM
	core.bus_write(&bus, 0xFF46, 0xC0)
	core.bus_tick(&bus, 8) // 開始遅延を過ぎて転送中にする

	testing.expect(t, core.bus_read(&bus, 0xC000) == 0xFF, "転送中はHRAM以外を読むと0xFF")
	testing.expect(t, core.bus_read(&bus, 0xFF80) == 0x22, "HRAMは転送中でも通常どおり読める")
}

@(test)
test_dma_reads_are_normal_again_after_transfer_completes :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xC000, 0x11)
	core.bus_write(&bus, 0xFF46, 0xC0)
	core.bus_tick(&bus, 644) // 開始遅延 + 160 M-cycle 全て終える

	testing.expect(t, core.bus_read(&bus, 0xC000) == 0x11, "転送完了後は通常どおり読める")
}

@(test)
test_dma_register_readback_returns_last_written_value :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF46, 0x9F)
	testing.expect(t, core.bus_read(&bus, 0xFF46) == 0x9F, "DMAレジスタは転送中でも書いた値を読み戻せる")
	core.bus_tick(&bus, 644)
	core.bus_write(&bus, 0xFF46, 0x42)
	testing.expect(t, core.bus_read(&bus, 0xFF46) == 0x42)
}
