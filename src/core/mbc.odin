package core

// MBC(メモリバンクコントローラ)の状態と読み書き。architecture.md「型と表現の決定事項」:
// MBC 状態は Odin の tagged union で表現する(Mbc_State :: union { Mbc_None, Mbc1_State, ... })。
// bus.odin の 0000-7FFF(ROM)・A000-BFFF(外部RAM)はこのファイルの mbc_read/mbc_write を
// 経由する(T4-2、~/dev/_Emu/BubiBoy/src/BubiBoy.Core/CartridgeMemory.fs のアルゴリズムを移植)。

ROM_BANK_SIZE :: 0x4000
RAM_BANK_SIZE :: 0x2000

// Mbc_None: ROM only カートリッジ(バンク切替も外部RAMも無し)。
Mbc_None :: struct {}

Mbc1_Mode :: enum {
	Rom, // 6000-7FFF に 0 を書いた状態(既定値)。0000-3FFF は常にバンク0
	Ram, // 6000-7FFF に 1 を書いた状態。0000-3FFF/外部RAMバンクにも上位2bitが効く
}

Mbc1_State :: struct {
	ram_enabled:   bool, // 0000-1FFF: 下位4bit=0x0A で有効
	rom_bank_low5: u8, // 2000-3FFF: 下位5bit(0は1に読み替え済みの値を保持)
	bank_high2:    u8, // 4000-5FFF: 上位2bit(0-3)
	mode:          Mbc1_Mode, // 6000-7FFF
}

// Mbc2_State: 内蔵 512x4bit RAM を持つ MBC2(T4-3)。RAM 有効化と ROM バンク選択は
// 0000-3FFF の**同じアドレス帯**でアドレス bit8 により区別される(MBC1 と違う落とし穴)。
Mbc2_State :: struct {
	ram_enabled: bool,
	rom_bank:    u8, // 下位4bit(0は1に読み替え)
	ram:         [512]u8, // 内蔵RAM。外部の Cartridge.ram は使わない(cartridge_init 参照)
}

// Mbc3_State: MBC3(+RTC)。rtc は「現在時刻」を表すライブレジスタ、latched_rtc は
// 直近のラッチ操作(6000-7FFFへ0→1)で複製されたスナップショットで、CPU からの読み出しは
// 常に latched_rtc を見る(実機同様、ラッチしないと最新値は読めない)。rtc_base_unix は
// 直近に emulator_set_wall_clock で供給された UNIX 秒(「基準UNIX時刻+経過秒」方式、T4-4)。
// 0(ゼロ値)は「まだ同期されていない」を表すセンチネルとして扱う(core は現在時刻を直接
// 取得しないため、最初の供給は「基準点を打つだけ」で経過秒には加算しない)。
Mbc3_State :: struct {
	ram_enabled:       bool, // 0000-1FFF: 下位4bit=0x0A で有効
	rom_bank:          u8, // 2000-3FFF: 下位7bit(0は1に読み替え)
	ram_or_rtc_select: u8, // 4000-5FFF: 0x00-0x03=RAMバンク、0x08-0x0C=RTCレジスタ(S/M/H/DL/DH)
	rtc:               [5]u8, // ライブレジスタ(進行中の現在時刻)。index: 0=S,1=M,2=H,3=DL,4=DH
	latched_rtc:       [5]u8, // 直近ラッチのスナップショット。CPU からの読み出しはこちら
	latch_prepared:    bool, // 6000-7FFFへ0x00を書いた直後(次に0x01が来たらラッチ)
	rtc_base_unix:     i64, // 直近の emulator_set_wall_clock 供給値。0=未同期
}

