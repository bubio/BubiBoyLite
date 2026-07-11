package tests

import "core:testing"
import core "bbl:core"

// T5-3: 波形メモリチャンネル(ch3)の単体テスト。
// 参照: docs/dev/phases/phase-05-apu.md T5-3「完了条件」。

@(private = "file")
power_on_wave_apu :: proc(bus: ^core.Bus) {
	core.bus_write(bus, core.NR52_ADDR, 0x80)
}

@(test)
test_apu_wave_nibble_order_is_high_first :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_wave_apu(&bus)

	core.bus_write(&bus, 0xFF30, 0xAB) // サンプル0=0xA, サンプル1=0xB
	bus.apu.wave.position = 0
	testing.expect(t, core.apu_wave_current_nibble(&bus.apu) == 0x0A, "position0は上位ニブル")
	bus.apu.wave.position = 1
	testing.expect(t, core.apu_wave_current_nibble(&bus.apu) == 0x0B, "position1は下位ニブル")

	core.bus_write(&bus, 0xFF31, 0xCD)
	bus.apu.wave.position = 2
	testing.expect(t, core.apu_wave_current_nibble(&bus.apu) == 0x0C)
	bus.apu.wave.position = 3
	testing.expect(t, core.apu_wave_current_nibble(&bus.apu) == 0x0D)
}

@(test)
test_apu_wave_output_level_decode :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_wave_apu(&bus)

	core.bus_write(&bus, core.NR32_ADDR, 0x00) // 00 = mute
	testing.expect(t, bus.apu.wave.output_level == 0)
	core.bus_write(&bus, core.NR32_ADDR, 0x20) // 01 = 100%
	testing.expect(t, bus.apu.wave.output_level == 1)
	core.bus_write(&bus, core.NR32_ADDR, 0x40) // 10 = 50%
	testing.expect(t, bus.apu.wave.output_level == 2)
	core.bus_write(&bus, core.NR32_ADDR, 0x60) // 11 = 25%
	testing.expect(t, bus.apu.wave.output_level == 3)
}

@(test)
test_apu_wave_length_is_256_n :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_wave_apu(&bus)

	core.bus_write(&bus, core.NR31_ADDR, 1) // length = 256-1 = 255
	testing.expect(t, bus.apu.wave.length_counter == 255)

	core.bus_write(&bus, core.NR31_ADDR, 0) // length = 256-0 = 256
	testing.expect(t, bus.apu.wave.length_counter == 256)
}

@(test)
test_apu_wave_trigger_requires_dac :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_wave_apu(&bus)

	core.bus_write(&bus, core.NR30_ADDR, 0x00) // DAC off
	core.bus_write(&bus, core.NR34_ADDR, 0x80) // トリガー
	testing.expect(t, !bus.apu.wave.enabled)

	core.bus_write(&bus, core.NR30_ADDR, 0x80) // DAC on
	core.bus_write(&bus, core.NR34_ADDR, 0x80)
	testing.expect(t, bus.apu.wave.enabled)
}

@(test)
test_apu_wave_trigger_resets_position :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_wave_apu(&bus)

	core.bus_write(&bus, core.NR30_ADDR, 0x80)
	core.bus_write(&bus, core.NR33_ADDR, 0x00)
	core.bus_write(&bus, core.NR34_ADDR, 0x87) // freq=0x700=1792, トリガー

	testing.expect(t, bus.apu.wave.position == 0)
	testing.expect(t, bus.apu.wave.frequency == 1792)

	// period = (2048-1792)*2 = 512
	core.bus_tick(&bus, 512)
	testing.expect(t, bus.apu.wave.position == 1)
}

@(test)
test_apu_wave_dac_off_disables_playing_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_wave_apu(&bus)

	core.bus_write(&bus, core.NR30_ADDR, 0x80)
	core.bus_write(&bus, core.NR34_ADDR, 0x80)
	testing.expect(t, bus.apu.wave.enabled)

	core.bus_write(&bus, core.NR30_ADDR, 0x00)
	testing.expect(t, !bus.apu.wave.enabled)
}
