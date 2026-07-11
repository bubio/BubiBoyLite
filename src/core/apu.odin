package core

// APU: 4ch(矩形波x2/波形メモリ/ノイズ) + フレームシーケンサ + 48kHz ステレオサンプル生成
// (T5-1〜T5-5)。SDL2 に一切依存しない(architecture.md「core と app の分離」)。
// 参照: ~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs(構造を参考にしつつ、dmg_sound の
// obscure 挙動(長さカウンタの即時clock、スイープのnegate切替停止等)は Pan Docs を
// 別途確認して補う。BubiBoy 自体は dmg_sound 個別ROMでの検証未実施のため鵜呑みにしない)。
// Pan Docs "Audio Registers" / "Sound Channel 1/2/3/4" / "Audio details"。
//
// T5-1(このコミット)の範囲: レジスタ読み書き(マスク表・NR52電源セマンティクス・wave RAM)
// とフレームシーケンサの巡回機構のみ。各chはまだトリガーできず常時無効(プレースホルダ、
// T3-1が LY を固定0のままにしたのと同じ位置づけ)。ch実体(T5-2〜T5-4)とミキサー/
// サンプル生成(T5-5)は後続タスクで追加する。

NR10_ADDR :: 0xFF10
NR11_ADDR :: 0xFF11
NR12_ADDR :: 0xFF12
NR13_ADDR :: 0xFF13
NR14_ADDR :: 0xFF14
NR21_ADDR :: 0xFF16
NR22_ADDR :: 0xFF17
NR23_ADDR :: 0xFF18
NR24_ADDR :: 0xFF19
NR30_ADDR :: 0xFF1A
NR31_ADDR :: 0xFF1B
NR32_ADDR :: 0xFF1C
NR33_ADDR :: 0xFF1D
NR34_ADDR :: 0xFF1E
NR41_ADDR :: 0xFF20
NR42_ADDR :: 0xFF21
NR43_ADDR :: 0xFF22
NR44_ADDR :: 0xFF23
NR50_ADDR :: 0xFF24
NR51_ADDR :: 0xFF25
NR52_ADDR :: 0xFF26
WAVE_RAM_START :: 0xFF30
WAVE_RAM_END :: 0xFF3F

FRAME_SEQUENCER_PERIOD :: 8192 // T-cycle。512Hz = 4194304/8192
APU_MAX_VOLUME :: 15

Envelope_Direction :: enum {
	Decrease,
	Increase,
}

Envelope :: struct {
	initial_volume: int, // NRx2 bit7-4
	direction:       Envelope_Direction, // NRx2 bit3
	period:          int, // NRx2 bit2-0
	timer:           int, // クロックまでの残りステップ数
	volume:          int, // 現在の音量(0-15)
}

Sweep :: struct {
	period:                          int, // NR10 bit6-4
	negate:                          bool, // NR10 bit3
	shift:                           int, // NR10 bit2-0
	timer:                           int,
	shadow_frequency:                int,
	enabled:                         bool,
	negate_calculated_since_trigger: bool, // 落とし穴: negate計算後に正方向へ切替でch停止(T5-2)
}

Pulse_Channel :: struct {
	enabled:        bool,
	dac_enabled:    bool,
	duty:           int, // NRx1 bit7-6
	duty_step:      int, // 0-7
	length_counter: int,
	length_enabled: bool,
	frequency:      int, // 11bit
	timer:          int,
	envelope:       Envelope,
	sweep:          Sweep, // ch2(スイープなし)では未使用。has_sweepは呼び出し側(apu_trigger_pulse)が
	// 引数で指定する(構造体に持たせるとapu_power_offのゼロクリアで消えるため)
}

Wave_Channel :: struct {
	enabled:        bool,
	dac_enabled:    bool, // NR30 bit7
	length_counter: int,
	length_enabled: bool,
	frequency:      int,
	timer:          int,
	position:       int, // 0-31(32サンプル、上位ニブル先)
	output_level:   int, // NR32 bit6-5 を 0/1/2/3 にデコードした値(シフト量ではない)
}

Noise_Channel :: struct {
	enabled:        bool,
	dac_enabled:    bool,
	length_counter: int,
	length_enabled: bool,
	timer:          int,
	lfsr:           u16, // 15bit LFSR(電源投入時 0x7FFF)
	envelope:       Envelope,
}

