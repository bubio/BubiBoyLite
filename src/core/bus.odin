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
KEY1_ADDR :: 0xFF4D // T6-6: [CGB] ダブルスピード切替(bit7=現速度読取, bit0=切替準備書込)
VBK_ADDR :: 0xFF4F // T6-2: [CGB] VRAM バンク切替(bit0 のみ有効)
HDMA1_ADDR :: 0xFF51 // T6-7: [CGB] VRAM DMA ソース上位バイト
HDMA2_ADDR :: 0xFF52 // T6-7: [CGB] VRAM DMA ソース下位バイト(下位4bit無視)
HDMA3_ADDR :: 0xFF53 // T6-7: [CGB] VRAM DMA 宛先上位バイト(上位3bitマスク、常に0x80起点)
HDMA4_ADDR :: 0xFF54 // T6-7: [CGB] VRAM DMA 宛先下位バイト(下位4bit無視)
HDMA5_ADDR :: 0xFF55 // T6-7: [CGB] VRAM DMA 開始/状態(bit7=0:GDMA即時, 1:HDMA毎HBlank)
BCPS_ADDR :: 0xFF68 // T6-4: [CGB] BG パレットRAM インデックス(bit7=オートインクリメント)
BCPD_ADDR :: 0xFF69 // T6-4: [CGB] BG パレットRAM データ
OCPS_ADDR :: 0xFF6A // T6-4: [CGB] OBJ パレットRAM インデックス
OCPD_ADDR :: 0xFF6B // T6-4: [CGB] OBJ パレットRAM データ
SVBK_ADDR :: 0xFF70 // T6-3: [CGB] WRAM バンク切替(bit2-0、1-7。0指定は1扱い)

OAM_SIZE :: 160
VRAM_BANK_SIZE :: 8192
WRAM_BANK_SIZE :: 4096
PALETTE_RAM_SIZE :: 64 // T6-4: BG/OBJ 各64バイト(8パレット×4色×2バイト)

Bus :: struct {
	mode:                      Gb_Mode, // T6-1: ヘッダのCGBフラグから決まる実行モード(emulator_load_romが設定)
	cart:                      Cartridge, // ヘッダ情報・ROM(借用)・外部RAM(所有)・MBC状態(T4-2、cartridge.odin/mbc.odin)
	vram:                      [2][VRAM_BANK_SIZE]u8, // T6-2: バンク0=DMG互換、バンク1=CGB属性/追加タイルデータ
	vram_bank:                 u8, // FF4F(VBK) bit0。DMGモードでは常に0固定(書き込み無視)
	wram:                      [8][WRAM_BANK_SIZE]u8, // T6-3: C000-CFFFはバンク0固定、D000-DFFFはこのうちwram_bankを使う
	wram_bank:                 u8, // SVBK生値(0-7)。「0→1読み替え」は書込み時ではなくwram_active_bankで解決するため、未書込み(ゼロ値)でも自動的にバンク1として扱われる
	oam:                       [160]u8,
	hram:                      [127]u8,
	io:                        [128]u8, // FF00-FF7F の生バックストア(個別実装されたレジスタ以外は読み出し時 0xFF)
	ie:                        u8, // FFFF
	cycles:                    u64, // 累計 T-cycle(CPU側クロック。ダブルスピード中は実時間の2倍で進む)
	hw_cycles:                 u64, // 累計 T-cycle(PPU/APU側=実時間クロック。T6-6、emulator_run_frameのフレーム境界はこちらで数える)
	double_speed:              bool, // T6-6: KEY1 bit7相当。trueの間CPU/Timer/シリアルは2倍速、PPU/APUは等速
	speed_switch_prepared:     bool, // T6-6: KEY1 bit0相当(書込み)。STOP実行時にtrueなら速度反転してfalseに戻す

	// T6-7: HDMA/GDMA(VRAM DMA)。
	hdma_source:               u16, // HDMA1:HDMA2(下位4bitは書込み時に既にマスク済み)
	hdma_destination:          u16, // HDMA3:HDMA4。常に0x8000起点、下位4bit・上位3bit(0x9FFF超え)はマスク済み
	hdma_remaining:            int, // 残りブロック数(16バイト単位、1-128)。0=非アクティブ
	hdma_active:               bool, // true の間 HDMA(HBlank毎転送)が進行中。GDMAは即時完了するのでtrueにならない
	hdma_aborted:              bool, // 直近にHDMA中断(bit7=0書込み)が起きたか(FF55読み出し値の決定に使う)
	hdma_aborted_remaining:    int, // 中断時点で残っていたブロック数(FF55読み出し用のスナップショット)
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
	apu:                       Apu, // 4ch + フレームシーケンサ + 48kHzサンプル生成(apu.odin、T5-1)
	cart_load_error:           Cartridge_Parse_Error, // 直近の bus_load_rom 失敗理由(T4-2)。成功時は .None

	// T6-4: CGB パレットRAM(BG/OBJ各64バイト = 8パレット×4色×リトルエンディアンRGB555 2バイト)。
	bg_palette_ram:  [PALETTE_RAM_SIZE]u8,
	obj_palette_ram: [PALETTE_RAM_SIZE]u8,
	bcps:            u8, // FF68生値(bit7=オートインクリメント有効, bit6=常に1で読める未使用bit, bit5-0=インデックス)
	ocps:            u8, // FF6A生値。レイアウトはbcpsと同じ
}

