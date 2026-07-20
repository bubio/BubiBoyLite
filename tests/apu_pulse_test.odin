package tests

import "core:testing"
import core "bbl:core"

// T5-2: 矩形波チャンネル(ch1スイープ付き/ch2スイープなし)の単体テスト。
// 参照: docs/dev/phases/phase-05-apu.md T5-2「完了条件」。

@(private = "file")
power_on_apu :: proc(bus: ^core.Bus) {
	core.bus_write(bus, core.NR52_ADDR, 0x80)
}

@(test)
test_apu_pulse_trigger_enables_channel_with_dac :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR12_ADDR, 0xF0) // 音量15、DAC on
	core.bus_write(&bus, core.NR14_ADDR, 0x80) // トリガー

	testing.expect(t, bus.apu.pulse1.enabled)
	testing.expect(t, core.bus_read(&bus, core.NR52_ADDR) & 0x01 != 0)
}

@(test)
test_apu_pulse_trigger_without_dac_stays_disabled :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR12_ADDR, 0x00) // DAC off(上位5bit=0)
	core.bus_write(&bus, core.NR14_ADDR, 0x80)

	testing.expect(t, !bus.apu.pulse1.enabled)
}

@(test)
test_apu_pulse_dac_off_disables_playing_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR14_ADDR, 0x80)
	testing.expect(t, bus.apu.pulse1.enabled)

	core.bus_write(&bus, core.NR12_ADDR, 0x00) // DAC off
	testing.expect(t, !bus.apu.pulse1.enabled)
}

@(test)
test_apu_pulse_length_counter_expiry_stops_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR11_ADDR, 0x3F) // length = 64-63 = 1
	core.bus_write(&bus, core.NR14_ADDR, 0xC0) // トリガー + length enable

	testing.expect(t, bus.apu.pulse1.enabled)
	testing.expect(t, bus.apu.pulse1.length_counter == 1)

	// フレームシーケンサの length step(0,2,4,6のいずれか)まで進める。
	core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)

	testing.expect(t, bus.apu.pulse1.length_counter == 0)
	testing.expect(t, !bus.apu.pulse1.enabled)
}

@(test)
test_apu_pulse_duty_step_advances_with_period :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR13_ADDR, 0x00)
	core.bus_write(&bus, core.NR14_ADDR, 0x87) // freq=0x700 (高3bit=7) -> period=(2048-0x700)*4
	// frequency = (0x700)|0 = 0x700 = 1792。period=(2048-1792)*4=1024

	testing.expect(t, bus.apu.pulse1.duty_step == 0)
	core.bus_tick(&bus, 1024)
	testing.expect(t, bus.apu.pulse1.duty_step == 1)
	core.bus_tick(&bus, 1024*7)
	testing.expect(t, bus.apu.pulse1.duty_step == 0) // 8stepで一周
}

@(test)
test_apu_pulse_envelope_increases_and_clamps :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	// 初期音量0、増加方向、周期1
	core.bus_write(&bus, core.NR12_ADDR, 0x09) // vol=0, increase(bit3=1), period=1 -> だがperiod1&vol0はDAC off
	// DACはbit7-3(上位5bit)が0でoff。0x09の上位5bit=00001=1なのでDAC on。
	core.bus_write(&bus, core.NR14_ADDR, 0x80) // トリガー
	testing.expect(t, bus.apu.pulse1.envelope.volume == 0)

	// エンベロープはstep7でのみ進む。frame_sequencer_stepは0開始なので、
	// step0,1,2,3,4,5,6の発火を経てstep7が発火するまで8周期分進める。
	for _ in 0 ..< 8 {
		core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	}
	testing.expect(t, bus.apu.pulse1.envelope.volume == 1)
}

@(test)
test_apu_pulse2_has_no_sweep_field_effect :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR22_ADDR, 0xF0)
	core.bus_write(&bus, core.NR23_ADDR, 0x00)
	core.bus_write(&bus, core.NR24_ADDR, 0x87)
	testing.expect(t, bus.apu.pulse2.enabled)
	testing.expect(t, !bus.apu.pulse2.sweep.enabled) // ch2はスイープ初期化されない
}

@(test)
test_apu_sweep_overflow_on_trigger_disables_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR10_ADDR, 0x01) // period=0, negate=0, shift=1
	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	// frequency = 2000。shift1でdelta=1000、new=3000>2047でオーバーフロー。
	core.bus_write(&bus, core.NR13_ADDR, u8(2000 & 0xFF))
	core.bus_write(&bus, core.NR14_ADDR, 0x80 | u8((2000 >> 8) & 0x07))

	testing.expect(t, !bus.apu.pulse1.enabled, "06-overflow on trigger 相当: トリガー時オーバーフローで即停止")
}