Apu :: struct {
	powered_on: bool, // NR52 bit7

	frame_sequencer_step:   int, // 0-7、次にfire(未発火)のstep
	frame_sequencer_cycles: int, // 0..FRAME_SEQUENCER_PERIOD-1

	pulse1: Pulse_Channel,
	pulse2: Pulse_Channel,
	wave:   Wave_Channel,
	noise:  Noise_Channel,

	// レジスタの生バイト(読み出しマスクとORして返す。T5-1)。トリガービット(NRx4 bit7)は
	// 処理後クリアして保持する(読み出し自体はマスクで常に1になるが内部状態の整合のため)。
	nr10, nr11, nr12, nr13, nr14: u8,
	nr21, nr22, nr23, nr24:       u8,
	nr30, nr31, nr32, nr33, nr34: u8,
	nr41, nr42, nr43, nr44:       u8,
	nr50, nr51:                   u8,

	wave_ram: [16]u8, // FF30-FF3F。電源off中も読み書き可(T5-1落とし穴)
}

// apu_read_mask は各 NR レジスタの「未使用/書き込み専用ビットは読み出し時1になる」マスクを返す
// (Pan Docs "Audio Registers" の表どおり。dmg_sound 01-registers が最初に検査する)。
// NR52 は専用関数(apu_status_byte)で扱うためここには含めない。
@(private)
apu_read_mask :: proc(addr: u16) -> u8 {
	switch addr {
	case NR10_ADDR:
		return 0x80
	case NR11_ADDR:
		return 0x3F
	case NR12_ADDR:
		return 0x00
	case NR13_ADDR:
		return 0xFF
	case NR14_ADDR:
		return 0xBF
	case NR21_ADDR:
		return 0x3F
	case NR22_ADDR:
		return 0x00
	case NR23_ADDR:
		return 0xFF
	case NR24_ADDR:
		return 0xBF
	case NR30_ADDR:
		return 0x7F
	case NR31_ADDR:
		return 0xFF
	case NR32_ADDR:
		return 0x9F
	case NR33_ADDR:
		return 0xFF
	case NR34_ADDR:
		return 0xBF
	case NR41_ADDR:
		return 0xFF
	case NR42_ADDR:
		return 0x00
	case NR43_ADDR:
		return 0x00
	case NR44_ADDR:
		return 0xBF
	case NR50_ADDR:
		return 0x00
	case NR51_ADDR:
		return 0x00
	case:
		return 0xFF // FF15/FF1F(未使用アドレス)。呼び出し元は通常ここに来ない
	}
}

// apu_status_byte は NR52 の読み出し値(bit7=電源, bit6-4=1固定, bit3-0=各chの動作中フラグ)。
@(private)
apu_status_byte :: proc(apu: ^Apu) -> u8 {
	bits: u8 = 0x70
	if !apu.powered_on {
		return bits
	}
	bits |= 0x80
	if apu.pulse1.enabled {
		bits |= 0x01
	}
	if apu.pulse2.enabled {
		bits |= 0x02
	}
	if apu.wave.enabled {
		bits |= 0x04
	}
	if apu.noise.enabled {
		bits |= 0x08
	}
	return bits
}

// apu_power_on はブート完了直後のAPU状態を直接セットする(実BIOS非対応方針、ppu_power_onと同じ
// 位置づけ)。NR50/NR51 のみ Pan Docs の実測既定値を反映し、各chの音源レジスタは0のまま
// (Blargg等のROMは通常自前で全chを再設定するため厳密な忠実さより単純さを優先、T5-1)。
apu_power_on :: proc(apu: ^Apu) {
	apu.powered_on = true
	apu.nr50 = 0x77
	apu.nr51 = 0xF3
	apu.noise.lfsr = 0x7FFF
}

