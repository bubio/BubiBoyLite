package tests

import "core:testing"
import core "bbl:core"

// T5-4: ノイズチャンネル(ch4)の単体テスト。
// 参照: docs/dev/phases/phase-05-apu.md T5-4「完了条件」。
// LFSR系列の期待値は Pan Docs のアルゴリズム(XOR(bit0,bit1)をbit14に挿入して右シフト、
// 7bitモードはbit6にも書き込む)をPythonで独立に再現して求めた既知系列(検証ログ参照)。

@(private = "file")
power_on_noise_apu :: proc(bus: ^core.Bus) {
	core.bus_write(bus, core.NR52_ADDR, 0x80)
}

@(test)
test_apu_noise_trigger_resets_lfsr_and_requires_dac :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_noise_apu(&bus)

	core.bus_write(&bus, core.NR42_ADDR, 0x00) // DAC off(上位5bit=0)
	core.bus_write(&bus, core.NR44_ADDR, 0x80)
	testing.expect(t, !bus.apu.noise.enabled)

	core.bus_write(&bus, core.NR42_ADDR, 0xF0) // DAC on
	core.bus_write(&bus, core.NR44_ADDR, 0x80)
	testing.expect(t, bus.apu.noise.enabled)
	testing.expect(t, bus.apu.noise.lfsr == 0x7FFF)
}

@(test)
test_apu_noise_lfsr_sequence_15bit_mode :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_noise_apu(&bus)

	core.bus_write(&bus, core.NR42_ADDR, 0xF0)
	core.bus_write(&bus, core.NR43_ADDR, 0x00) // divisor code0(=8) << shift0 = period8、15bitモード
	core.bus_write(&bus, core.NR44_ADDR, 0x80)

	testing.expect(t, bus.apu.noise.lfsr == 0x7FFF)

	expected := [4]u16{0x3FFF, 0x1FFF, 0x0FFF, 0x07FF}
	for want, i in expected {
		core.bus_tick(&bus, 8)
		testing.expectf(t, bus.apu.noise.lfsr == want, "step %d: expected %04X, got %04X", i, want, bus.apu.noise.lfsr)
	}
}

@(test)
test_apu_noise_lfsr_7bit_mode :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_noise_apu(&bus)

	core.bus_write(&bus, core.NR42_ADDR, 0xF0)
	core.bus_write(&bus, core.NR43_ADDR, 0x08) // bit3=1(7bitモード)、period8
	core.bus_write(&bus, core.NR44_ADDR, 0x80)

	expected := [3]u16{0x3FBF, 0x1F9F, 0x0F8F}
	for want, i in expected {
		core.bus_tick(&bus, 8)
		testing.expectf(t, bus.apu.noise.lfsr == want, "step %d: expected %04X, got %04X", i, want, bus.apu.noise.lfsr)
	}
}

@(test)
test_apu_noise_divisor_table_timing :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_noise_apu(&bus)

	core.bus_write(&bus, core.NR42_ADDR, 0xF0)
	// divisor code1(=16) << shift2 = period64。
	core.bus_write(&bus, core.NR43_ADDR, 0x21)
	core.bus_write(&bus, core.NR44_ADDR, 0x80)

	core.bus_tick(&bus, 63)
	testing.expect(t, bus.apu.noise.lfsr == 0x7FFF, "周期63/64ではまだ進まない")

	core.bus_tick(&bus, 1)
	testing.expect(t, bus.apu.noise.lfsr == 0x3FFF, "64サイクルでdivisor=16<<shift2の周期に達する")
}

@(test)
test_apu_noise_length_counter_expiry_stops_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_noise_apu(&bus)

	core.bus_write(&bus, core.NR42_ADDR, 0xF0)
	core.bus_write(&bus, core.NR41_ADDR, 0x3F) // length = 64-63 = 1
	core.bus_write(&bus, core.NR44_ADDR, 0xC0) // トリガー + length enable

	testing.expect(t, bus.apu.noise.enabled)
	core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	testing.expect(t, !bus.apu.noise.enabled)
}

@(test)
test_apu_noise_dac_off_disables_playing_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_noise_apu(&bus)

	core.bus_write(&bus, core.NR42_ADDR, 0xF0)
	core.bus_write(&bus, core.NR44_ADDR, 0x80)
	testing.expect(t, bus.apu.noise.enabled)

	core.bus_write(&bus, core.NR42_ADDR, 0x00)
	testing.expect(t, !bus.apu.noise.enabled)
}
