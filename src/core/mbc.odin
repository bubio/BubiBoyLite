package core

// MBC(メモリバンクコントローラ)の状態と読み書き。architecture.md「型と表現の決定事項」:
// MBC 状態は Odin の tagged union で表現する(Mbc_State :: union { Mbc_None, Mbc1_State, ... })。
// bus.odin の 0000-7FFF(ROM)・A000-BFFF(外部RAM)はこのファイルの mbc_read/mbc_write を
// 経由する(T4-2、~/dev/_Emu/BubiBoy/src/BubiBoy.Core/CartridgeMemory.fs のアルゴリズムを移植)。
// MBC2/3/5 は T4-3〜T4-5 で union に追加していく。

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

Mbc_State :: union {
	Mbc_None,
	Mbc1_State,
}

// mbc_read は ROM(0000-7FFF)・外部 RAM(A000-BFFF)への読み出しを MBC の種類に応じてディスパッチする。
mbc_read :: proc(cart: ^Cartridge, addr: u16) -> u8 {
	switch state in cart.mbc {
	case Mbc_None:
		return mbc_none_read(cart, addr)
	case Mbc1_State:
		return mbc1_read(cart, state, addr)
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