// apu_power_off は NR52 電源offの効果を適用する: NR10-NR51 とch状態をクリアするが、
// wave RAM とDMGの length カウンタ/length_enabled は保持する(T5-1落とし穴、dmg_sound
// 08-len ctr during power / 11-regs after power が検査)。
@(private)
apu_power_off :: proc(apu: ^Apu) {
	apu.powered_on = false

	apu.nr10, apu.nr11, apu.nr12, apu.nr13, apu.nr14 = 0, 0, 0, 0, 0
	apu.nr21, apu.nr22, apu.nr23, apu.nr24 = 0, 0, 0, 0
	apu.nr30, apu.nr31, apu.nr32, apu.nr33, apu.nr34 = 0, 0, 0, 0, 0
	apu.nr41, apu.nr42, apu.nr43, apu.nr44 = 0, 0, 0, 0
	apu.nr50, apu.nr51 = 0, 0

	saved_len1, saved_len_en1 := apu.pulse1.length_counter, apu.pulse1.length_enabled
	saved_len2, saved_len_en2 := apu.pulse2.length_counter, apu.pulse2.length_enabled
	saved_len3, saved_len_en3 := apu.wave.length_counter, apu.wave.length_enabled
	saved_len4, saved_len_en4 := apu.noise.length_counter, apu.noise.length_enabled

	apu.pulse1 = Pulse_Channel{}
	apu.pulse2 = Pulse_Channel{}
	apu.wave = Wave_Channel{}
	apu.noise = Noise_Channel{}

	apu.pulse1.length_counter, apu.pulse1.length_enabled = saved_len1, saved_len_en1
	apu.pulse2.length_counter, apu.pulse2.length_enabled = saved_len2, saved_len_en2
	apu.wave.length_counter, apu.wave.length_enabled = saved_len3, saved_len_en3
	apu.noise.length_counter, apu.noise.length_enabled = saved_len4, saved_len_en4

	apu.frame_sequencer_step = 0
	apu.frame_sequencer_cycles = 0
}

// apu_clock_length_pulse/_wave/_noise はフレームシーケンサの length クロック(step 0,2,4,6)。
// T5-1時点では各chは常時 enabled=false のため実質何もしないが、フレームシーケンサの
// 巡回そのものはT5-1の範囲(ch実体はT5-2〜T5-4で追加)。
@(private)
apu_clock_length_pulse :: proc(ch: ^Pulse_Channel) {
	if ch.enabled && ch.length_enabled && ch.length_counter > 0 {
		ch.length_counter -= 1
		if ch.length_counter == 0 {
			ch.enabled = false
		}
	}
}

@(private)
apu_clock_length_wave :: proc(ch: ^Wave_Channel) {
	if ch.enabled && ch.length_enabled && ch.length_counter > 0 {
		ch.length_counter -= 1
		if ch.length_counter == 0 {
			ch.enabled = false
		}
	}
}

@(private)
apu_clock_length_noise :: proc(ch: ^Noise_Channel) {
	if ch.enabled && ch.length_enabled && ch.length_counter > 0 {
		ch.length_counter -= 1
		if ch.length_counter == 0 {
			ch.enabled = false
		}
	}
}

// apu_clock_envelope はボリュームエンベロープを1ステップ進める(step 7、T5-2で実質稼働)。
@(private)
apu_clock_envelope :: proc(env: ^Envelope) {
	if env.period == 0 {
		return
	}
	env.timer -= 1
	if env.timer > 0 {
		return
	}
	env.timer = env.period
	delta := env.direction == .Increase ? 1 : -1
	next_volume := env.volume + delta
	if next_volume >= 0 && next_volume <= APU_MAX_VOLUME {
		env.volume = next_volume
	}
}

// apu_pulse_period は矩形波chの周期タイマーの再ロード値を返す((2048-freq)*4 T-cycle)。
@(private)
apu_pulse_period :: proc(frequency: int) -> int {
	return (2048 - frequency) * 4
}

// apu_sweep_calculate はスイープの周波数計算を行い、オーバーフロー(>2047)なら overflow=true
// を返す(値そのものは適用しない、呼び出し側が判断する)。negate方向を使った場合は
// negate_calculated_since_trigger を立てる(NR10落とし穴: negate使用後の正方向切替でch停止、
// T5-2「落とし穴」)。shift=0でも計算自体は行う(shift0でdelta=shadow自体になり2倍加算に
// なるため、period>0のsweepはshift0でもオーバーフローしうる。Pan Docsの記述に基づく)。
@(private)
apu_sweep_calculate :: proc(sweep: ^Sweep) -> (new_freq: int, overflow: bool) {
	delta := sweep.shadow_frequency >> uint(sweep.shift)
	if sweep.negate {
		new_freq = sweep.shadow_frequency - delta
		sweep.negate_calculated_since_trigger = true
	} else {
		new_freq = sweep.shadow_frequency + delta
	}
	overflow = new_freq > 2047 // 負値にはなりえない(delta<=shadow、Pan Docs "cannot underflow")
	return
}