// Mbc5_State: GBC世代の標準MBC5(T4-5)。落とし穴: MBC1/MBC2/MBC3と違い、バンク0を
// そのまま4000-7FFFに指定できる(0→1の読み替えをしない)。
Mbc5_State :: struct {
	ram_enabled:    bool, // 0000-1FFF: 下位4bit=0x0A で有効
	rom_bank_low8:  u8, // 2000-2FFF: ROMバンク下位8bit
	rom_bank_high1: u8, // 3000-3FFF: ROMバンクbit8(0-1)。500バンク超のROM向け
	ram_bank:       u8, // 4000-5FFF: RAMバンク(0-15)
}

Mbc_State :: union {
	Mbc_None,
	Mbc1_State,
	Mbc2_State,
	Mbc3_State,
	Mbc5_State,
}

// mbc_read は ROM(0000-7FFF)・外部 RAM(A000-BFFF)への読み出しを MBC の種類に応じてディスパッチする。
mbc_read :: proc(cart: ^Cartridge, addr: u16) -> u8 {
	switch state in cart.mbc {
	case Mbc_None:
		return mbc_none_read(cart, addr)
	case Mbc1_State:
		return mbc1_read(cart, state, addr)
	case Mbc2_State:
		return mbc2_read(cart, state, addr)
	case Mbc3_State:
		return mbc3_read(cart, state, addr)
	case Mbc5_State:
		return mbc5_read(cart, state, addr)
	}
	return 0xFF
}

// mbc_write は ROM 領域(バンク切替レジスタ)・外部 RAM への書き込みを MBC の種類に応じて
// ディスパッチする。Odin のポインタ型スイッチ(switch &v in union、union はアドレス可能な
// lvalue である必要がある)で変更を union に直接書き戻す。
mbc_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	switch &state in cart.mbc {
	case Mbc_None:
	// ROM only はバンク切替レジスタも外部RAMも無いので書き込みは無視
	case Mbc1_State:
		mbc1_write(cart, &state, addr, value)
	case Mbc2_State:
		mbc2_write(cart, &state, addr, value)
	case Mbc3_State:
		mbc3_write(cart, &state, addr, value)
	case Mbc5_State:
		mbc5_write(cart, &state, addr, value)
	}
}

// mbc_sync_wall_clock は emulator_set_wall_clock(emulator.odin)から呼ばれ、MBC3 の RTC が
// あれば時刻を進める。MBC3 以外・RTC無しカートリッジでは何もしない。
mbc_sync_wall_clock :: proc(cart: ^Cartridge, unix_seconds: i64) {
	switch &state in cart.mbc {
	case Mbc3_State:
		if cart.info.has_rtc {
			mbc3_advance_rtc(&state, unix_seconds)
		}
	case Mbc_None, Mbc1_State, Mbc2_State, Mbc5_State:
	}
}

// --- 共通ヘルパー(バンク境界の正規化。BubiBoy normalizeRomBank 相当) ---

@(private)
read_rom_bank :: proc(cart: ^Cartridge, bank: int, offset: u16) -> u8 {
	bank_count := cart.info.rom_banks
	normalized := bank
	if bank_count > 0 {
		normalized = bank % bank_count
	} else {
		normalized = 0
	}
	physical := normalized * ROM_BANK_SIZE + int(offset)
	if physical < 0 || physical >= len(cart.rom) {
		return 0xFF
	}
	return cart.rom[physical]
}

@(private)
mbc_ram_bank_count :: proc(cart: ^Cartridge) -> int {
	if len(cart.ram) == 0 {
		return 0
	}
	return len(cart.ram) / RAM_BANK_SIZE
}

@(private)
read_ram_bank :: proc(cart: ^Cartridge, bank: int, offset: u16) -> u8 {
	if len(cart.ram) == 0 {
		return 0xFF
	}
	bank_count := mbc_ram_bank_count(cart)
	normalized := bank
	if bank_count > 0 {
		normalized = bank % bank_count
	} else {
		normalized = 0
	}
	physical := normalized * RAM_BANK_SIZE + int(offset)
	if physical < 0 || physical >= len(cart.ram) {
		return 0xFF
	}
	return cart.ram[physical]
}

