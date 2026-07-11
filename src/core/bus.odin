package core

// メモリマップと M-cycle tick 駆動。
// bus_tick は Timer/PPU/APU/DMA を駆動する唯一の場所になる(architecture.md「タイミングモデル」)。
// DIV/TIMA/TMA/TAC の落下エッジ検出方式の実装は timer.odin(T2-3)。

DIV_ADDR :: 0xFF04
TIMA_ADDR :: 0xFF05
TMA_ADDR :: 0xFF06
TAC_ADDR :: 0xFF07
IF_ADDR :: 0xFF0F
DMA_ADDR :: 0xFF46

OAM_SIZE :: 160

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
	dma_active:                bool, // OAM DMA 転送中(HRAM以外の読み出しが0xFFになる。T2-5)
	dma_source:                u16, // 現在進行中の転送の転送元ベースアドレス
	dma_index:                 int, // 転送済みバイト数(0..159)
	dma_start_delay:           int, // (再)開始までの残りM-cycle数(0=保留無し)。開始には1 M-cycleの遅延がある
	dma_pending_source:        u16, // dma_start_delay が0になった時点で dma_source に反映される転送元
	ppu:                       Ppu, // LCD レジスタ・モードタイミング・フレームバッファ(ppu.odin、T3-1)
}

// bus_load_rom は ROM-only カートリッジをそのまま map する(MBC はフェーズ4)。
bus_load_rom :: proc(bus: ^Bus, data: []u8) -> bool {
	if len(data) == 0 {
		return false
	}
	bus.rom = data
	return true
}

// bus_power_on はブート ROM 完了直後の IO レジスタ状態を直接セットする(T3-8、
// CLAUDE.md「実 BIOS ROM の読み込みには対応しない」方針)。現時点では PPU レジスタのみ
// (ppu.odin の ppu_power_on)。Timer/Joypad はゼロ値のままで実用上問題ないため対象外
// (T2-3/T2-4で確認済み、テスト ROM は自前で初期化するか値を仮定しない)。
bus_power_on :: proc(bus: ^Bus) {
	ppu_power_on(&bus.ppu)
}

// bus_tick は t_cycles ぶん時間を進める。CPU の全メモリアクセスごとに呼ばれる。
// Timer(timer.odin、T2-3)、PPU(ppu.odin、T3-2)、OAM DMA(T2-5)を駆動する。APU の駆動はフェーズ5以降。
// t_cycles は常に4の倍数(1 M-cycle単位)で渡される想定(architecture.md のタイミングモデル)。
bus_tick :: proc(bus: ^Bus, t_cycles: int) {
	bus.cycles += u64(t_cycles)
	timer_tick(bus, t_cycles)
	ppu_tick(bus, t_cycles)
	for _ in 0 ..< t_cycles / 4 {
		dma_tick_one_mcycle(bus)
	}
}

// dma_tick_one_mcycle は OAM DMA を1 M-cycleぶん進める。
//
// 開始タイミング(Mooneye oam_dma_start.s のコメントで実機確認済み):
//   M0: 0xFF46 への書き込みが起きる(この時点では dma_start_delay=2 をセットするのみ)
//   M1: まだ何も起きない(旧転送が実行中ならそれはそのまま継続する。新規開始の場合はOAMがまだ読める)
//   M2: 新しい転送が(旧転送を打ち切って)開始し、以後1バイト/M-cycleで160 M-cycleかけて転送する
//
// dma_active は「CPUからの読み出しをHRAM以外0xFFにする」条件を兼ねる(bus_read 参照)。
@(private)
dma_tick_one_mcycle :: proc(bus: ^Bus) {
	if bus.dma_start_delay > 0 {
		bus.dma_start_delay -= 1
		if bus.dma_start_delay == 0 {
			// M2: 新しい転送が(実行中だったものを打ち切って)ここから始まる。
			bus.dma_active = true
			bus.dma_source = bus.dma_pending_source
			bus.dma_index = 0
		}
	}

	if bus.dma_active {
		bus.oam[bus.dma_index] = bus_read_raw(bus, bus.dma_source + u16(bus.dma_index))
		bus.dma_index += 1
		if bus.dma_index >= OAM_SIZE {
			bus.dma_active = false
		}
	}
}

// bus_read は CPU からの読み出し経路。OAM DMA 中は HRAM(FF80-FFFE)以外を読むと
// 0xFF になる(実バス競合の簡易モデル、T2-5)。DMA 自身の内部読み出しは
// この制限を受けない bus_read_raw を直接使う。
bus_read :: proc(bus: ^Bus, addr: u16) -> u8 {
	if bus.dma_active && !(addr >= 0xFF80 && addr <= 0xFFFE) {
		return 0xFF
	}
	return bus_read_raw(bus, addr)
}

@(private)
bus_read_raw :: proc(bus: ^Bus, addr: u16) -> u8 {
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
	case DMA_ADDR:
		// 転送状態に関わらず、直近に書き込まれた値をそのまま返す(mooneye oam_dma/reg_read)。
		return bus.io[DMA_ADDR - 0xFF00]
	case LCDC_ADDR, STAT_ADDR, SCY_ADDR, SCX_ADDR, LY_ADDR, LYC_ADDR, BGP_ADDR, OBP0_ADDR, OBP1_ADDR, WY_ADDR, WX_ADDR:
		return ppu_read(bus, addr)
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
	case DMA_ADDR:
		bus.io[DMA_ADDR - 0xFF00] = value // 読み戻し用(mooneye oam_dma/reg_read)
		bus.dma_pending_source = u16(value) << 8
		bus.dma_start_delay = 2 // 1 M-cycleの遅延後、2M-cycle目から新しい転送が始まる
	case LCDC_ADDR, STAT_ADDR, SCY_ADDR, SCX_ADDR, LY_ADDR, LYC_ADDR, BGP_ADDR, OBP0_ADDR, OBP1_ADDR, WY_ADDR, WX_ADDR:
		ppu_write(bus, addr, value)
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