// apu_sweep_clock は ch1 のスイープを1ステップ進める(step 2,6)。
@(private)
apu_sweep_clock :: proc(pulse1: ^Pulse_Channel) {
	sweep := &pulse1.sweep
	if !pulse1.enabled || !sweep.enabled {
		return
	}
	sweep.timer -= 1
	if sweep.timer > 0 {
		return
	}
	sweep.timer = sweep.period == 0 ? 8 : sweep.period

	if sweep.period == 0 {
		return // 周期0はイテレーション無し(タイマーのリロードのみ行う)
	}
	if sweep.shift == 0 {
		return // shift=0では計算そのものを行わない(shift>>0=shadow自体になり誤って
		// 倍加/オーバーフロー判定してしまうのを防ぐ。NR10=0x00でスイープ無効の
		// 一般的なケースがこれで壊れないようにする)
	}

	new_freq, overflow := apu_sweep_calculate(sweep)
	if overflow {
		pulse1.enabled = false
		return
	}
	sweep.shadow_frequency = new_freq
	pulse1.frequency = new_freq
	pulse1.timer = apu_pulse_period(new_freq)
	// 2回目のオーバーフロー判定(次回の反映に備えた事前チェック、実機仕様)。
	_, overflow2 := apu_sweep_calculate(sweep)
	if overflow2 {
		pulse1.enabled = false
	}
}

// apu_trigger_pulse はNRx4トリガー(bit7=1)時の共通初期化。has_sweep=trueはch1用で
// スイープのshadow初期化とトリガー時オーバーフロー即時判定(dmg_sound "06-overflow on
// trigger")も行う。
@(private)
apu_trigger_pulse :: proc(ch: ^Pulse_Channel, has_sweep: bool) {
	ch.envelope.volume = ch.envelope.initial_volume
	ch.envelope.timer = ch.envelope.period
	ch.duty_step = 0
	ch.timer = apu_pulse_period(ch.frequency)

	if has_sweep {
		ch.sweep.shadow_frequency = ch.frequency
		ch.sweep.timer = ch.sweep.period == 0 ? 8 : ch.sweep.period
		ch.sweep.enabled = ch.sweep.period != 0 || ch.sweep.shift != 0
		ch.sweep.negate_calculated_since_trigger = false
		// オーバーフロー判定はshift!=0のときのみ実際に計算が走る(shift=0でshadow自体を
		// deltaにしてしまい誤検出するのを防ぐ。dmg_sound "06-overflow on trigger" 対象)。
		if ch.sweep.shift != 0 {
			_, overflow := apu_sweep_calculate(&ch.sweep)
			if overflow {
				ch.enabled = false
				return
			}
		}
	}

	ch.enabled = ch.dac_enabled
}

// apu_apply_length_and_trigger は NRx4 書き込み共通の length/trigger 処理。Pan Docs
// "Audio details" の obscure 挙動を反映する(T5-2落とし穴):
//   1. 「次のフレームシーケンサ step が length を刻まない」タイミングで length_enable を
//      無効→有効に切り替えると、length_counter を即座に1減らす(0になったら即ch停止、
//      ただしこのタイミングでトリガーもされているなら停止しない)
//   2. トリガー時に length_counter が0なら max にリロードするが、上と同じ条件が
//      成立していれば max-1 にする(dmg_sound 02-len ctr / 03-trigger が検査)
@(private)
apu_apply_length_and_trigger :: proc(
	length_counter: ^int,
	length_enabled: ^bool,
	enabled: ^bool,
	apu: ^Apu,
	new_length_enabled: bool,
	trigger: bool,
	max_length: int,
) {
	next_step_clocks_length := apu.frame_sequencer_step % 2 == 0
	was_enabled := length_enabled^

	if !next_step_clocks_length && !was_enabled && new_length_enabled && length_counter^ > 0 {
		length_counter^ -= 1
		if length_counter^ == 0 && !trigger {
			enabled^ = false
		}
	}

	length_enabled^ = new_length_enabled

	if trigger && length_counter^ == 0 {
		length_counter^ = max_length
		if !next_step_clocks_length && new_length_enabled {
			length_counter^ -= 1
		}
	}
}