@(test)
test_apu_sweep_periodic_clock_updates_frequency :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR10_ADDR, 0x11) // period=1, negate=0, shift=1
	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR13_ADDR, 100) // frequency = 100(オーバーフローしない範囲)
	core.bus_write(&bus, core.NR14_ADDR, 0x80)

	testing.expect(t, bus.apu.pulse1.enabled)
	testing.expect(t, bus.apu.pulse1.frequency == 100, "トリガー直後はまだ周波数を適用しない(判定のみ)")

	// スイープ(step2,6)まで進める: frame_sequencer_step は0開始なので3回tickでstep2が発火。
	for _ in 0 ..< 3 {
		core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	}

	testing.expect(t, bus.apu.pulse1.enabled)
	testing.expect(t, bus.apu.pulse1.frequency == 150, "100 + (100>>1) = 150")
}

@(test)
test_apu_sweep_negate_then_positive_disables_channel :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR10_ADDR, 0x1F) // period=1, negate=1, shift=7
	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR13_ADDR, 0x00)
	core.bus_write(&bus, core.NR14_ADDR, 0x84) // freq=0x400=1024, トリガー
	testing.expect(t, bus.apu.pulse1.enabled)
	testing.expect(t, bus.apu.pulse1.sweep.negate_calculated_since_trigger, "トリガー時のオーバーフロー判定でnegateを使ったフラグが立つ")

	// negateから正方向へ切り替える。
	core.bus_write(&bus, core.NR10_ADDR, 0x17) // period=1, negate=0, shift=7
	testing.expect(t, !bus.apu.pulse1.enabled, "negate計算後の正方向切替でch即停止")
}

// T21-2: shift==0でも周期的なapu_sweep_clockのオーバーフロー判定は必ず行われる
// (フェーズ21で修正したバグの回帰テスト)。Fableの最小再現、BubiBoyの回帰テスト
// `zero shift sweep still disables pulse channel on overflow` に相当するレジスタ値。
@(test)
test_apu_sweep_zero_shift_periodic_clock_still_disables_on_overflow :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR10_ADDR, 0x20) // period=2, negate=0, shift=0
	core.bus_write(&bus, core.NR11_ADDR, 0x40)
	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR13_ADDR, 0x00)
	core.bus_write(&bus, core.NR14_ADDR, 0x84) // freq=0x400=1024, トリガー

	testing.expect(t, bus.apu.pulse1.enabled, "shift=0はトリガー時オーバーフロー判定の対象外(dmg_sound 06相当)")

	// フレームシーケンサを7ステップ進める(sweepはstep2,6で発火。2回目の発火で
	// shadow_frequency 1024 が shift=0でも delta=1024 として加算され2048でオーバーフロー)。
	for _ in 0 ..< 7 {
		core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	}

	testing.expect(
		t,
		!bus.apu.pulse1.enabled,
		"shift=0でも周期的なapu_sweep_clockのオーバーフロー判定は必ず行われチャンネルが無効化される",
	)
}

// T21-2: period==0かつshift==0(NR10=0x00、スイープ完全オフ)は、apu_trigger_pulseで
// sweep.enabled=falseになりapu_sweep_clockの先頭ガードで即returnするため、
// 本フェーズの修正の影響を受けない(回帰確認)。
@(test)
test_apu_sweep_fully_off_is_unaffected_by_overflow_fix :: proc(t: ^testing.T) {
	bus: core.Bus
	power_on_apu(&bus)

	core.bus_write(&bus, core.NR10_ADDR, 0x00) // period=0, negate=0, shift=0(スイープ完全オフ)
	core.bus_write(&bus, core.NR12_ADDR, 0xF0)
	core.bus_write(&bus, core.NR13_ADDR, 0x00)
	core.bus_write(&bus, core.NR14_ADDR, 0x84) // freq=0x400=1024, トリガー

	testing.expect(t, bus.apu.pulse1.enabled)
	testing.expect(t, !bus.apu.pulse1.sweep.enabled, "period=0かつshift=0はトリガー時にsweep.enabled=falseになる")

	for _ in 0 ..< 7 {
		core.bus_tick(&bus, core.FRAME_SEQUENCER_PERIOD)
	}

	testing.expect(
		t,
		bus.apu.pulse1.enabled,
		"スイープ完全オフはapu_sweep_clockの先頭ガードで即returnし、周波数もオーバーフロー判定も行われない",
	)
	testing.expect(t, bus.apu.pulse1.frequency == 1024, "周波数は変化しない")
}
