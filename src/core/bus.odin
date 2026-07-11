package core

// メモリマップと M-cycle tick 駆動。
// bus_tick は Timer/PPU/APU/DMA を駆動する唯一の場所になる(architecture.md「タイミングモデル」)。
// DIV/TIMA/TMA/TAC の落下エッジ検出方式の実装は timer.odin(T2-3)。

DIV_ADDR :: 0xFF04
TIMA_ADDR :: 0xFF05
TMA_ADDR :: 0xFF06
TAC_ADDR :: 0xFF07
IF_ADDR :: 0xFF0F

Bus :: struct {
	rom:                       []u8, // ROM-only カートリッジ(32KiB)。MBC はフェーズ4
	vram:                      [8192]u8,
	wram:                      [8192]u8,
	oam:                       [160]u8,
	hram:                      [127]u8,
	io:                        [128]u8, // FF00-FF7F の生バックストア(個別実装されたレジスタ以外は読み出し時 0xFF)
	ie:                        u8, // FFFF
	cycles:                    u64, // 累計 T-cycle
	serial_log:                [dynamic]u8, // シリアル出力キャプチャ(T1-7、serial.odin)
	div_counter:               u16, // DIV の内部カウンタ(上位8bitがDIVとして読める。timer.odin)
	tima:                      u8, // 0xFF05
	tma:                       u8, // 0xFF06
	tac:                       u8, // 0xFF07(bit2=有効, bit1-0=周波数選択)
	timer_reload_pending:      int, // TIMAオーバーフロー後のTMAリロードまでの残りT-cycle(0=無し。timer.odin)
	timer_reload_just_happened: bool, // 直近の timer_tick 呼び出しでリロードが完了したか(TIMA/TMA書き込みの特殊挙動判定用)
	joyp_select_action:        bool, // JOYP bit5=0(joypad.odin)
	joyp_select_direction:     bool, // JOYP bit4=0(joypad.odin)
	joyp_pressed:              u8, // Button ごとのビットマスク(joypad.odin の button_bit)
}

// bus_load_rom は ROM-only カートリッジをそのまま map する(MBC はフェーズ4)。
bus_load_rom :: proc(bus: ^Bus, data: []u8) -> bool {
	if len(data) == 0 {
		return false
	}
	bus.rom = data
	return true
}

// bus_tick は t_cycles ぶん時間を進める。CPU の全メモリアクセスごとに呼ばれる。
// Timer(timer.odin、T2-3)を駆動する。PPU/APU の駆動はフェーズ3/5以降。
bus_tick :: proc(bus: ^Bus, t_cycles: int) {
	bus.cycles += u64(t_cycles)
	timer_tick(bus, t_cycles)
}

bus_read :: proc(bus: ^Bus, addr: u16) -> u8 {
	switch {
	case addr <= 0x7FFF:
		if int(addr) < len(bus.rom) {
			return bus.rom[addr]
		}
		return 0xFF
	case addr <= 0x9FFF:
		return bus.vram[addr - 0x8000]
	case addr <= 0xBFFF:
		return 0xFF // 外部RAM未実装(フェーズ4)
	case addr <= 0xDFFF:
		return bus.wram[addr - 0xC000]
	case addr <= 0xFDFF:
		return bus.wram[addr - 0xE000] // エコーRAM: WRAM のミラー
	case addr <= 0xFE9F:
		return bus.oam[addr - 0xFE00]
	case addr <= 0xFEFF:
		return 0xFF // 未使用領域
	case addr <= 0xFF7F:
		return bus_io_read(bus, addr)
	case addr <= 0xFFFE:
		return bus.hram[addr - 0xFF80]
	case:
		return bus.ie // 0xFFFF
	}
}

bus_write :: proc(bus: ^Bus, addr: u16, value: u8) {
	switch {
	case addr <= 0x7FFF:
	// ROM への書き込みは無視(MBC バンク切替はフェーズ4)
	case addr <= 0x9FFF:
		bus.vram[addr - 0x8000] = value
	case addr <= 0xBFFF:
	// 外部RAM未実装(フェーズ4)
	case addr <= 0xDFFF:
		bus.wram[addr - 0xC000] = value
	case addr <= 0xFDFF:
		bus.wram[addr - 0xE000] = value
	case addr <= 0xFE9F:
		bus.oam[addr - 0xFE00] = value
	case addr <= 0xFEFF:
	// 未使用領域: 書き込み無視
	case addr <= 0xFF7F:
		bus_io_write(bus, addr, value)
	case addr <= 0xFFFE:
		bus.hram[addr - 0xFF80] = value
	case:
		bus.ie = value // 0xFFFF
	}
}

// bus_io_read/write は FF00-FF7F を扱う。個別実装のあるレジスタ以外は
// read で常に 0xFF を返す(未実装 IO レジスタの規約)。
// SB/SC(シリアル)は serial.odin にハンドリングを委譲する(T1-7)。
@(private)
bus_io_read :: proc(bus: ^Bus, addr: u16) -> u8 {
	switch addr {
	case JOYP_ADDR:
		return joypad_read_p1(bus)
	case SERIAL_SB, SERIAL_SC:
		return bus.io[addr - 0xFF00]
	case DIV_ADDR:
		return u8(bus.div_counter >> 8)
	case TIMA_ADDR:
		return bus.tima
	case TMA_ADDR:
		return bus.tma
	case TAC_ADDR:
		return bus.tac | 0xF8 // 未使用bitは1で読める
	case IF_ADDR:
		return bus.io[IF_ADDR - 0xFF00] | 0xE0 // 上位3bit未使用、読み出し時は1
	case:
		return 0xFF
	}
}

@(private)
bus_io_write :: proc(bus: ^Bus, addr: u16, value: u8) {
	switch addr {
	case JOYP_ADDR:
		joypad_write_p1(bus, value)
	case SERIAL_SB, SERIAL_SC:
		serial_write(bus, addr, value)
	case DIV_ADDR:
		timer_write_div(bus)
	case TIMA_ADDR:
		timer_write_tima(bus, value)
	case TMA_ADDR:
		timer_write_tma(bus, value)
	case TAC_ADDR:
		timer_write_tac(bus, value)
	case:
		bus.io[addr - 0xFF00] = value
	}
}

// --- CPU 側のメモリアクセス経路 ---
// architecture.md: CPU からの全メモリアクセスは必ずこの経路を通し、
// 命令実行後に一括 tick する設計は禁止。

cpu_read8 :: proc(cpu: ^Cpu, bus: ^Bus, addr: u16) -> u8 {
	bus_tick(bus, 4)
	return bus_read(bus, addr)
}

cpu_write8 :: proc(cpu: ^Cpu, bus: ^Bus, addr: u16, value: u8) {
	bus_tick(bus, 4)
	bus_write(bus, addr, value)
}