// apu_write_nr10 は NR10(スイープ)への書き込み。negateから正方向へ切り替えた際、
// トリガー以降にnegate計算を1回でも使っていればchを即停止する(T5-2落とし穴)。
@(private)
apu_write_nr10 :: proc(pulse1: ^Pulse_Channel, value: u8) {
	old_negate := pulse1.sweep.negate
	pulse1.sweep.period = int((value >> 4) & 0x07)
	pulse1.sweep.shift = int(value & 0x07)
	new_negate := value & 0x08 != 0
	if old_negate && !new_negate && pulse1.sweep.negate_calculated_since_trigger {
		pulse1.enabled = false
	}
	pulse1.sweep.negate = new_negate
}

// apu_tick_pulse は矩形波chの周期タイマーを1 T-cycle進める(T5-2)。
@(private)
apu_tick_pulse :: proc(ch: ^Pulse_Channel) {
	if !ch.enabled {
		return
	}
	ch.timer -= 1
	if ch.timer <= 0 {
		ch.timer += apu_pulse_period(ch.frequency)
		ch.duty_step = (ch.duty_step + 1) & 0x07
	}
}

// --- ch3: 波形メモリ(T5-3) ---

// apu_wave_period は ch3 の周期タイマーの再ロード値を返す((2048-freq)*2 T-cycle、
// 矩形波chの半分。32サンプルを1周期で再生するため)。
@(private)
apu_wave_period :: proc(frequency: int) -> int {
	return (2048 - frequency) * 2
}

// apu_wave_current_nibble は wave.position(0-31)が指す4bitサンプルを返す。FF30-FF3Fの
// 16バイトは32サンプルで、各バイトは上位ニブルが先(position偶数=上位、奇数=下位、T5-3)。
apu_wave_current_nibble :: proc(apu: ^Apu) -> u8 {
	byte_val := apu.wave_ram[apu.wave.position / 2]
	if apu.wave.position % 2 == 0 {
		return byte_val >> 4
	}
	return byte_val & 0x0F
}

// apu_tick_wave は ch3 の周期タイマーを1 T-cycle進める(T5-3)。
@(private)
apu_tick_wave :: proc(apu: ^Apu) {
	ch := &apu.wave
	if !ch.enabled {
		return
	}
	ch.timer -= 1
	if ch.timer <= 0 {
		ch.timer += apu_wave_period(ch.frequency)
		ch.position = (ch.position + 1) & 0x1F
	}
}

// apu_trigger_wave はch3のNR34トリガー(bit7=1)時の初期化: 周期タイマーとposition(0番地から
// 再生開始)をリセットし、DAC onならch有効にする(T5-3)。
@(private)
apu_trigger_wave :: proc(apu: ^Apu) {
	apu.wave.timer = apu_wave_period(apu.wave.frequency)
	apu.wave.position = 0
	apu.wave.enabled = apu.wave.dac_enabled
}

// apu_clock_frame_sequencer は512Hzのフレームシーケンサを1step進める。
// length は step 0,2,4,6 / エンベロープは step 7 / スイープは step 2,6。
@(private)
apu_clock_frame_sequencer :: proc(apu: ^Apu) {
	step := apu.frame_sequencer_step

	if step == 0 || step == 2 || step == 4 || step == 6 {
		apu_clock_length_pulse(&apu.pulse1)
		apu_clock_length_pulse(&apu.pulse2)
		apu_clock_length_wave(&apu.wave)
		apu_clock_length_noise(&apu.noise)
	}
	if step == 2 || step == 6 {
		apu_sweep_clock(&apu.pulse1)
	}
	if step == 7 {
		apu_clock_envelope(&apu.pulse1.envelope)
		apu_clock_envelope(&apu.pulse2.envelope)
		apu_clock_envelope(&apu.noise.envelope)
	}

	apu.frame_sequencer_step = (step + 1) & 0x07
}

// apu_notify_div_write は DIV(0xFF04)書き込み時の副作用(timer.odin の timer_write_div から
// 呼ばれる)。内部16bitカウンタのbit12(DIVレジスタのbit4相当)が1→0に落ちる場合、
// フレームシーケンサが1回余分に進む(実機のDIV-APUカウンタ仕様。dmg_sound 07-len sweep
// period sync が関連する)。呼び出し時点ではまだ bus.div_counter はリセットされていない
// (=旧値)ことを前提にする。
apu_notify_div_write :: proc(apu: ^Apu, old_div_counter: u16) {
	if !apu.powered_on {
		return
	}
	if old_div_counter & 0x1000 != 0 {
		apu_clock_frame_sequencer(apu)
	}
	apu.frame_sequencer_cycles = 0
}