// bus_load_rom はヘッダを解析してカートリッジ(ROM/RAM/MBC状態)をロードする(T4-2)。
// 失敗時は bus.cart_load_error に理由が残る(app 側は cartridge_error_message で整形できる)。
// data の所有権は呼び出し側に残る(bus.cart.rom はそれを指す借用スライス)。
bus_load_rom :: proc(bus: ^Bus, data: []u8) -> bool {
	if len(data) == 0 {
		bus.cart_load_error = .Header_Too_Small
		return false
	}
	cart, err := cartridge_init(data)
	if err != .None {
		bus.cart_load_error = err
		bus.cart = cart // type_code 等、エラーメッセージ表示に使える情報だけ残す
		return false
	}
	bus.cart = cart
	bus.cart_load_error = .None
	return true
}

// bus_destroy は cartridge_init が確保した外部RAMを解放する(T4-2)。
bus_destroy :: proc(bus: ^Bus) {
	cartridge_destroy(&bus.cart)
}

// bus_power_on はブート ROM 完了直後の IO レジスタ状態を直接セットする(T3-8、
// CLAUDE.md「実 BIOS ROM の読み込みには対応しない」方針)。現時点では PPU レジスタのみ
// (ppu.odin の ppu_power_on)。Timer/Joypad はゼロ値のままで実用上問題ないため対象外
// (T2-3/T2-4で確認済み、テスト ROM は自前で初期化するか値を仮定しない)。
bus_power_on :: proc(bus: ^Bus) {
	ppu_power_on(&bus.ppu)
	apu_power_on(&bus.apu)
}

