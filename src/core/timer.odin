package core

// DIV/TIMA/TMA/TAC の正式実装(T2-3)。落下エッジ検出方式でTIMAをカウントアップする。
// T1-9 で bus.odin に入れたフリーラン仮実装を置き換える。
// 参照: ~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Timer.fs(136行、ロジックをそのまま移植)。
//
// DIV は独立したレジスタではなく、bus.div_counter(内部16bitカウンタ)の上位8bit。
// TIMA は「TAC で選んだカウンタビットと TAC enable(bit2)の AND」の落下エッジ(1→0)で
// 1増える。この信号は timer_tick 内で 1 T-cycle 刻みに評価する(4サイクルまとめて
// 判定するとエッジを跨いだ変化を見落とすため)。

// timer_selected_bit は TAC 下位2bitに対応する内部カウンタのビット位置を返す。
// 00→bit9(4096Hz), 01→bit3(262144Hz), 10→bit5(65536Hz), 11→bit7(16384Hz)。
@(private)
timer_selected_bit :: proc(tac: u8) -> uint {
	switch tac & 0x3 {
	case 0:
		return 9
	case 1:
		return 3
	case 2:
		return 5
	case:
		return 7
	}
}

// timer_signal は現在の内部カウンタと TAC から、TIMA インクリメントの元になる
// 信号(TAC enable と選択ビットの AND)の現在値を返す。
@(private)
timer_signal :: proc(divider: u16, tac: u8) -> bool {
	if tac & 0x4 == 0 {
		return false
	}
	bit := timer_selected_bit(tac)
	return divider & (u16(1) << bit) != 0
}

// timer_increment_tima は TIMA を1増やす。0xFF からのオーバーフローでは実際の値は
// まだ更新せず(4 T-cycle の間 0x00 のまま)、リロード遅延を開始する。
// 既にリロード遅延中の場合、この期間中の追加の落下エッジは無視される
// (実機: リロードが完了するまで TIMA は変化しない)。
@(private)
timer_increment_tima :: proc(bus: ^Bus) {
	if bus.timer_reload_pending > 0 {
		return
	}
	if bus.tima == 0xFF {
		bus.tima = 0x00
		bus.timer_reload_pending = 4
	} else {
		bus.tima += 1
	}
}

// timer_advance_reload はリロード遅延のカウントダウンを1 T-cycle分進める。
// 残り1からの遷移で TMA を TIMA へリロードし、タイマー割り込み(IF bit2)を要求する。
// このタイミングで timer_reload_just_happened を立てる(TIMA/TMA 書き込みの
// 特殊挙動判定に使う。tima_write_reloading/tma_write_reloading 用)。
@(private)
timer_advance_reload :: proc(bus: ^Bus) {
	if bus.timer_reload_pending <= 0 {
		return
	}
	if bus.timer_reload_pending == 1 {
		bus.timer_reload_pending = 0
		bus.tima = bus.tma
		bus.timer_reload_just_happened = true
		interrupt_request(bus, .Timer)
	} else {
		bus.timer_reload_pending -= 1
	}
}

// timer_tick は t_cycles ぶん(1 T-cycle刻み)タイマーを進める。bus_tick から呼ばれる
// (architecture.md のタイミングモデル: 命令のメモリアクセス毎に呼ばれるので t_cycles は
// 通常4)。timer_reload_just_happened はこの呼び出し1回ぶんの結果として毎回上書きする。
timer_tick :: proc(bus: ^Bus, t_cycles: int) {
	bus.timer_reload_just_happened = false

	for _ in 0 ..< t_cycles {
		timer_advance_reload(bus)

		old_signal := timer_signal(bus.div_counter, bus.tac)
		bus.div_counter += 1
		new_signal := timer_signal(bus.div_counter, bus.tac)

		if old_signal && !new_signal {
			timer_increment_tima(bus)
		}
	}
}

// timer_write_div は DIV(0xFF04) への書き込みを処理する: 値によらず内部カウンタ全体を
// 0にする。このとき選択ビットが1→0に落ちるなら TIMA も余分に進む(実機の仕様)。
timer_write_div :: proc(bus: ^Bus) {
	old_signal := timer_signal(bus.div_counter, bus.tac)
	bus.div_counter = 0
	if old_signal {
		timer_increment_tima(bus)
	}
}

// timer_write_tima は TIMA(0xFF05) への書き込みを処理する。
// ちょうどリロードが完了した直後の書き込み(timer_reload_just_happened)は無視される
// (実機の仕様。mooneye tima_write_reloading が検査する)。それ以外は値をセットし、
// 保留中のリロード(4 T-cycle 窓の途中)をキャンセルする。
timer_write_tima :: proc(bus: ^Bus, value: u8) {
	if bus.timer_reload_just_happened {
		return
	}
	bus.timer_reload_pending = 0
	bus.tima = value
}

// timer_write_tma は TMA(0xFF06) への書き込みを処理する。ちょうどリロードが完了した
// 直後の書き込みは、新しい TMA 値がそのまま TIMA にも反映される(実機の仕様。
// mooneye tma_write_reloading が検査する)。
timer_write_tma :: proc(bus: ^Bus, value: u8) {
	bus.tma = value
	if bus.timer_reload_just_happened {
		bus.tima = value
	}
}

// timer_write_tac は TAC(0xFF07) への書き込みを処理する: 選択ビットが1→0に落ちる
// タイミングと一致すれば TIMA が余分に進む(実機の仕様)。
timer_write_tac :: proc(bus: ^Bus, value: u8) {
	new_tac := value & 0x07
	old_signal := timer_signal(bus.div_counter, bus.tac)
	bus.tac = new_tac
	new_signal := timer_signal(bus.div_counter, bus.tac)
	if old_signal && !new_signal {
		timer_increment_tima(bus)
	}
}