// write_ram_bank は実際にバイトを書き込んだ場合のみ ram_dirty を立てる(T4-6 の落とし穴:
// RAM 無効時の書き込みは呼び出し元でガードされ、ここには到達しないのでダーティ判定が単純になる)。
@(private)
write_ram_bank :: proc(cart: ^Cartridge, bank: int, offset: u16, value: u8) {
	if len(cart.ram) == 0 {
		return
	}
	bank_count := mbc_ram_bank_count(cart)
	normalized := bank
	if bank_count > 0 {
		normalized = bank % bank_count
	} else {
		normalized = 0
	}
	physical := normalized * RAM_BANK_SIZE + int(offset)
	if physical < 0 || physical >= len(cart.ram) {
		return
	}
	cart.ram[physical] = value
	cart.ram_dirty = true
}

// --- Mbc_None(ROM only) ---

@(private)
mbc_none_read :: proc(cart: ^Cartridge, addr: u16) -> u8 {
	if addr <= 0x7FFF {
		if int(addr) < len(cart.rom) {
			return cart.rom[addr]
		}
		return 0xFF
	}
	return 0xFF // 0xA000-0xBFFF: ROM only は外部RAM無し
}

// --- MBC1 ---

@(private)
mbc1_lower_bank :: proc(state: Mbc1_State) -> int {
	if state.mode == .Ram {
		return int(state.bank_high2) << 5
	}
	return 0
}

// mbc1_upper_bank は 4000-7FFF で選択されるバンクを返す。
// 落とし穴(T4-2): 「5bit レジスタが 0 なら 1」の判定は書き込み時に 5bit マスク後で行い済み
// (mbc1_write 参照)。ここでの再チェックは BubiBoy CartridgeMemory.fs upperRomBank と同じ
// 防御的な二重チェック(通常は raw&0x1F が 0 になることはない)。
@(private)
mbc1_upper_bank :: proc(state: Mbc1_State) -> int {
	raw := (int(state.bank_high2) << 5) | int(state.rom_bank_low5)
	if raw & 0x1F == 0 {
		raw |= 1
	}
	return raw
}

@(private)
mbc1_ram_bank :: proc(state: Mbc1_State) -> int {
	if state.mode == .Ram {
		return int(state.bank_high2)
	}
	return 0
}

@(private)
mbc1_read :: proc(cart: ^Cartridge, state: Mbc1_State, addr: u16) -> u8 {
	switch {
	case addr <= 0x3FFF:
		return read_rom_bank(cart, mbc1_lower_bank(state), addr)
	case addr <= 0x7FFF:
		return read_rom_bank(cart, mbc1_upper_bank(state), addr - 0x4000)
	case addr >= 0xA000 && addr <= 0xBFFF:
		if !state.ram_enabled {
			return 0xFF
		}
		return read_ram_bank(cart, mbc1_ram_bank(state), addr - 0xA000)
	case:
		return 0xFF
	}
}

@(private)
mbc1_write :: proc(cart: ^Cartridge, state: ^Mbc1_State, addr: u16, value: u8) {
	switch {
	case addr <= 0x1FFF:
		state.ram_enabled = value & 0x0F == 0x0A
	case addr <= 0x3FFF:
		low5 := value & 0x1F
		if low5 == 0 {
			low5 = 1
		}
		state.rom_bank_low5 = low5
	case addr <= 0x5FFF:
		state.bank_high2 = value & 0x03
	case addr <= 0x7FFF:
		state.mode = .Ram if value & 0x01 != 0 else .Rom
	case addr >= 0xA000 && addr <= 0xBFFF:
		if state.ram_enabled {
			write_ram_bank(cart, mbc1_ram_bank(state^), addr - 0xA000, value)
		}
	case:
	// 未使用領域: 無視
	}
}

// --- MBC2 ---

