package core

// ステートのシリアライズ/復元(T7-1/T7-2)。
// フォーマット: マジック"BBLS"(4B) + フォーマットバージョンu32(=1) + ROMヘッダのグローバル
// チェックサム(0x014E-0x014F、2B) + 本体。すべてリトルエンディアン(architecture.md)。
//
// 本体には ROM 自体を含めない(チェックサムで同一カートリッジであることを確認するのみ)。
// リングバッファのインデックス(apu.ring*)や Mooneye 判定用デバッグフラグ
// (cpu.debug_break_on_ld_b_b/ld_b_b_hit)、シリアル出力キャプチャ(bus.serial_log、テスト専用)も
// 保存しない(phase-07-savestate.md「落とし穴」)。
//
// 設計: 本体サイズは「現在ロードされているカートリッジの構成(MBC種別・外部RAMサイズ)」から
// 一意に決まる(可変長要素は外部RAMだけで、そのサイズは同じROMを前提にする限り不変)。
// savestate_expected_size がこのサイズを計算し、write はこのサイズちょうどのバッファへ、
// read は decode 前に len(data) がこのサイズ以上であることを確認する。これにより
// 「読み込み中に範囲外アクセスが起きる」ことを構造的に防ぎ、T7-2 の「現在の状態を壊さない」
// (全フィールド読み取り成功が保証されてから初めて emu へ書き込む)を単純な事前サイズ検査だけで
// 満たす。

SAVESTATE_MAGIC :: "BBLS"
SAVESTATE_FORMAT_VERSION :: u32(1)
SAVESTATE_HEADER_SIZE :: 4 + 4 + 2 // マジック + バージョン + ROMチェックサム

Load_Error :: enum {
	None,
	Bad_Magic,
	Version_Mismatch,
	Rom_Checksum_Mismatch,
	Too_Small,
}

// --- カーソル(書き込み/読み出し共通の位置管理) ---
// 事前にバッファサイズを確定させてから使うため、範囲外アクセスは起きない前提(上記設計参照)。

@(private = "file")
Cursor :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
put_u8 :: proc(c: ^Cursor, v: u8) {
	c.data[c.pos] = v
	c.pos += 1
}

@(private = "file")
get_u8 :: proc(c: ^Cursor) -> u8 {
	v := c.data[c.pos]
	c.pos += 1
	return v
}

@(private = "file")
put_bool :: proc(c: ^Cursor, v: bool) {
	put_u8(c, v ? 1 : 0)
}

@(private = "file")
get_bool :: proc(c: ^Cursor) -> bool {
	return get_u8(c) != 0
}

@(private = "file")
put_u16 :: proc(c: ^Cursor, v: u16) {
	put_u8(c, u8(v))
	put_u8(c, u8(v >> 8))
}

@(private = "file")
get_u16 :: proc(c: ^Cursor) -> u16 {
	lo := u16(get_u8(c))
	hi := u16(get_u8(c))
	return lo | (hi << 8)
}

@(private = "file")
put_u32 :: proc(c: ^Cursor, v: u32) {
	put_u8(c, u8(v))
	put_u8(c, u8(v >> 8))
	put_u8(c, u8(v >> 16))
	put_u8(c, u8(v >> 24))
}

