package core

// メモリマップと M-cycle tick 駆動。
// bus_tick は今後 Timer/PPU/APU/DMA を駆動する唯一の場所になる(architecture.md「タイミングモデル」)。

Bus :: struct {
	rom:        []u8, // ROM-only カートリッジ(32KiB)。MBC はフェーズ4
	vram:       [8192]u8,
	wram:       [8192]u8,
	oam:        [160]u8,
	hram:       [127]u8,
	io:         [128]u8, // FF00-FF7F の生バックストア(個別実装されたレジスタ以外は読み出し時 0xFF)
	ie:         u8, // FFFF
	cycles:     u64, // 累計 T-cycle
	serial_log: [dynamic]u8, // シリアル出力キャプチャ(T1-7、serial.odin)
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
// 今はカウンタ加算のみ(Timer/PPU/APU/DMA の駆動はフェーズ2以降で追加)。
bus_tick :: proc(bus: ^Bus, t_cycles: int) {
	bus.cycles += u64(t_cycles)
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
	case SERIAL_SB, SERIAL_SC:
		return bus.io[addr - 0xFF00]
	case:
		return 0xFF
	}
}

@(private)
bus_io_write :: proc(bus: ^Bus, addr: u16, value: u8) {
	switch addr {
	case SERIAL_SB, SERIAL_SC:
		serial_write(bus, addr, value)
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
