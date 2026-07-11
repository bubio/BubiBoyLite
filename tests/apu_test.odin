package tests

import "core:testing"
import core "bbl:core"

// T5-1: APU 骨格・フレームシーケンサ・制御レジスタの単体テスト。
// 参照: docs/dev/phases/phase-05-apu.md T5-1「完了条件」。

@(test)
test_apu_register_read_mask_powered_on :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80) // 電源on

	// Pan Docs "Audio Registers" のマスク表(T5-1「落とし穴」に明記の値)。
	core.bus_write(&bus, core.NR10_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR10_ADDR) == 0x80)

	core.bus_write(&bus, core.NR11_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR11_ADDR) == 0x3F)

	core.bus_write(&bus, core.NR12_ADDR, 0xFF)
	testing.expect(t, core.bus_read(&bus, core.NR12_ADDR) == 0xFF) // マスク0x00: 全bit読める

	core.bus_write(&bus, core.NR13_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR13_ADDR) == 0xFF) // 書き込み専用

	core.bus_write(&bus, core.NR14_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR14_ADDR) == 0xBF)

	core.bus_write(&bus, core.NR21_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR21_ADDR) == 0x3F)

	core.bus_write(&bus, core.NR24_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR24_ADDR) == 0xBF)

	core.bus_write(&bus, core.NR30_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR30_ADDR) == 0x7F)

	core.bus_write(&bus, core.NR32_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR32_ADDR) == 0x9F)

	core.bus_write(&bus, core.NR34_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR34_ADDR) == 0xBF)

	core.bus_write(&bus, core.NR41_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR41_ADDR) == 0xFF)

	core.bus_write(&bus, core.NR44_ADDR, 0x00)
	testing.expect(t, core.bus_read(&bus, core.NR44_ADDR) == 0xBF)

	core.bus_write(&bus, core.NR50_ADDR, 0x77)
	testing.expect(t, core.bus_read(&bus, core.NR50_ADDR) == 0x77)

	core.bus_write(&bus, core.NR51_ADDR, 0xF3)
	testing.expect(t, core.bus_read(&bus, core.NR51_ADDR) == 0xF3)
}

@(test)
test_apu_nr52_status_reflects_power :: proc(t: ^testing.T) {
	bus: core.Bus

	// 電源off時: bit7=0, bit6-4=1固定, bit3-0=0
	testing.expect(t, core.bus_read(&bus, core.NR52_ADDR) == 0x70)

	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	testing.expect(t, core.bus_read(&bus, core.NR52_ADDR) == 0xF0) // ch全て無効(未トリガー)
}

@(test)
test_apu_power_off_clears_registers_but_keeps_wave_ram :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	core.bus_write(&bus, core.NR10_ADDR, 0x7F)
	core.bus_write(&bus, core.NR50_ADDR, 0x77)
	core.bus_write(&bus, 0xFF30, 0xAB) // wave RAM

	core.bus_write(&bus, core.NR52_ADDR, 0x00) // 電源off

	testing.expect(t, core.bus_read(&bus, core.NR10_ADDR) == 0x80) // クリアされマスクのみ見える(0x00|0x80)
	testing.expect(t, core.bus_read(&bus, core.NR50_ADDR) == 0x00)
	testing.expect(t, core.bus_read(&bus, 0xFF30) == 0xAB) // wave RAMは保持(T5-1落とし穴)

	// wave RAMは電源off中も書き込み可
	core.bus_write(&bus, 0xFF31, 0xCD)
	testing.expect(t, core.bus_read(&bus, 0xFF31) == 0xCD)

	// 電源off中、NR10等への書き込みは無視される(NRx1の長さデータ以外)
	core.bus_write(&bus, core.NR10_ADDR, 0x7F)
	testing.expect(t, core.bus_read(&bus, core.NR10_ADDR) == 0x80) // 変化なし
}

@(test)
test_apu_power_off_preserves_dmg_length_counters :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	core.bus_write(&bus, core.NR11_ADDR, 0x3F) // length_counter = 64-63 = 1

	core.bus_write(&bus, core.NR52_ADDR, 0x00) // 電源off

	// 電源off中もNRx1(長さデータ)は書き込める(DMGの例外、Pan Docs footnote)
	core.bus_write(&bus, core.NR21_ADDR, 0x20) // length_counter = 64-32 = 32

	core.bus_write(&bus, core.NR52_ADDR, 0x80) // 電源on

	// length_counterはpulse1/pulse2構造体の内部状態なので直接は読めないが、
	// NR11経由で書き込んだ値が電源off/onを跨いで保持されていることを再書き込みなしで
	// 間接確認する代わりに、NR21で電源off中に書いた値が正しく反映されているかを
	// トリガー時のch有効化を通じて確認する(T5-2でchが実装されるまでは長さが0でなければ
	// 良いとする簡易確認)。
	testing.expect(t, bus.apu.pulse1.length_counter == 1)
	testing.expect(t, bus.apu.pulse2.length_counter == 32)
}

@(test)
test_apu_frame_sequencer_cycles_through_steps :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)

	testing.expect(t, bus.apu.frame_sequencer_step == 0)
	core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	testing.expect(t, bus.apu.frame_sequencer_step == 1)

	for _ in 0 ..< 7 {
		core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	}
	testing.expect(t, bus.apu.frame_sequencer_step == 0) // 8stepで一周
}

@(test)
test_apu_unused_registers_read_ff :: proc(t: ^testing.T) {
	bus: core.Bus
	testing.expect(t, core.bus_read(&bus, 0xFF15) == 0xFF)
	testing.expect(t, core.bus_read(&bus, 0xFF1F) == 0xFF)
}