// mbc2_ram_index は A000-BFFF(0x2000バイト)を内蔵512バイトRAMに畳み込む。
// A000-A1FF が本体、A200-BFFF はエコー(0x200バイト境界で繰り返す、落とし穴)。
@(private)
mbc2_ram_index :: proc(addr: u16) -> u16 {
	return (addr - 0xA000) & 0x01FF
}

@(private)
mbc2_read :: proc(cart: ^Cartridge, state: Mbc2_State, addr: u16) -> u8 {
	switch {
	case addr <= 0x3FFF:
		return read_rom_bank(cart, 0, addr)
	case addr <= 0x7FFF:
		return read_rom_bank(cart, int(state.rom_bank), addr - 0x4000)
	case addr >= 0xA000 && addr <= 0xBFFF:
		if !state.ram_enabled {
			return 0xFF
		}
		// 上位4bitは読むと1(0xF0)。実データは下位4bitのみ(落とし穴、T4-3)。
		return 0xF0 | (state.ram[mbc2_ram_index(addr)] & 0x0F)
	case:
		return 0xFF
	}
}

// mbc2_write: 0000-3FFF はアドレス bit8 で RAM 有効化(bit8=0)/ROM バンク選択(bit8=1)を
// 区別する(MBC1 は別々のアドレス範囲で区別するのに対し、MBC2 は同じ範囲内でbit8により
// 区別する点が異なる。落とし穴、T4-3)。
@(private)
mbc2_write :: proc(cart: ^Cartridge, state: ^Mbc2_State, addr: u16, value: u8) {
	switch {
	case addr <= 0x3FFF:
		if addr & 0x0100 == 0 {
			state.ram_enabled = value & 0x0F == 0x0A
		} else {
			bank := value & 0x0F
			if bank == 0 {
				bank = 1
			}
			state.rom_bank = bank
		}
	case addr >= 0xA000 && addr <= 0xBFFF:
		if state.ram_enabled {
			state.ram[mbc2_ram_index(addr)] = value & 0x0F
			cart.ram_dirty = true // T4-6: 実書き込みでのみ立てる(RAM無効時はここに到達しない)
		}
	case:
	// 未使用領域: 無視
	}
}

// --- MBC3(+RTC) ---

RTC_SECONDS_PER_DAY :: i64(24 * 60 * 60)
RTC_MAX_DAYS :: i64(512) // DHのbit0が日カウンタbit8(9bit=0-511)

// mbc3_rtc_index は 4000-5FFF の選択値を RTC レジスタ配列のインデックスに変換する
// (0x08=S, 0x09=M, 0x0A=H, 0x0B=DL, 0x0C=DH)。RAM バンク選択(0x00-0x03)はここでは false。
@(private)
mbc3_rtc_index :: proc(select: u8) -> (idx: int, ok: bool) {
	if select >= 0x08 && select <= 0x0C {
		return int(select - 0x08), true
	}
	return 0, false
}

@(private)
mbc3_rtc_halted :: proc(rtc: [5]u8) -> bool {
	return rtc[4] & 0x40 != 0
}

@(private)
mbc3_rtc_total_seconds :: proc(rtc: [5]u8) -> i64 {
	day := i64(rtc[3]) | (i64(rtc[4] & 0x01) << 8)
	return i64(rtc[0]) + i64(rtc[1]) * 60 + i64(rtc[2]) * 3600 + day * RTC_SECONDS_PER_DAY
}

// mbc3_set_rtc_from_total_seconds は total 秒(0以上、512日未満に丸め済みであること)から
// S/M/H/DL/DHを再構築する。halted/carry は DH の bit6/bit7 に反映する。
@(private)
mbc3_set_rtc_from_total_seconds :: proc(rtc: ^[5]u8, total: i64, carry: bool, halted: bool) {
	day := total / RTC_SECONDS_PER_DAY
	remainder := total % RTC_SECONDS_PER_DAY
	hour := remainder / 3600
	remainder2 := remainder % 3600
	minute := remainder2 / 60
	second := remainder2 % 60

	high: u8 = 0
	if day & 0x100 != 0 {
		high |= 0x01
	}
	if halted {
		high |= 0x40
	}
	if carry {
		high |= 0x80
	}

	rtc[0] = u8(second)
	rtc[1] = u8(minute)
	rtc[2] = u8(hour)
	rtc[3] = u8(day & 0xFF)
	rtc[4] = high
}