// apu_tick は t_cycles(通常4、M-cycle単位)ぶんAPUを進める。bus_tick から呼ばれる
// (architecture.md のタイミングモデル)。T5-1時点ではフレームシーケンサの巡回のみ
// (ch進行・サンプル生成はT5-2〜T5-5で追加)。
apu_tick :: proc(apu: ^Apu, t_cycles: int) {
	if !apu.powered_on {
		return
	}
	for _ in 0 ..< t_cycles {
		apu.frame_sequencer_cycles += 1
		if apu.frame_sequencer_cycles >= FRAME_SEQUENCER_PERIOD {
			apu.frame_sequencer_cycles -= FRAME_SEQUENCER_PERIOD
			apu_clock_frame_sequencer(apu)
		}

		apu_tick_pulse(&apu.pulse1)
		apu_tick_pulse(&apu.pulse2)
		apu_tick_wave(apu)
	}
}

// apu_read_register は FF10-FF26 / FF30-FF3F への読み出しを処理する(bus_io_read から呼ぶ)。
apu_read_register :: proc(apu: ^Apu, addr: u16) -> u8 {
	if addr == NR52_ADDR {
		return apu_status_byte(apu)
	}
	if addr >= WAVE_RAM_START && addr <= WAVE_RAM_END {
		return apu.wave_ram[addr - WAVE_RAM_START] // 電源off中も読める(T5-1落とし穴)
	}

	raw: u8
	switch addr {
	case NR10_ADDR:
		raw = apu.nr10
	case NR11_ADDR:
		raw = apu.nr11
	case NR12_ADDR:
		raw = apu.nr12
	case NR13_ADDR:
		raw = apu.nr13
	case NR14_ADDR:
		raw = apu.nr14
	case NR21_ADDR:
		raw = apu.nr21
	case NR22_ADDR:
		raw = apu.nr22
	case NR23_ADDR:
		raw = apu.nr23
	case NR24_ADDR:
		raw = apu.nr24
	case NR30_ADDR:
		raw = apu.nr30
	case NR31_ADDR:
		raw = apu.nr31
	case NR32_ADDR:
		raw = apu.nr32
	case NR33_ADDR:
		raw = apu.nr33
	case NR34_ADDR:
		raw = apu.nr34
	case NR41_ADDR:
		raw = apu.nr41
	case NR42_ADDR:
		raw = apu.nr42
	case NR43_ADDR:
		raw = apu.nr43
	case NR44_ADDR:
		raw = apu.nr44
	case NR50_ADDR:
		raw = apu.nr50
	case NR51_ADDR:
		raw = apu.nr51
	case:
		return 0xFF // FF15/FF1F
	}
	return raw | apu_read_mask(addr)
}