// bus_tick は t_cycles ぶん時間を進める。CPU の全メモリアクセスごとに呼ばれる。
// Timer(timer.odin、T2-3)、PPU(ppu.odin、T3-2)、APU(apu.odin、T5-1)、OAM DMA(T2-5)を駆動する。
// t_cycles は常に4の倍数(1 M-cycle単位)で渡される想定(architecture.md のタイミングモデル)。
//
// T6-6: ダブルスピード中はCPU/Timer/シリアルは実時間の2倍速で進むが、PPU/APUは等速のまま
// (実クロックは変わらない)。そのため t_cycles(CPU側)をそのまま渡すのは Timer/DMA だけにし、
// PPU/APUには hw_cycles = double_speed ? t_cycles/2 : t_cycles を渡す(BubiBoy Bus.fs の
// hardwareCyclesForCpuCycles方式)。落とし穴: これを逆にすると音程が半オクターブずれたり
// ゲームが倍速になったりする。bus.hw_cycles(PPU/APU側の累計)は emulator_run_frame の
// フレーム境界判定に使う(bus.cyclesのままだとダブルスピード中に1フレームがPPU的には
// 半分しか進んでいないのに70224で打ち切ってしまう)。
bus_tick :: proc(bus: ^Bus, t_cycles: int) {
	bus.cycles += u64(t_cycles)
	hw_cycles := t_cycles
	if bus.double_speed {
		hw_cycles = t_cycles / 2
	}
	bus.hw_cycles += u64(hw_cycles)

	timer_tick(bus, t_cycles) // Timerは常にCPU側クロック(ダブルスピードで2倍速)
	ppu_tick(bus, hw_cycles) // PPUは実時間側(等速)
	apu_tick(&bus.apu, hw_cycles) // APUも実時間側(等速)
	for _ in 0 ..< t_cycles / 4 {
		dma_tick_one_mcycle(bus) // OAM DMAはCPU側クロックでのM-cycle単位のまま
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

// hdma_copy_block は現在の hdma_source/hdma_destination から16バイトを VRAM(現在の VBK
// バンク)へコピーし、両アドレスを次のブロックへ進める(T6-7)。宛先は0x1FF0でマスクした
// オフセットに折り返す(BubiBoy Bus.fs のHdma.copyBlock方式、VRAM境界を超えない)。
// ソース読み出しは bus_read_raw を再利用する(ROM/WRAM/VRAM等どの領域でも読める。
// dma_active によるバス競合0xFF化は受けない、OAM DMAと同じ扱い)。
@(private)
hdma_copy_block :: proc(bus: ^Bus) {
	dest_base := int(bus.hdma_destination - 0x8000)
	for offset in 0 ..< 16 {
		value := bus_read_raw(bus, bus.hdma_source + u16(offset))
		bus.vram[bus.vram_bank][dest_base + offset] = value
	}
	bus.hdma_source += 0x10
	bus.hdma_destination = 0x8000 | ((bus.hdma_destination + 0x10 - 0x8000) & 0x1FF0)
}

// hdma_run_general は GDMA(HDMA5 bit7=0)を実行する: (n+1)*16バイトを即座に全転送する。
// 「CPU停止時間も加算」(phase-06-cgb.md)を、転送1ブロックあたり8 T-cycleのbus_tickで
// 表現する(Pan Docs実測値相当、ダブルスピードでも同じT-cycle数を消費する=hw_cycles換算で
// 半分になりPPU/APU側は等速に見える。T6-6のbus_tick経由なので自動的にそうなる)。
@(private)
hdma_run_general :: proc(bus: ^Bus) {
	for bus.hdma_remaining > 0 {
		hdma_copy_block(bus)
		bus.hdma_remaining -= 1
		bus_tick(bus, 8)
	}
	bus.hdma_active = false
}

// hdma_start_or_cancel は HDMA5(FF55)への書き込みを処理する(T6-7)。
// 進行中のHDMA(HBlank毎転送)にbit7=0を書くと中断し、残りブロック数を記録して以後の
// FF55読み出しに反映する(落とし穴)。それ以外は新しい転送を開始する: bit7=1ならHDMA
// (HBlank毎に16バイト、ppu.odinのHBlank遷移フックが進める)、bit7=0ならGDMA(即時全転送)。
@(private)
hdma_start_or_cancel :: proc(bus: ^Bus, value: u8) {
	if bus.hdma_active && value & 0x80 == 0 {
		bus.hdma_aborted = true
		bus.hdma_aborted_remaining = bus.hdma_remaining
		bus.hdma_active = false
		return
	}

	length := int(value & 0x7F) + 1
	bus.hdma_remaining = length
	bus.hdma_aborted = false

	if value & 0x80 != 0 {
		bus.hdma_active = true // HDMA: HBlank毎にppu.odin側から1ブロックずつ進む
	} else {
		bus.hdma_active = false
		hdma_run_general(bus) // GDMA: ここで即時に全ブロック転送する
	}
}

// bus_vram_read_bank は指定バンクの VRAM を直接読む(PPU の BG/ウィンドウ属性バイト読み取り、
// HDMA のソース読み取りで使う。T6-2)。CPU バス経由ではないので dma_active 等の制限を受けない。
bus_vram_read_bank :: proc(bus: ^Bus, bank: u8, addr: u16) -> u8 {
	return bus.vram[bank & 1][addr - 0x8000]
}

// wram_active_bank は D000-DFFF(およびそのエコー)が実際に使う解決済みバンク番号(1-7)を返す
// (T6-3)。SVBK に 0 が書かれた場合の「0指定は1扱い」を書き込み時ではなくここで解決するため、
// bus_power_on を呼ばない生の Bus{}(テストで多用、T2-3等の既存慣習)でも常に正しく動く。
@(private)
wram_active_bank :: proc(bus: ^Bus) -> u8 {
	b := bus.wram_bank & 0x07
	return b == 0 ? 1 : b
}

// wram_locate はCPUアドレス(C000-DFFF または E000-FDFFのエコー)を実バンク番号とバンク内
// オフセットへ変換する(T6-3)。エコーRAMはC000-DDFFだけをミラーする(DE00-DFFFはミラー
// されない、実機のOAM領域との兼ね合いによる仕様どおりの範囲)。
// DMGモードではSVBKが無視され常に1が有効バンクなので(wram_active_bank参照)、
// 「C000-DFFF直結の2バンク相当」の落とし穴要件を自然に満たす。
@(private)
wram_locate :: proc(bus: ^Bus, addr: u16) -> (bank: u8, offset: u16) {
	a := addr
	if a >= 0xE000 {
		a -= 0x2000
	}
	if a <= 0xCFFF {
		return 0, a - 0xC000
	}
	return wram_active_bank(bus), a - 0xD000
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
		return mbc_read(&bus.cart, addr)
	case addr <= 0x9FFF:
		return bus.vram[bus.vram_bank][addr - 0x8000]
	case addr <= 0xBFFF:
		return mbc_read(&bus.cart, addr)
	case addr <= 0xFDFF:
		// C000-CFFFはバンク0固定、D000-DFFFはSVBK選択バンク、E000-FDFFはC000-DDFFのエコー
		// (T6-3、wram_locateが3領域まとめて解決する)。
		bank, offset := wram_locate(bus, addr)
		return bus.wram[bank][offset]
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
		mbc_write(&bus.cart, addr, value) // MBC バンク切替レジスタ(T4-2)
	case addr <= 0x9FFF:
		bus.vram[bus.vram_bank][addr - 0x8000] = value
	case addr <= 0xBFFF:
		mbc_write(&bus.cart, addr, value) // 外部RAM(T4-2)
	case addr <= 0xFDFF:
		bank, offset := wram_locate(bus, addr)
		bus.wram[bank][offset] = value
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
	if (addr >= NR10_ADDR && addr <= NR52_ADDR) || (addr >= WAVE_RAM_START && addr <= WAVE_RAM_END) {
		return apu_read_register(&bus.apu, addr)
	}
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
	case KEY1_ADDR:
		// CGB 専用レジスタ。bit7=現在の速度(読み専用)、bit0=切替準備(読み書き可)、
		// 残りは常に1で読める未使用bit(BubiBoy Bus.fs方式)。
		if bus.mode != .Cgb {
			return 0xFF
		}
		v: u8 = 0x7E
		if bus.double_speed {
			v |= 0x80
		}
		if bus.speed_switch_prepared {
			v |= 0x01
		}
		return v
	case VBK_ADDR:
		// CGB 専用レジスタ。DMG モードでは他の未実装レジスタと同じく 0xFF を返す
		// (BubiBoy Bus.fs の isCgb ガード方式に倣う)。
		if bus.mode != .Cgb {
			return 0xFF
		}
		return 0xFE | bus.vram_bank
	case HDMA1_ADDR, HDMA2_ADDR, HDMA3_ADDR, HDMA4_ADDR:
		// HDMA1-4は書き込み専用として扱う(BubiBoy Bus.fs同様、読み出しは他の未実装レジスタと
		// 同じ0xFF。実機ではソース/宛先レジスタの読み出しは仕様上未定義/使われない)。
		if bus.mode != .Cgb {
			return 0xFF
		}
		return 0xFF
	case HDMA5_ADDR:
		if bus.mode != .Cgb {
			return 0xFF
		}
		if bus.hdma_active {
			// 落とし穴: bit7は「非アクティブ」を表すので進行中は0のまま、下位7bitに残りブロック-1。
			return u8(bus.hdma_remaining - 1)
		}
		if bus.hdma_aborted {
			// 中断直後は残っていたブロック数-1をbit7=1つきで読める(BubiBoy Bus.fs方式)。
			return u8(bus.hdma_aborted_remaining - 1) | 0x80
		}
		return 0xFF // 非アクティブ(GDMA完了後・未使用時)
	case SVBK_ADDR:
		if bus.mode != .Cgb {
			return 0xFF
		}
		return 0xF8 | wram_active_bank(bus) // 0指定は1扱いなので読み出しも解決済みバンクを返す
	case BCPS_ADDR:
		if bus.mode != .Cgb {
			return 0xFF
		}
		return bus.bcps
	case BCPD_ADDR:
		// 落とし穴: 読み出しではオートインクリメントしない(書き込み時のみ)。
		if bus.mode != .Cgb {
			return 0xFF
		}
		return bus.bg_palette_ram[bus.bcps & 0x3F]
	case OCPS_ADDR:
		if bus.mode != .Cgb {
			return 0xFF
		}
		return bus.ocps
	case OCPD_ADDR:
		if bus.mode != .Cgb {
			return 0xFF
		}
		return bus.obj_palette_ram[bus.ocps & 0x3F]
	case:
		return 0xFF
	}
}

// palette_index_increment はBCPS/OCPSのオートインクリメントを適用した新しいインデックス
// レジスタ値を返す(T6-4)。bit7(オートインクリメント有効)が0なら何もしない。bit6は常に1で
// 読める未使用bitとして保持し、インデックス(bit5-0)だけ+1(64でラップ)する
// (BubiBoy CgbMemory.incrementPaletteIndex を移植)。
@(private)
palette_index_increment :: proc(index_reg: u8) -> u8 {
	if index_reg & 0x80 == 0 {
		return index_reg
	}
	return (index_reg & 0x80) | 0x40 | ((index_reg + 1) & 0x3F)
}

@(private)
bus_io_write :: proc(bus: ^Bus, addr: u16, value: u8) {
	if (addr >= NR10_ADDR && addr <= NR52_ADDR) || (addr >= WAVE_RAM_START && addr <= WAVE_RAM_END) {
		apu_write_register(&bus.apu, addr, value)
		return
	}
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
	case KEY1_ADDR:
		// bit0(切替準備)のみ書き込み可能。実際の速度反転はSTOP実行時(cpu.odin)に行う。
		if bus.mode == .Cgb {
			bus.speed_switch_prepared = value & 0x01 != 0
		}
	case VBK_ADDR:
		// 落とし穴(phase-06): DMG モードでは VBK 書き込みを無視しバンク0固定のままにする。
		if bus.mode == .Cgb {
			bus.vram_bank = value & 0x01
		}
	case HDMA1_ADDR:
		if bus.mode == .Cgb {
			bus.hdma_source = (u16(value) << 8) | (bus.hdma_source & 0x00F0)
		}
	case HDMA2_ADDR:
		// 落とし穴: 下位4bitは無視(常に0)。
		if bus.mode == .Cgb {
			bus.hdma_source = (bus.hdma_source & 0xFF00) | u16(value & 0xF0)
		}
	case HDMA3_ADDR:
		// 落とし穴: 上位3bitはマスクされ常に0x8000起点(VRAM内)になる。
		if bus.mode == .Cgb {
			bus.hdma_destination = 0x8000 | (u16(value & 0x1F) << 8) | (bus.hdma_destination & 0x00F0)
		}
	case HDMA4_ADDR:
		// 落とし穴: 下位4bitは無視(常に0)。
		if bus.mode == .Cgb {
			bus.hdma_destination = 0x8000 | (bus.hdma_destination & 0x1F00) | u16(value & 0xF0)
		}
	case HDMA5_ADDR:
		if bus.mode == .Cgb {
			hdma_start_or_cancel(bus, value)
		}
	case SVBK_ADDR:
		// 落とし穴(phase-06): DMG モードでは SVBK 書き込みを無視する。
		if bus.mode == .Cgb {
			bus.wram_bank = value & 0x07 // 0→1読み替えは読み出し/アドレス解決側(wram_active_bank)で行う
		}
	case BCPS_ADDR:
		if bus.mode == .Cgb {
			bus.bcps = value | 0x40 // bit6は常に1で読める(BubiBoy Bus.fs方式)
		}
	case BCPD_ADDR:
		if bus.mode == .Cgb {
			bus.bg_palette_ram[bus.bcps & 0x3F] = value
			bus.bcps = palette_index_increment(bus.bcps) // 落とし穴: 書き込み時のみオートインクリメント
		}
	case OCPS_ADDR:
		if bus.mode == .Cgb {
			bus.ocps = value | 0x40
		}
	case OCPD_ADDR:
		if bus.mode == .Cgb {
			bus.obj_palette_ram[bus.ocps & 0x3F] = value
			bus.ocps = palette_index_increment(bus.ocps)
		}
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