// mbc3_advance_rtc_registers は seconds 秒(>0)を rtc に加算する(BubiBoy advanceRtcRegisters
// 相当)。511日を超えたら512日で折り返し、桁あふれフラグ(DH bit7)を立てる。halted 中は
// 呼び出し側(mbc3_advance_rtc)でガードするのでここでは常に加算する。
@(private)
mbc3_advance_rtc_registers :: proc(rtc: ^[5]u8, seconds: i64) {
	total_days_seconds := RTC_MAX_DAYS * RTC_SECONDS_PER_DAY
	current_total := mbc3_rtc_total_seconds(rtc^)
	advanced_total := current_total + seconds
	carry := (rtc[4] & 0x80 != 0) || advanced_total >= total_days_seconds
	wrapped_total := advanced_total % total_days_seconds
	mbc3_set_rtc_from_total_seconds(rtc, wrapped_total, carry, false)
}

// mbc3_advance_rtc は emulator_set_wall_clock から呼ばれる。「基準UNIX時刻+経過秒」方式
// (T4-4): rtc_base_unix と unix_seconds の差分だけ rtc を進め、rtc_base_unix を更新する。
// rtc_base_unix==0(未同期センチネル)の場合は基準点を打つだけで経過秒には加算しない
// (core は現在時刻を直接取れないため、初回供給時点を起点にする)。
// halt 中(DH bit6=1)は rtc_base_unix だけ更新し、レジスタは進めない
// (再開時に一気に進んでしまうのを防ぐ)。
@(private)
mbc3_advance_rtc :: proc(state: ^Mbc3_State, unix_seconds: i64) {
	if state.rtc_base_unix == 0 {
		state.rtc_base_unix = unix_seconds
		return
	}

	elapsed := unix_seconds - state.rtc_base_unix
	state.rtc_base_unix = unix_seconds

	if elapsed <= 0 || mbc3_rtc_halted(state.rtc) {
		return
	}

	mbc3_advance_rtc_registers(&state.rtc, elapsed)
}

// mbc3_normalize_rtc_register は CPU からの直接書き込み(初期時刻設定)を正規化する
// (BubiBoy normalizeRtcRegister 相当)。
@(private)
mbc3_normalize_rtc_register :: proc(idx: int, value: u8) -> u8 {
	switch idx {
	case 0, 1:
		return value % 60
	case 2:
		return value % 24
	case 3:
		return value
	case 4:
		return value & 0xC1 // bit0(日カウンタbit8)・bit6(停止)・bit7(桁あふれ)のみ
	case:
		return value
	}
}

// mbc3_latch は 6000-7FFF への書き込みを処理する。「0x00 を書いてから 0x01」の遷移のみ
// ラッチが発生する(落とし穴、T4-4)。それ以外の値(0x01 を prepared 無しで書く等)は
// latch_prepared を false にリセットする(BubiBoy latchMbc3Rtc と同じ状態機械)。
@(private)
mbc3_latch :: proc(state: ^Mbc3_State, value: u8) {
	if value == 0x00 {
		state.latch_prepared = true
	} else if value == 0x01 && state.latch_prepared {
		state.latched_rtc = state.rtc
		state.latch_prepared = false
	} else {
		state.latch_prepared = false
	}
}

