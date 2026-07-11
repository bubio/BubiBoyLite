package tests

import "core:testing"
import core "bbl:core"

// T5-5: ミキサーと48kHzサンプル生成の単体テスト。
// 参照: docs/dev/phases/phase-05-apu.md T5-5「完了条件」
// (1フレーム分tick後のサンプル数が800前後、無音時のDCオフセットが0近傍)。

@(test)
test_apu_sample_count_per_frame_matches_theoretical_rate :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)

	core.bus_tick(&bus, core.CYCLES_PER_FRAME)

	// 70224/4194304*48000 ≈ 803.6。固定小数点カウンタでの厳密な理論値は803
	// (Pythonで独立に同アルゴリズムを再現して確認、検証ログ参照)。
	dst: [4096]i16
	n := core.apu_drain_samples(&bus.apu, dst[:])
	pairs := n / 2
	testing.expectf(t, pairs == 803, "1フレーム分のサンプル数は803ペアを期待したが%dだった", pairs)
}

@(test)
test_apu_silence_has_zero_dc_offset :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80) // 電源onだが全ch未トリガー=無音

	core.bus_tick(&bus, core.CYCLES_PER_FRAME)

	dst: [4096]i16
	n := core.apu_drain_samples(&bus.apu, dst[:])
	testing.expect(t, n > 0)

	sum: i64 = 0
	for i in 0 ..< n {
		sum += i64(dst[i])
	}
	avg := f64(sum) / f64(n)
	testing.expectf(t, avg == 0, "無音時のDCオフセットは0を期待したが平均%fだった", avg)
}

@(test)
test_apu_powered_off_still_generates_silent_samples_at_correct_rate :: proc(t: ^testing.T) {
	// T5-6のオーディオ駆動ペーシングがAPU電源off中も破綻しないよう、サンプル生成の
	// ペース自体は電源状態に関わらず一定であることを確認する。
	bus: core.Bus // 電源off(zero-value)のまま

	core.bus_tick(&bus, core.CYCLES_PER_FRAME)

	dst: [4096]i16
	n := core.apu_drain_samples(&bus.apu, dst[:])
	pairs := n / 2
	testing.expectf(t, pairs == 803, "電源off中もサンプル生成レートは変わらないはずだが%dペアだった", pairs)
	for i in 0 ..< n {
		testing.expect(t, dst[i] == 0, "電源off中は常に無音(0)を期待")
	}
}

@(test)
test_apu_drain_samples_respects_destination_capacity :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)
	core.bus_tick(&bus, core.CYCLES_PER_FRAME) // 803ペア生成

	small: [10]i16 // 5ペア分の容量しかない
	n := core.apu_drain_samples(&bus.apu, small[:])
	testing.expect(t, n == 10)

	rest: [4096]i16
	n2 := core.apu_drain_samples(&bus.apu, rest[:])
	testing.expect(t, n2 == (803-5)*2)
}

@(test)
test_apu_ring_buffer_caps_at_capacity_when_not_drained :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, core.NR52_ADDR, 0x80)

	// APU_RING_CAPACITY(8192ペア)を大きく超える分のサンプルを、drainせずに生成し続ける。
	// 803ペア/フレームなので、8192/803 ≈ 10.2 -> 12フレーム回せば確実に超える。
	for _ in 0 ..< 12 {
		core.bus_tick(&bus, core.CYCLES_PER_FRAME)
	}

	dst: [core.APU_RING_CAPACITY * 2 + 100]i16
	n := core.apu_drain_samples(&bus.apu, dst[:])
	pairs := n / 2
	testing.expectf(t, pairs == core.APU_RING_CAPACITY, "あふれた分は破棄され容量上限%dに収まるはずだが%dだった", core.APU_RING_CAPACITY, pairs)
}
