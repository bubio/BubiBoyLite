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

// T20-2/T20-3: 区間平均(ボックスフィルタ)の回帰テスト(ノイズch版)。divisor=8/shift=0
// (周期8 T-cycle)にすると、48kHzサンプル1個分の区間(約87 T-cycle)の間にLFSRが
// 10回前後遷移する。点サンプリング(修正前)なら出力は常にenvelope音量の振幅上限
// (左chソロで0.25*32767≈8191)ぴったりになるはずだが、区間平均ならLFSRの正負反転が
// 平均され減衰する(Pythonで同アルゴリズムを独立再現し平均振幅約1984(振幅上限の
// 約24%)、最大振幅ちょうどに達するのは0.1%未満であることを確認済み、検証ログ参照)。
@(test)
test_apu_noise_box_filter_attenuates_high_frequency_toggle :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	core.bus_write(&bus, core.NR50_ADDR, 0x77) // 左右とも最大音量
	core.bus_write(&bus, core.NR51_ADDR, 0x88) // ch4のみ左右両方へ
	core.bus_write(&bus, core.NR42_ADDR, 0xF0) // 音量15、DAC on
	core.bus_write(&bus, core.NR43_ADDR, 0x00) // divisor code0(=8)<<shift0=周期8、15bitモード
	core.bus_write(&bus, core.NR44_ADDR, 0x80) // トリガー

	samples: [dynamic]i16
	defer delete(samples)
	buf: [4096]i16
	remaining := 2_000_000
	for remaining > 0 {
		chunk := min(remaining, 50000)
		core.bus_tick(&bus, chunk)
		remaining -= chunk
		for {
			n := core.apu_drain_samples(&bus.apu, buf[:])
			if n == 0 {
				break
			}
			append(&samples, ..buf[:n])
		}
	}

	testing.expect(t, len(samples) > 1000, "十分なサンプル数が採取できていること")

	max_amp := 0
	at_max_count := 0
	sum_abs: i64 = 0
	count := 0
	for i := 0; i < len(samples); i += 2 { // 左chのみ(ch4ソロ)
		v := int(samples[i])
		a := v < 0 ? -v : v
		if a > max_amp {
			max_amp = a
		}
		if a >= 8100 {
			at_max_count += 1
		}
		sum_abs += i64(a)
		count += 1
	}
	mean_abs := f64(sum_abs) / f64(count)
	max_fraction := f64(at_max_count) / f64(count)

	testing.expectf(
		t,
		mean_abs < 4000,
		"区間平均により減衰するはずだが平均振幅%fだった(点サンプリングなら8191近辺のはず)",
		mean_abs,
	)
	testing.expectf(
		t,
		max_fraction < 0.1,
		"点サンプリングなら常に振幅上限になるはずだが、区間平均では振幅上限付近の割合が低いはず(実測%f)",
		max_fraction,
	)
}