@(private)
mbc3_read :: proc(cart: ^Cartridge, state: Mbc3_State, addr: u16) -> u8 {
	switch {
	case addr <= 0x3FFF:
		return read_rom_bank(cart, 0, addr)
	case addr <= 0x7FFF:
		return read_rom_bank(cart, int(state.rom_bank), addr - 0x4000)
	case addr >= 0xA000 && addr <= 0xBFFF:
		if !state.ram_enabled {
			return 0xFF
		}
		if idx, is_rtc := mbc3_rtc_index(state.ram_or_rtc_select); is_rtc {
			if !cart.info.has_rtc {
				return 0xFF
			}
			return state.latched_rtc[idx] // 常にラッチ済みスナップショットを読む(実機と同じ)
		}
		if state.ram_or_rtc_select <= 0x03 {
			return read_ram_bank(cart, int(state.ram_or_rtc_select), addr - 0xA000)
		}
		return 0xFF
	case:
		return 0xFF
	}
}

@(private)
mbc3_write :: proc(cart: ^Cartridge, state: ^Mbc3_State, addr: u16, value: u8) {
	switch {
	case addr <= 0x1FFF:
		state.ram_enabled = value & 0x0F == 0x0A
	case addr <= 0x3FFF:
		bank := value & 0x7F
		if bank == 0 {
			bank = 1
		}
		state.rom_bank = bank
	case addr <= 0x5FFF:
		state.ram_or_rtc_select = value
	case addr <= 0x7FFF:
		mbc3_latch(state, value)
	case addr >= 0xA000 && addr <= 0xBFFF:
		if !state.ram_enabled {
			return
		}
		if idx, is_rtc := mbc3_rtc_index(state.ram_or_rtc_select); is_rtc {
			if cart.info.has_rtc {
				state.rtc[idx] = mbc3_normalize_rtc_register(idx, value)
			}
		} else if state.ram_or_rtc_select <= 0x03 {
			write_ram_bank(cart, int(state.ram_or_rtc_select), addr - 0xA000, value)
		}
	case:
	// 未使用領域: 無視
	}
}

// --- MBC5 ---

@(private)
mbc5_rom_bank :: proc(state: Mbc5_State) -> int {
	return (int(state.rom_bank_high1) << 8) | int(state.rom_bank_low8)
}

@(private)
mbc5_read :: proc(cart: ^Cartridge, state: Mbc5_State, addr: u16) -> u8 {
	switch {
	case addr <= 0x3FFF:
		return read_rom_bank(cart, 0, addr)
	case addr <= 0x7FFF:
		return read_rom_bank(cart, mbc5_rom_bank(state), addr - 0x4000)
	case addr >= 0xA000 && addr <= 0xBFFF:
		if !state.ram_enabled {
			return 0xFF
		}
		return read_ram_bank(cart, int(state.ram_bank), addr - 0xA000)
	case:
		return 0xFF
	}
}

// mbc5_write: 落とし穴(T4-5) MBC1/MBC2/MBC3の「バンク0は1に読み替える」癖を
// 持ち込まない。MBC5はバンク0をそのまま4000-7FFFに指定できる。
@(private)
mbc5_write :: proc(cart: ^Cartridge, state: ^Mbc5_State, addr: u16, value: u8) {
	switch {
	case addr <= 0x1FFF:
		state.ram_enabled = value & 0x0F == 0x0A
	case addr <= 0x2FFF:
		state.rom_bank_low8 = value
	case addr <= 0x3FFF:
		state.rom_bank_high1 = value & 0x01
	case addr <= 0x5FFF:
		state.ram_bank = value & 0x0F
	case addr >= 0xA000 && addr <= 0xBFFF:
		if state.ram_enabled {
			write_ram_bank(cart, int(state.ram_bank), addr - 0xA000, value)
		}
	case:
	// 未使用領域: 無視
	}
}

// --- バッテリーセーブ(.sav)向けエクスポート/インポート(T4-6) ---
// app 側(src/app/saveram.odin)はこれらだけを使い、MBC の内部表現(MBC2 の内蔵RAMが
// union に埋め込まれている等)を意識しなくてよい。MBC3 は RAM のみを対象とし、
// RTC は対象外(.rtc への永続化はフェーズ7 T7-3)。バッテリー無しカートリッジは ok=false。