// apu_write_register は FF10-FF26 / FF30-FF3F への書き込みを処理する(bus_io_write から呼ぶ)。
// 電源off中は NR52 と wave RAM、そして DMG の例外(NRx1 の length データ)以外の書き込みは
// 無視される(Pan Docs footnote、T5-1落とし穴)。
// T5-1時点ではレジスタの生バイト保存・length/DAC有効フラグの反映のみ行い、トリガー/duty/
// 周波数追従等の実際のch挙動はT5-2〜T5-4で追加する(ch.enabledは常にfalseのまま)。
apu_write_register :: proc(apu: ^Apu, addr: u16, value: u8) {
	if addr == NR52_ADDR {
		was_on := apu.powered_on
		is_on := value & 0x80 != 0
		if was_on && !is_on {
			apu_power_off(apu)
		} else if !was_on && is_on {
			apu.powered_on = true
			apu.frame_sequencer_step = 0
			apu.frame_sequencer_cycles = 0
		}
		return
	}

	if addr >= WAVE_RAM_START && addr <= WAVE_RAM_END {
		apu.wave_ram[addr - WAVE_RAM_START] = value // 電源off中も書き込み可(T5-1落とし穴)
		return
	}

	is_length_reg := addr == NR11_ADDR || addr == NR21_ADDR || addr == NR31_ADDR || addr == NR41_ADDR
	if !apu.powered_on && !is_length_reg {
		return
	}

	switch addr {
	case NR10_ADDR:
		apu.nr10 = value
		apu_write_nr10(&apu.pulse1, value)
	case NR11_ADDR:
		apu.nr11 = value
		apu.pulse1.duty = int(value >> 6)
		apu.pulse1.length_counter = 64 - int(value & 0x3F)
	case NR12_ADDR:
		apu.nr12 = value
		apu.pulse1.envelope.initial_volume = int(value >> 4)
		apu.pulse1.envelope.direction = value & 0x08 != 0 ? .Increase : .Decrease
		apu.pulse1.envelope.period = int(value & 0x07)
		apu.pulse1.dac_enabled = value & 0xF8 != 0
		if !apu.pulse1.dac_enabled {
			apu.pulse1.enabled = false
		}
	case NR13_ADDR:
		apu.nr13 = value
		apu.pulse1.frequency = (apu.pulse1.frequency & 0x700) | int(value)
	case NR14_ADDR:
		trigger := value & 0x80 != 0
		new_length_enabled := value & 0x40 != 0
		apu.nr14 = value & 0x7F // トリガービットはクリアして保持
		apu.pulse1.frequency = (apu.pulse1.frequency & 0x0FF) | (int(value & 0x07) << 8)
		apu_apply_length_and_trigger(
			&apu.pulse1.length_counter,
			&apu.pulse1.length_enabled,
			&apu.pulse1.enabled,
			apu,
			new_length_enabled,
			trigger,
			64,
		)
		if trigger {
			apu_trigger_pulse(&apu.pulse1, true)
		}

	case NR21_ADDR:
		apu.nr21 = value
		apu.pulse2.duty = int(value >> 6)
		apu.pulse2.length_counter = 64 - int(value & 0x3F)
	case NR22_ADDR:
		apu.nr22 = value
		apu.pulse2.envelope.initial_volume = int(value >> 4)
		apu.pulse2.envelope.direction = value & 0x08 != 0 ? .Increase : .Decrease
		apu.pulse2.envelope.period = int(value & 0x07)
		apu.pulse2.dac_enabled = value & 0xF8 != 0
		if !apu.pulse2.dac_enabled {
			apu.pulse2.enabled = false
		}
	case NR23_ADDR:
		apu.nr23 = value
		apu.pulse2.frequency = (apu.pulse2.frequency & 0x700) | int(value)
	case NR24_ADDR:
		trigger := value & 0x80 != 0
		new_length_enabled := value & 0x40 != 0
		apu.nr24 = value & 0x7F
		apu.pulse2.frequency = (apu.pulse2.frequency & 0x0FF) | (int(value & 0x07) << 8)
		apu_apply_length_and_trigger(
			&apu.pulse2.length_counter,
			&apu.pulse2.length_enabled,
			&apu.pulse2.enabled,
			apu,
			new_length_enabled,
			trigger,
			64,
		)
		if trigger {
			apu_trigger_pulse(&apu.pulse2, false)
		}

	case NR30_ADDR:
		apu.nr30 = value
		apu.wave.dac_enabled = value & 0x80 != 0
		if !apu.wave.dac_enabled {
			apu.wave.enabled = false
		}
	case NR31_ADDR:
		apu.nr31 = value
		apu.wave.length_counter = 256 - int(value)
	case NR32_ADDR:
		apu.nr32 = value
		apu.wave.output_level = int((value >> 5) & 0x03)
	case NR33_ADDR:
		apu.nr33 = value
		apu.wave.frequency = (apu.wave.frequency & 0x700) | int(value)
	case NR34_ADDR:
		trigger := value & 0x80 != 0
		new_length_enabled := value & 0x40 != 0
		apu.nr34 = value & 0x7F
		apu.wave.frequency = (apu.wave.frequency & 0x0FF) | (int(value & 0x07) << 8)
		apu_apply_length_and_trigger(
			&apu.wave.length_counter,
			&apu.wave.length_enabled,
			&apu.wave.enabled,
			apu,
			new_length_enabled,
			trigger,
			256,
		)
		if trigger {
			apu_trigger_wave(apu)
		}

	case NR41_ADDR:
		apu.nr41 = value
		apu.noise.length_counter = 64 - int(value & 0x3F)
	case NR42_ADDR:
		apu.nr42 = value
		apu.noise.dac_enabled = value & 0xF8 != 0
		if !apu.noise.dac_enabled {
			apu.noise.enabled = false
		}
	case NR43_ADDR:
		apu.nr43 = value
	case NR44_ADDR:
		apu.nr44 = value & 0x7F
		apu.noise.length_enabled = value & 0x40 != 0

	case NR50_ADDR:
		apu.nr50 = value
	case NR51_ADDR:
		apu.nr51 = value
	}
}
