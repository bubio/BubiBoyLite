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

// T20-2: 区間平均(ボックスフィルタ)の回帰テスト。wave RAM を全バイト0xF0(ナイブル値が
// 15,0,15,0,...と交互)に設定し、周波数2040(ナイキスト超えの閾値未満、区間平均の
// 通常経路を通る)で1周期16 T-cycle毎に位置が進む状態にすると、48kHzサンプル1個分の
// 区間(約87 T-cycle)の間に複数回振幅が反転する。点サンプリング(修正前)なら出力は
// 常に振幅上限(左chソロで0.25*32767≈8191)近辺になるはずだが、区間平均なら大きく
// 減衰する(Pythonで同アルゴリズムを独立再現し平均振幅約592・最大振幅約847を確認済み、
// 検証ログ参照)。
@(test)
test_apu_wave_box_filter_attenuates_high_frequency_toggle :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	core.bus_write(&bus, core.NR50_ADDR, 0x77) // 左右とも最大音量
	core.bus_write(&bus, core.NR51_ADDR, 0x44) // ch3のみ左右両方へ
	core.bus_write(&bus, core.NR32_ADDR, 0x20) // output_level=1(100%)
	for addr in u16(0xFF30) ..= u16(0xFF3F) {
		core.bus_write(&bus, addr, 0xF0) // 全position交互に15,0
	}
	core.bus_write(&bus, core.NR30_ADDR, 0x80) // DAC on
	core.bus_write(&bus, core.NR33_ADDR, 0xF8)
	core.bus_write(&bus, core.NR34_ADDR, 0x87) // freq=0x7F8=2040、トリガー

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
	sum_abs: i64 = 0
	count := 0
	for i := 0; i < len(samples); i += 2 { // 左chのみ(ch3ソロ)
		v := int(samples[i])
		a := v < 0 ? -v : v
		if a > max_amp {
			max_amp = a
		}
		sum_abs += i64(a)
		count += 1
	}
	mean_abs := f64(sum_abs) / f64(count)

	testing.expectf(
		t,
		mean_abs < 2000,
		"区間平均により減衰するはずだが平均振幅%fだった(点サンプリングなら8191近辺のはず)",
		mean_abs,
	)
	testing.expectf(t, max_amp < 2000, "区間平均なら最大振幅も抑えられるはずだが%dだった", max_amp)
}

// T20-2: ナイキスト周波数超えフォールバック(1周期全体の平均)の回帰テスト。wave RAM を
// [0xFF,0xF0]の2バイトパターンの繰り返し(32サンプル中24個が15、8個が0)に設定すると、
// 1周期全体の平均は (24*15 + 8*(-15)) / 32 / 15 = 0.5 になる(手計算)。周波数2047は
// ナイキスト(24kHz)を大きく超える(1周期=64 T-cycle、48kHzサンプル間隔約87 T-cycleより
// 短い)ため、区間平均ではなく1周期全体の平均にフォールバックし、位相に依存せず常に
// この理論値どおりの振幅になるはず。
@(test)
test_apu_wave_above_nyquist_uses_full_cycle_average :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	core.bus_write(&bus, core.NR50_ADDR, 0x77)
	core.bus_write(&bus, core.NR51_ADDR, 0x44) // ch3のみ左右両方へ
	core.bus_write(&bus, core.NR32_ADDR, 0x20) // output_level=1(100%)
	for i in 0 ..< 8 {
		core.bus_write(&bus, u16(0xFF30 + i*2), 0xFF)
		core.bus_write(&bus, u16(0xFF30 + i*2 + 1), 0xF0)
	}
	core.bus_write(&bus, core.NR30_ADDR, 0x80) // DAC on
	core.bus_write(&bus, core.NR33_ADDR, 0xFF)
	core.bus_write(&bus, core.NR34_ADDR, 0x87) // freq=0x7FF=2047、トリガー

	// 期待振幅: 0.5(正規化) * 0.25(ミキサー) * 左右ボリューム1.0 * 32767 ≈ 4095。
	expected_f: f32 = 0.5 * 0.25 * 32767.0
	expected := int(expected_f)

	samples: [dynamic]i16
	defer delete(samples)
	buf: [4096]i16
	remaining := 200000
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

	testing.expect(t, len(samples) > 200, "十分なサンプル数が採取できていること")

	// 最初の数サンプルはトリガー直後の過渡状態(区間平均の窓がまだ揃っていない)の可能性が
	// あるため読み飛ばし、以降は理論値に位相非依存で一致するはず(フォールバックの特徴)。
	for i := 20; i < len(samples); i += 2 {
		v := int(samples[i])
		diff := v - expected
		if diff < 0 {
			diff = -diff
		}
		testing.expectf(
			t,
			diff <= 2,
			"ナイキスト超えフォールバックは位相非依存の理論値%dに一致するはずだがsamples[%d]=%dだった",
			expected,
			i,
			v,
		)
	}
}