@(private = "file")
get_u32 :: proc(c: ^Cursor) -> u32 {
	b0 := u32(get_u8(c))
	b1 := u32(get_u8(c))
	b2 := u32(get_u8(c))
	b3 := u32(get_u8(c))
	return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

// put_int/get_int は Odin の int(64bit環境で8バイト)をファイル上は常に符号付き32bitで
// 固定する(architecture.md のバイト順規約に加え、フォーマットをホストのポインタ幅に
// 依存させないため)。PPU の dot 等、実際に扱う値は十分 32bit に収まる。
@(private = "file")
put_int :: proc(c: ^Cursor, v: int) {
	put_u32(c, u32(i32(v)))
}

@(private = "file")
get_int :: proc(c: ^Cursor) -> int {
	return int(i32(get_u32(c)))
}

@(private = "file")
put_u64 :: proc(c: ^Cursor, v: u64) {
	put_u32(c, u32(v))
	put_u32(c, u32(v >> 32))
}

@(private = "file")
get_u64 :: proc(c: ^Cursor) -> u64 {
	lo := u64(get_u32(c))
	hi := u64(get_u32(c))
	return lo | (hi << 32)
}

@(private = "file")
put_i64 :: proc(c: ^Cursor, v: i64) {
	put_u64(c, u64(v))
}

@(private = "file")
get_i64 :: proc(c: ^Cursor) -> i64 {
	return i64(get_u64(c))
}

@(private = "file")
put_bytes :: proc(c: ^Cursor, v: []u8) {
	copy(c.data[c.pos:c.pos + len(v)], v)
	c.pos += len(v)
}

@(private = "file")
get_bytes :: proc(c: ^Cursor, dst: []u8) {
	copy(dst, c.data[c.pos:c.pos + len(dst)])
	c.pos += len(dst)
}

// --- サイズ計算 ---

CPU_STATE_SIZE :: 8 /*a,f,b,c,d,e,h,l*/ + 2 /*sp*/ + 2 /*pc*/ + 1 /*ime*/ + 1 /*halted*/ + 1 /*halt_bug*/ + 4 /*ime_delay*/ + 1 /*stopped*/ + 1 /*illegal_opcode_hit*/

TIMER_STATE_SIZE :: 2 /*div_counter*/ + 1 /*tima*/ + 1 /*tma*/ + 1 /*tac*/ + 4 /*timer_reload_pending*/ + 1 /*timer_reload_just_happened*/

PPU_STATE_SIZE :: 11 /*lcdc,stat_enable,scy,scx,ly,lyc,bgp,obp0,obp1,wy,wx*/ + 1 /*mode*/ + 1 /*lyc_equal*/ + 4 /*dot*/ + 4 /*window_line*/ + 1 /*stat_irq_line*/ + (SCREEN_WIDTH * SCREEN_HEIGHT * 4) /*framebuffer*/

JOYPAD_STATE_SIZE :: 1 + 1 + 1 // joyp_select_action, joyp_select_direction, joyp_pressed

DMA_STATE_SIZE :: 1 /*dma_active*/ + 2 /*dma_source*/ + 4 /*dma_index*/ + 4 /*dma_start_delay*/ + 2 /*dma_pending_source*/

HDMA_STATE_SIZE :: 2 /*source*/ + 2 /*destination*/ + 4 /*remaining*/ + 1 /*active*/ + 1 /*aborted*/ + 4 /*aborted_remaining*/

ENVELOPE_SIZE :: 4 /*initial_volume*/ + 1 /*direction*/ + 4 /*period*/ + 4 /*timer*/ + 4 /*volume*/
SWEEP_SIZE :: 4 /*period*/ + 1 /*negate*/ + 4 /*shift*/ + 4 /*timer*/ + 4 /*shadow_frequency*/ + 1 /*enabled*/ + 1 /*negate_calculated_since_trigger*/

PULSE_CHANNEL_SIZE :: 1 /*enabled*/ + 1 /*dac_enabled*/ + 4 /*duty*/ + 4 /*duty_step*/ + 4 /*length_counter*/ + 1 /*length_enabled*/ + 4 /*frequency*/ + 4 /*timer*/ + ENVELOPE_SIZE + SWEEP_SIZE

WAVE_CHANNEL_SIZE :: 1 /*enabled*/ + 1 /*dac_enabled*/ + 4 /*length_counter*/ + 1 /*length_enabled*/ + 4 /*frequency*/ + 4 /*timer*/ + 4 /*position*/ + 4 /*output_level*/

NOISE_CHANNEL_SIZE :: 1 /*enabled*/ + 1 /*dac_enabled*/ + 4 /*length_counter*/ + 1 /*length_enabled*/ + 4 /*timer*/ + 2 /*lfsr*/ + ENVELOPE_SIZE

APU_NR_REGS_SIZE :: 20 // nr10-nr14,nr21-nr24,nr30-nr34,nr41-nr44,nr50,nr51

APU_STATE_SIZE :: 1 /*powered_on*/ + 4 /*frame_sequencer_step*/ + 4 /*frame_sequencer_cycles*/ + PULSE_CHANNEL_SIZE * 2 + WAVE_CHANNEL_SIZE + NOISE_CHANNEL_SIZE + APU_NR_REGS_SIZE + 16 /*wave_ram*/ + 4 /*sample_counter*/

BUS_SCALAR_SIZE :: 1 /*mode*/ + 1 /*vram_bank*/ + 1 /*wram_bank*/ + 8 /*cycles*/ + 8 /*hw_cycles*/ + 1 /*double_speed*/ + 1 /*speed_switch_prepared*/ + 1 /*bcps*/ + 1 /*ocps*/

BUS_LARGE_ARRAYS_SIZE :: (2 * VRAM_BANK_SIZE) + (8 * WRAM_BANK_SIZE) + OAM_SIZE + 127 /*hram*/ + 128 /*io*/ + 1 /*ie*/ + PALETTE_RAM_SIZE + PALETTE_RAM_SIZE /*bg+obj palette*/

// mbc_state_size は現在ロードされている MBC 種別に応じた「タグ1バイト+中身」のサイズを返す。
@(private = "file")
mbc_state_size :: proc(cart: ^Cartridge) -> int {
	switch _ in cart.mbc {
	case Mbc_None:
		return 1
	case Mbc1_State:
		return 1 + 1 /*ram_enabled*/ + 1 /*rom_bank_low5*/ + 1 /*bank_high2*/ + 1 /*mode*/
	case Mbc2_State:
		return 1 + 1 /*ram_enabled*/ + 1 /*rom_bank*/ + 512 /*ram*/
	case Mbc3_State:
		return 1 + 1 /*ram_enabled*/ + 1 /*rom_bank*/ + 1 /*ram_or_rtc_select*/ + 5 /*rtc*/ + 5 /*latched_rtc*/ + 1 /*latch_prepared*/ + 8 /*rtc_base_unix*/
	case Mbc5_State:
		return 1 + 1 /*ram_enabled*/ + 1 /*rom_bank_low8*/ + 1 /*rom_bank_high1*/ + 1 /*ram_bank*/
	}
	return 1
}

// savestate_expected_size は現在ロードされているカートリッジの構成(MBC種別・外部RAMサイズ)から
// 決まる本体サイズ(ヘッダ含む)を計算する。write はこのサイズちょうどのバッファを作り、
// read は decode 前に len(data) がこの値以上かを確認する(T7-2、上記コメント参照)。
savestate_expected_size :: proc(emu: ^Emulator) -> int {
	return(
		SAVESTATE_HEADER_SIZE +
		CPU_STATE_SIZE +
		BUS_SCALAR_SIZE +
		BUS_LARGE_ARRAYS_SIZE +
		HDMA_STATE_SIZE +
		TIMER_STATE_SIZE +
		PPU_STATE_SIZE +
		JOYPAD_STATE_SIZE +
		DMA_STATE_SIZE +
		APU_STATE_SIZE +
		mbc_state_size(&emu.bus.cart) +
		len(emu.bus.cart.ram) \
	)
}

// rom_header_checksum は ROM ヘッダのグローバルチェックサム(0x014E-0x014F、ビッグエンディアン
//格納だが本関数はそのまま2バイトの値として読み出すだけ)を返す。カートリッジロード成功時は
// 必ず HEADER_MIN_LEN(0x150)以上の長さがあることが保証されている(cartridge_parse_header)。
@(private = "file")
rom_header_checksum :: proc(rom: []u8) -> u16 {
	if len(rom) < 0x150 {
		return 0
	}
	return (u16(rom[0x014E]) << 8) | u16(rom[0x014F])
}

// --- 書き込み ---

savestate_write :: proc(emu: ^Emulator) -> []u8 {
	size := savestate_expected_size(emu)
	buf := make([]u8, size)
	c := Cursor{data = buf}

	// ヘッダ
	put_bytes(&c, transmute([]u8)string(SAVESTATE_MAGIC))
	put_u32(&c, SAVESTATE_FORMAT_VERSION)
	put_u16(&c, rom_header_checksum(emu.bus.cart.rom))

	write_cpu_state(&c, &emu.cpu)
	write_bus_state(&c, &emu.bus)

	// 内部不変条件: 実際に書き込んだバイト数は savestate_expected_size の計算値とちょうど
	// 一致するはず(read 側はこのサイズ計算だけを頼りに範囲外アクセスを避けているため、
	// ここがずれると静かに壊れる。フォーマット変更時にサイズ計算の更新漏れを即検出する)。
	assert(c.pos == size, "savestate_write: 書き込みバイト数が savestate_expected_size と一致しない")

	return buf
}

@(private = "file")
write_cpu_state :: proc(c: ^Cursor, cpu: ^Cpu) {
	put_u8(c, cpu.a)
	put_u8(c, cpu.f)
	put_u8(c, cpu.b)
	put_u8(c, cpu.c)
	put_u8(c, cpu.d)
	put_u8(c, cpu.e)
	put_u8(c, cpu.h)
	put_u8(c, cpu.l)
	put_u16(c, cpu.sp)
	put_u16(c, cpu.pc)
	put_bool(c, cpu.ime)
	put_bool(c, cpu.halted)
	put_bool(c, cpu.halt_bug)
	put_int(c, cpu.ime_delay)
	put_bool(c, cpu.stopped)
	put_bool(c, cpu.illegal_opcode_hit)
}

@(private = "file")
read_cpu_state :: proc(c: ^Cursor, cpu: ^Cpu) {
	cpu.a = get_u8(c)
	cpu.f = get_u8(c)
	cpu.b = get_u8(c)
	cpu.c = get_u8(c)
	cpu.d = get_u8(c)
	cpu.e = get_u8(c)
	cpu.h = get_u8(c)
	cpu.l = get_u8(c)
	cpu.sp = get_u16(c)
	cpu.pc = get_u16(c)
	cpu.ime = get_bool(c)
	cpu.halted = get_bool(c)
	cpu.halt_bug = get_bool(c)
	cpu.ime_delay = get_int(c)
	cpu.stopped = get_bool(c)
	cpu.illegal_opcode_hit = get_bool(c)
}

@(private = "file")
write_bus_state :: proc(c: ^Cursor, bus: ^Bus) {
	put_u8(c, u8(bus.mode))
	put_u8(c, bus.vram_bank)
	put_u8(c, bus.wram_bank)
	put_u64(c, bus.cycles)
	put_u64(c, bus.hw_cycles)
	put_bool(c, bus.double_speed)
	put_bool(c, bus.speed_switch_prepared)
	put_u8(c, bus.bcps)
	put_u8(c, bus.ocps)

	for bank in 0 ..< 2 {
		put_bytes(c, bus.vram[bank][:])
	}
	for bank in 0 ..< 8 {
		put_bytes(c, bus.wram[bank][:])
	}
	put_bytes(c, bus.oam[:])
	put_bytes(c, bus.hram[:])
	put_bytes(c, bus.io[:])
	put_u8(c, bus.ie)
	put_bytes(c, bus.bg_palette_ram[:])
	put_bytes(c, bus.obj_palette_ram[:])

	put_u16(c, bus.hdma_source)
	put_u16(c, bus.hdma_destination)
	put_int(c, bus.hdma_remaining)
	put_bool(c, bus.hdma_active)
	put_bool(c, bus.hdma_aborted)
	put_int(c, bus.hdma_aborted_remaining)

	write_timer_state(c, bus)
	write_ppu_state(c, &bus.ppu)

	put_bool(c, bus.joyp_select_action)
	put_bool(c, bus.joyp_select_direction)
	put_u8(c, bus.joyp_pressed)

	put_bool(c, bus.dma_active)
	put_u16(c, bus.dma_source)
	put_int(c, bus.dma_index)
	put_int(c, bus.dma_start_delay)
	put_u16(c, bus.dma_pending_source)

	write_apu_state(c, &bus.apu)
	write_mbc_state(c, &bus.cart)
	put_bytes(c, bus.cart.ram)
}

@(private = "file")
read_bus_state :: proc(c: ^Cursor, bus: ^Bus) {
	bus.mode = Gb_Mode(get_u8(c))
	bus.vram_bank = get_u8(c)
	bus.wram_bank = get_u8(c)
	bus.cycles = get_u64(c)
	bus.hw_cycles = get_u64(c)
	bus.double_speed = get_bool(c)
	bus.speed_switch_prepared = get_bool(c)
	bus.bcps = get_u8(c)
	bus.ocps = get_u8(c)

	for bank in 0 ..< 2 {
		get_bytes(c, bus.vram[bank][:])
	}
	for bank in 0 ..< 8 {
		get_bytes(c, bus.wram[bank][:])
	}
	get_bytes(c, bus.oam[:])
	get_bytes(c, bus.hram[:])
	get_bytes(c, bus.io[:])
	bus.ie = get_u8(c)
	get_bytes(c, bus.bg_palette_ram[:])
	get_bytes(c, bus.obj_palette_ram[:])

	bus.hdma_source = get_u16(c)
	bus.hdma_destination = get_u16(c)
	bus.hdma_remaining = get_int(c)
	bus.hdma_active = get_bool(c)
	bus.hdma_aborted = get_bool(c)
	bus.hdma_aborted_remaining = get_int(c)

	read_timer_state(c, bus)
	read_ppu_state(c, &bus.ppu)

	bus.joyp_select_action = get_bool(c)
	bus.joyp_select_direction = get_bool(c)
	bus.joyp_pressed = get_u8(c)

	bus.dma_active = get_bool(c)
	bus.dma_source = get_u16(c)
	bus.dma_index = get_int(c)
	bus.dma_start_delay = get_int(c)
	bus.dma_pending_source = get_u16(c)

	read_apu_state(c, &bus.apu)
	read_mbc_state(c, &bus.cart)
	get_bytes(c, bus.cart.ram)
}

@(private = "file")
write_timer_state :: proc(c: ^Cursor, bus: ^Bus) {
	put_u16(c, bus.div_counter)
	put_u8(c, bus.tima)
	put_u8(c, bus.tma)
	put_u8(c, bus.tac)
	put_int(c, bus.timer_reload_pending)
	put_bool(c, bus.timer_reload_just_happened)
}

@(private = "file")
read_timer_state :: proc(c: ^Cursor, bus: ^Bus) {
	bus.div_counter = get_u16(c)
	bus.tima = get_u8(c)
	bus.tma = get_u8(c)
	bus.tac = get_u8(c)
	bus.timer_reload_pending = get_int(c)
	bus.timer_reload_just_happened = get_bool(c)
}

@(private = "file")
write_ppu_state :: proc(c: ^Cursor, p: ^Ppu) {
	put_u8(c, p.lcdc)
	put_u8(c, p.stat_enable)
	put_u8(c, p.scy)
	put_u8(c, p.scx)
	put_u8(c, p.ly)
	put_u8(c, p.lyc)
	put_u8(c, p.bgp)
	put_u8(c, p.obp0)
	put_u8(c, p.obp1)
	put_u8(c, p.wy)
	put_u8(c, p.wx)
	put_u8(c, u8(p.mode))
	put_bool(c, p.lyc_equal)
	put_int(c, p.dot)
	put_int(c, p.window_line)
	put_bool(c, p.stat_irq_line)
	put_bytes(c, mem_u32_slice_to_u8(p.framebuffer[:]))
}

@(private = "file")
read_ppu_state :: proc(c: ^Cursor, p: ^Ppu) {
	p.lcdc = get_u8(c)
	p.stat_enable = get_u8(c)
	p.scy = get_u8(c)
	p.scx = get_u8(c)
	p.ly = get_u8(c)
	p.lyc = get_u8(c)
	p.bgp = get_u8(c)
	p.obp0 = get_u8(c)
	p.obp1 = get_u8(c)
	p.wy = get_u8(c)
	p.wx = get_u8(c)
	p.mode = Ppu_Mode(get_u8(c))
	p.lyc_equal = get_bool(c)
	p.dot = get_int(c)
	p.window_line = get_int(c)
	p.stat_irq_line = get_bool(c)
	get_bytes(c, mem_u32_slice_to_u8(p.framebuffer[:]))
}

// mem_u32_slice_to_u8 は [N]u32 のスライスをバイト列として読み書きするための再解釈。
// リトルエンディアン環境前提(architecture.md: 配布対象プラットフォームはすべてLE)。
@(private = "file")
mem_u32_slice_to_u8 :: proc(s: []u32) -> []u8 {
	return ([^]u8)(raw_data(s))[:len(s) * 4]
}

@(private = "file")
write_envelope :: proc(c: ^Cursor, e: ^Envelope) {
	put_int(c, e.initial_volume)
	put_u8(c, u8(e.direction))
	put_int(c, e.period)
	put_int(c, e.timer)
	put_int(c, e.volume)
}

@(private = "file")
read_envelope :: proc(c: ^Cursor, e: ^Envelope) {
	e.initial_volume = get_int(c)
	e.direction = Envelope_Direction(get_u8(c))
	e.period = get_int(c)
	e.timer = get_int(c)
	e.volume = get_int(c)
}

@(private = "file")
write_sweep :: proc(c: ^Cursor, s: ^Sweep) {
	put_int(c, s.period)
	put_bool(c, s.negate)
	put_int(c, s.shift)
	put_int(c, s.timer)
	put_int(c, s.shadow_frequency)
	put_bool(c, s.enabled)
	put_bool(c, s.negate_calculated_since_trigger)
}

@(private = "file")
read_sweep :: proc(c: ^Cursor, s: ^Sweep) {
	s.period = get_int(c)
	s.negate = get_bool(c)
	s.shift = get_int(c)
	s.timer = get_int(c)
	s.shadow_frequency = get_int(c)
	s.enabled = get_bool(c)
	s.negate_calculated_since_trigger = get_bool(c)
}

@(private = "file")
write_pulse_channel :: proc(c: ^Cursor, ch: ^Pulse_Channel) {
	put_bool(c, ch.enabled)
	put_bool(c, ch.dac_enabled)
	put_int(c, ch.duty)
	put_int(c, ch.duty_step)
	put_int(c, ch.length_counter)
	put_bool(c, ch.length_enabled)
	put_int(c, ch.frequency)
	put_int(c, ch.timer)
	write_envelope(c, &ch.envelope)
	write_sweep(c, &ch.sweep)
}

@(private = "file")
read_pulse_channel :: proc(c: ^Cursor, ch: ^Pulse_Channel) {
	ch.enabled = get_bool(c)
	ch.dac_enabled = get_bool(c)
	ch.duty = get_int(c)
	ch.duty_step = get_int(c)
	ch.length_counter = get_int(c)
	ch.length_enabled = get_bool(c)
	ch.frequency = get_int(c)
	ch.timer = get_int(c)
	read_envelope(c, &ch.envelope)
	read_sweep(c, &ch.sweep)
}

@(private = "file")
write_wave_channel :: proc(c: ^Cursor, ch: ^Wave_Channel) {
	put_bool(c, ch.enabled)
	put_bool(c, ch.dac_enabled)
	put_int(c, ch.length_counter)
	put_bool(c, ch.length_enabled)
	put_int(c, ch.frequency)
	put_int(c, ch.timer)
	put_int(c, ch.position)
	put_int(c, ch.output_level)
}

@(private = "file")
read_wave_channel :: proc(c: ^Cursor, ch: ^Wave_Channel) {
	ch.enabled = get_bool(c)
	ch.dac_enabled = get_bool(c)
	ch.length_counter = get_int(c)
	ch.length_enabled = get_bool(c)
	ch.frequency = get_int(c)
	ch.timer = get_int(c)
	ch.position = get_int(c)
	ch.output_level = get_int(c)
}

@(private = "file")
write_noise_channel :: proc(c: ^Cursor, ch: ^Noise_Channel) {
	put_bool(c, ch.enabled)
	put_bool(c, ch.dac_enabled)
	put_int(c, ch.length_counter)
	put_bool(c, ch.length_enabled)
	put_int(c, ch.timer)
	put_u16(c, ch.lfsr)
	write_envelope(c, &ch.envelope)
}

@(private = "file")
read_noise_channel :: proc(c: ^Cursor, ch: ^Noise_Channel) {
	ch.enabled = get_bool(c)
	ch.dac_enabled = get_bool(c)
	ch.length_counter = get_int(c)
	ch.length_enabled = get_bool(c)
	ch.timer = get_int(c)
	ch.lfsr = get_u16(c)
	read_envelope(c, &ch.envelope)
}

// write_apu_state/read_apu_state: オーディオリングバッファ(ring/ring_read/ring_write/
// ring_count)は保存しない(落とし穴: 単なる出力先バッファでゲーム状態ではない。復元直後は
// 空として再開して問題ない)。
@(private = "file")
write_apu_state :: proc(c: ^Cursor, apu: ^Apu) {
	put_bool(c, apu.powered_on)
	put_int(c, apu.frame_sequencer_step)
	put_int(c, apu.frame_sequencer_cycles)
	write_pulse_channel(c, &apu.pulse1)
	write_pulse_channel(c, &apu.pulse2)
	write_wave_channel(c, &apu.wave)
	write_noise_channel(c, &apu.noise)

	put_u8(c, apu.nr10)
	put_u8(c, apu.nr11)
	put_u8(c, apu.nr12)
	put_u8(c, apu.nr13)
	put_u8(c, apu.nr14)
	put_u8(c, apu.nr21)
	put_u8(c, apu.nr22)
	put_u8(c, apu.nr23)
	put_u8(c, apu.nr24)
	put_u8(c, apu.nr30)
	put_u8(c, apu.nr31)
	put_u8(c, apu.nr32)
	put_u8(c, apu.nr33)
	put_u8(c, apu.nr34)
	put_u8(c, apu.nr41)
	put_u8(c, apu.nr42)
	put_u8(c, apu.nr43)
	put_u8(c, apu.nr44)
	put_u8(c, apu.nr50)
	put_u8(c, apu.nr51)

	put_bytes(c, apu.wave_ram[:])
	put_int(c, apu.sample_counter)
}

@(private = "file")
read_apu_state :: proc(c: ^Cursor, apu: ^Apu) {
	apu.powered_on = get_bool(c)
	apu.frame_sequencer_step = get_int(c)
	apu.frame_sequencer_cycles = get_int(c)
	read_pulse_channel(c, &apu.pulse1)
	read_pulse_channel(c, &apu.pulse2)
	read_wave_channel(c, &apu.wave)
	read_noise_channel(c, &apu.noise)

	apu.nr10 = get_u8(c)
	apu.nr11 = get_u8(c)
	apu.nr12 = get_u8(c)
	apu.nr13 = get_u8(c)
	apu.nr14 = get_u8(c)
	apu.nr21 = get_u8(c)
	apu.nr22 = get_u8(c)
	apu.nr23 = get_u8(c)
	apu.nr24 = get_u8(c)
	apu.nr30 = get_u8(c)
	apu.nr31 = get_u8(c)
	apu.nr32 = get_u8(c)
	apu.nr33 = get_u8(c)
	apu.nr34 = get_u8(c)
	apu.nr41 = get_u8(c)
	apu.nr42 = get_u8(c)
	apu.nr43 = get_u8(c)
	apu.nr44 = get_u8(c)
	apu.nr50 = get_u8(c)
	apu.nr51 = get_u8(c)

	get_bytes(c, apu.wave_ram[:])
	apu.sample_counter = get_int(c)
}

// --- MBC(union のタグ + 中身、T7-1) ---
// タグ値は cartridge.odin の Mbc_Kind と同じ並び(0=Rom_Only,1=Mbc1,2=Mbc2,3=Mbc3,4=Mbc5)。
// 復元側は「現在ロードされているカートリッジと同じ種別である」ことをROMチェックサム一致で
// 保証されている前提で、対応する union ケースへ直接デコードする(savestate_expected_sizeの
// 計算もこの前提に立っている)。

@(private = "file")
write_mbc_state :: proc(c: ^Cursor, cart: ^Cartridge) {
	switch &state in cart.mbc {
	case Mbc_None:
		put_u8(c, 0)
	case Mbc1_State:
		put_u8(c, 1)
		put_bool(c, state.ram_enabled)
		put_u8(c, state.rom_bank_low5)
		put_u8(c, state.bank_high2)
		put_u8(c, u8(state.mode))
	case Mbc2_State:
		put_u8(c, 2)
		put_bool(c, state.ram_enabled)
		put_u8(c, state.rom_bank)
		put_bytes(c, state.ram[:])
	case Mbc3_State:
		put_u8(c, 3)
		put_bool(c, state.ram_enabled)
		put_u8(c, state.rom_bank)
		put_u8(c, state.ram_or_rtc_select)
		put_bytes(c, state.rtc[:])
		put_bytes(c, state.latched_rtc[:])
		put_bool(c, state.latch_prepared)
		put_i64(c, state.rtc_base_unix)
	case Mbc5_State:
		put_u8(c, 4)
		put_bool(c, state.ram_enabled)
		put_u8(c, state.rom_bank_low8)
		put_u8(c, state.rom_bank_high1)
		put_u8(c, state.ram_bank)
	}
}

@(private = "file")
read_mbc_state :: proc(c: ^Cursor, cart: ^Cartridge) {
	tag := get_u8(c)
	switch &state in cart.mbc {
	case Mbc_None:
	// タグのみ(既に読み進めている)。
	case Mbc1_State:
		state.ram_enabled = get_bool(c)
		state.rom_bank_low5 = get_u8(c)
		state.bank_high2 = get_u8(c)
		state.mode = Mbc1_Mode(get_u8(c))
	case Mbc2_State:
		state.ram_enabled = get_bool(c)
		state.rom_bank = get_u8(c)
		get_bytes(c, state.ram[:])
	case Mbc3_State:
		state.ram_enabled = get_bool(c)
		state.rom_bank = get_u8(c)
		state.ram_or_rtc_select = get_u8(c)
		get_bytes(c, state.rtc[:])
		get_bytes(c, state.latched_rtc[:])
		state.latch_prepared = get_bool(c)
		state.rtc_base_unix = get_i64(c)
	case Mbc5_State:
		state.ram_enabled = get_bool(c)
		state.rom_bank_low8 = get_u8(c)
		state.rom_bank_high1 = get_u8(c)
		state.ram_bank = get_u8(c)
	}
	_ = tag // タグ自体は cart.mbc の現在の種別(ロード済みROMの種別)から自明なので検査しない
}

// --- 読み込み(T7-2) ---
// 検証順: マジック/バージョン読み取りに必要な最小長 → マジック一致 → バージョン一致 →
// ROMチェックサム一致 → 本体サイズ充足。いずれかで失敗した場合、emu には一切書き込まない
// (「現在の状態を壊さない」)。全検証を通過して初めて emu.cpu/emu.bus へ復元する。
savestate_read :: proc(emu: ^Emulator, data: []u8) -> Load_Error {
	if len(data) < SAVESTATE_HEADER_SIZE {
		return .Too_Small
	}

	c := Cursor{data = data}
	magic := get_bytes_view(&c, 4)
	if string(magic) != SAVESTATE_MAGIC {
		return .Bad_Magic
	}

	version := get_u32(&c)
	if version != SAVESTATE_FORMAT_VERSION {
		return .Version_Mismatch
	}

	checksum := get_u16(&c)
	if checksum != rom_header_checksum(emu.bus.cart.rom) {
		return .Rom_Checksum_Mismatch
	}

	expected := savestate_expected_size(emu)
	if len(data) < expected {
		return .Too_Small
	}

	read_cpu_state(&c, &emu.cpu)
	read_bus_state(&c, &emu.bus)

	return .None
}

// get_bytes_view はコピーせずカーソル位置から n バイトを覗き見る(マジック文字列比較専用。
// 呼び出し側は data の生存期間中のみ有効な借用として扱う)。
@(private = "file")
get_bytes_view :: proc(c: ^Cursor, n: int) -> []u8 {
	v := c.data[c.pos:c.pos + n]
	c.pos += n
	return v
}