// mbc_export_ram はバッテリーバックアップRAMのコピーを返す(呼び出し側が所有・delete する)。
mbc_export_ram :: proc(cart: ^Cartridge) -> (data: []u8, ok: bool) {
	if !cart.info.has_battery {
		return nil, false
	}

	switch &state in cart.mbc {
	case Mbc2_State:
		out := make([]u8, len(state.ram))
		copy(out, state.ram[:])
		return out, true
	case Mbc_None, Mbc1_State, Mbc3_State, Mbc5_State:
		if len(cart.ram) == 0 {
			return nil, false
		}
		out := make([]u8, len(cart.ram))
		copy(out, cart.ram)
		return out, true
	}
	return nil, false
}

// mbc_import_ram は data をバッテリーバックアップRAMへ書き戻す。サイズが一致しない場合は
// 何もせず false を返す(呼び出し側で「サイズ不一致なら警告してロードしない」を実装する、
// T4-6 の完了条件)。
mbc_import_ram :: proc(cart: ^Cartridge, data: []u8) -> bool {
	if !cart.info.has_battery {
		return false
	}

	switch &state in cart.mbc {
	case Mbc2_State:
		if len(data) != len(state.ram) {
			return false
		}
		copy(state.ram[:], data)
		return true
	case Mbc_None, Mbc1_State, Mbc3_State, Mbc5_State:
		if len(cart.ram) == 0 || len(data) != len(cart.ram) {
			return false
		}
		copy(cart.ram, data)
		return true
	}
	return false
}

// --- RTC永続化(.rtc)向けエクスポート/インポート(T7-3) ---
// app 側(src/app/saveram.odin)はこれらだけを使い、Mbc3_State を意識しなくてよい
// (mbc_export_ram/mbc_import_ram と同じ位置づけ)。MBC3 以外・RTC無しカートリッジは ok=false。

// mbc_export_rtc は MBC3 の RTC(ライブレジスタ・直近ラッチのスナップショット・ラッチ準備
// フラグ・基準UNIX時刻)を返す。
mbc_export_rtc :: proc(
	cart: ^Cartridge,
) -> (
	rtc: [5]u8,
	latched_rtc: [5]u8,
	latch_prepared: bool,
	rtc_base_unix: i64,
	ok: bool,
) {
	if !cart.info.has_rtc {
		return {}, {}, false, 0, false
	}
	switch state in cart.mbc {
	case Mbc3_State:
		return state.rtc, state.latched_rtc, state.latch_prepared, state.rtc_base_unix, true
	case Mbc_None, Mbc1_State, Mbc2_State, Mbc5_State:
	}
	return {}, {}, false, 0, false
}

// mbc_import_rtc は渡された値を MBC3 の RTC へそのまま書き戻す(時刻は進めない、単純代入)。
// 「保存時からの経過秒をRTCへ加算する」処理自体は呼び出し側(app)が、この関数の直後に
// emulator_set_wall_clock を呼ぶことで mbc3_advance_rtc(既存のテスト済みロジック、DH bit6
// 停止中は加算しない・桁あふれ計算込み)へ委譲する設計(T7-3)。
mbc_import_rtc :: proc(cart: ^Cartridge, rtc: [5]u8, latched_rtc: [5]u8, latch_prepared: bool, rtc_base_unix: i64) -> bool {
	if !cart.info.has_rtc {
		return false
	}
	switch &state in cart.mbc {
	case Mbc3_State:
		state.rtc = rtc
		state.latched_rtc = latched_rtc
		state.latch_prepared = latch_prepared
		state.rtc_base_unix = rtc_base_unix
		return true
	case Mbc_None, Mbc1_State, Mbc2_State, Mbc5_State:
	}
	return false
}
