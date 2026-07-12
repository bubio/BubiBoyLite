package core

// PPU: LCD レジスタ群と VRAM/OAM アクセスの土台(T3-1)。
// モードタイミング(T3-2)、BG(T3-3)、ウィンドウ(T3-4)、スプライト(T3-5)描画は後続タスクで
// この上に積む。SDL2 に一切依存しない(architecture.md「core と app の分離」)。
// 参照: ~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Lcd.fs + Video.fs、Pan Docs "LCD Control" / "LCD Status"。

LCDC_ADDR :: 0xFF40
STAT_ADDR :: 0xFF41
SCY_ADDR :: 0xFF42
SCX_ADDR :: 0xFF43
LY_ADDR :: 0xFF44
LYC_ADDR :: 0xFF45
BGP_ADDR :: 0xFF47
OBP0_ADDR :: 0xFF48
OBP1_ADDR :: 0xFF49
WY_ADDR :: 0xFF4A
WX_ADDR :: 0xFF4B

// LCDC(FF40)のビット定義。references.md の表どおり。
LCDC_BIT_LCD_ENABLE :: 0x80
LCDC_BIT_WIN_MAP :: 0x40 // 0=0x9800, 1=0x9C00
LCDC_BIT_WIN_ENABLE :: 0x20
LCDC_BIT_BG_WIN_TILES :: 0x10 // 0=0x8800(signed,基点0x9000), 1=0x8000(unsigned)
LCDC_BIT_BG_MAP :: 0x08 // 0=0x9800, 1=0x9C00
LCDC_BIT_OBJ_SIZE :: 0x04 // 0=8x8, 1=8x16
LCDC_BIT_OBJ_ENABLE :: 0x02
LCDC_BIT_BG_ENABLE :: 0x01

// STAT(FF41)のビット定義。bit7は常に1、bit2/bit1-0はPPUが管理(書き込み不可)。
STAT_BIT_LYC_INT :: 0x40
STAT_BIT_OAM_INT :: 0x20
STAT_BIT_VBLANK_INT :: 0x10
STAT_BIT_HBLANK_INT :: 0x08
STAT_BIT_LYC_EQ :: 0x04
STAT_WRITABLE_MASK :: 0x78 // bit6-3のみ書き込みが反映される

// OAM 属性(attr)バイトのビット定義(T3-5で使用)。
OAM_ATTR_BG_PRIORITY :: 0x80
OAM_ATTR_Y_FLIP :: 0x40
OAM_ATTR_X_FLIP :: 0x20
OAM_ATTR_PALETTE :: 0x10 // DMG: OBP0/OBP1選択。CGBでもそのまま存在するが未使用(CGBパレットはbit2-0)

// CGB 属性ビット定義(T6-2)。BG/ウィンドウはタイルマップと同アドレスのバンク1、
// OAM はOAM自体のattrバイト(bit3=VRAMバンク, bit2-0=パレット番号)で共通のレイアウト。
CGB_ATTR_BG_PRIORITY :: 0x80 // BG属性のみ: BGをOBJより前面にする(T6-5の優先度表で使用)
CGB_ATTR_Y_FLIP :: 0x40
CGB_ATTR_X_FLIP :: 0x20
CGB_ATTR_BANK :: 0x08 // タイルデータの読み出し元VRAMバンク(0/1)
CGB_ATTR_PALETTE_MASK :: 0x07

// Ppu_Mode は STAT bit1-0 と同じ数値でエンコードする(u8(mode) がそのままビット値になる)。
Ppu_Mode :: enum u8 {
	HBlank  = 0,
	VBlank  = 1,
	OamScan = 2,
	Draw    = 3,
}

// DMG 4階調(グレースケール)。素直なグレーとする(BluePrint/phase-03指定)。
DMG_SHADE_0 :: 0xFFFFFFFF // 最も明るい
DMG_SHADE_1 :: 0xFFAAAAAA
DMG_SHADE_2 :: 0xFF555555
DMG_SHADE_3 :: 0xFF000000 // 最も暗い

Ppu :: struct {
	// レジスタ
	lcdc:        u8, // FF40
	stat_enable: u8, // FF41 のうち書き込み可能な bit6-3 のみ保持(bit7/bit2-0は読み出し時に合成)
	scy:         u8, // FF42
	scx:         u8, // FF43
	ly:          u8, // FF44(読み取り専用、PPU 内部でのみ更新)
	lyc:         u8, // FF45
	bgp:         u8, // FF47
	obp0:        u8, // FF48
	obp1:        u8, // FF49
	wy:          u8, // FF4A
	wx:          u8, // FF4B

	// PPU 内部状態(T3-2以降で使用)
	mode:          Ppu_Mode, // STAT bit1-0 相当
	lyc_equal:     bool, // STAT bit2 相当(LYC==LY)
	dot:           int, // 現在のラインの経過T-cycle(0..455)
	window_line:   int, // ウィンドウ内部ラインカウンタ(T3-4、LYとは別に数える)
	stat_irq_line: bool, // STAT blocking用の直近のOR条件(T3-2)

	// core が外界に公開する映像出力(architecture.md)
	framebuffer:    [SCREEN_WIDTH * SCREEN_HEIGHT]u32, // ARGB(0xAARRGGBB)、行優先(T3-3)
	bg_color_index: [SCREEN_WIDTH]u8, // 直近描画したラインのパレット適用前カラー番号(スプライト優先度判定用、T3-5)

	// T6-2: CGB の BG/ウィンドウ属性(バンク1のタイルマップと同アドレスから読む)。
	// DMGモードでは常にpalette=0・priority=falseのまま(属性バイトを読まない)。
	bg_cgb_palette:  [SCREEN_WIDTH]u8, // 属性bit2-0(パレット番号0-7)
	bg_cgb_priority: [SCREEN_WIDTH]bool, // 属性bit7(BG-to-OBJ優先。T6-5の優先度表で使用)
}

// ppu_read は FF40-FF45/FF47-FF4B の読み出しを扱う(FF46=DMAはbus.odinが別途処理)。
// STAT は bit7 常に1、bit2(LYC==LY)とbit1-0(モード)をPPU管理値から合成して返す。
ppu_read :: proc(bus: ^Bus, addr: u16) -> u8 {
	p := &bus.ppu
	switch addr {
	case LCDC_ADDR:
		return p.lcdc
	case STAT_ADDR:
		v: u8 = 0x80 | p.stat_enable | u8(p.mode)
		if p.lyc_equal {
			v |= STAT_BIT_LYC_EQ
		}
		return v
	case SCY_ADDR:
		return p.scy
	case SCX_ADDR:
		return p.scx
	case LY_ADDR:
		return p.ly
	case LYC_ADDR:
		return p.lyc
	case BGP_ADDR:
		return p.bgp
	case OBP0_ADDR:
		return p.obp0
	case OBP1_ADDR:
		return p.obp1
	case WY_ADDR:
		return p.wy
	case WX_ADDR:
		return p.wx
	case:
		return 0xFF
	}
}

// ppu_write は FF40-FF45/FF47-FF4B の書き込みを扱う。
// LY への書き込みは無視する(リセットではない。落とし穴として明記されている挙動)。
// STAT への書き込みは bit6-3 のみ反映され、bit2-0 は PPU が管理するため無視される。
ppu_write :: proc(bus: ^Bus, addr: u16, value: u8) {
	p := &bus.ppu
	switch addr {
	case LCDC_ADDR:
		was_enabled := p.lcdc & LCDC_BIT_LCD_ENABLE != 0
		p.lcdc = value
		now_enabled := p.lcdc & LCDC_BIT_LCD_ENABLE != 0
		if !was_enabled && now_enabled {
			ppu_enable(p)
		} else if was_enabled && !now_enabled {
			ppu_disable(p)
		}
		ppu_update_stat_irq(bus)
	case STAT_ADDR:
		p.stat_enable = value & STAT_WRITABLE_MASK
		ppu_update_stat_irq(bus)
	case SCY_ADDR:
		p.scy = value
	case SCX_ADDR:
		p.scx = value
	case LY_ADDR:
	// 読み取り専用: 書き込みは無視(落とし穴: リセットではない)
	case LYC_ADDR:
		p.lyc = value
		ppu_update_lyc_equal(p)
		ppu_update_stat_irq(bus)
	case BGP_ADDR:
		p.bgp = value
	case OBP0_ADDR:
		p.obp0 = value
	case OBP1_ADDR:
		p.obp1 = value
	case WY_ADDR:
		p.wy = value
	case WX_ADDR:
		p.wx = value
	}
}

// ppu_update_lyc_equal は STAT bit2(LYC==LY)を再評価する。LY/LYC いずれかが
// 変化するたびに呼ぶ(T3-2 の ppu_tick でも LY 更新後に呼ばれる)。
@(private)
ppu_update_lyc_equal :: proc(p: ^Ppu) {
	p.lyc_equal = p.ly == p.lyc
}

// ppu_power_on は実 BIOS を読み込まない方針(CLAUDE.md/architecture.md)のもと、
// DMG ブート ROM 完了直後の PPU レジスタ状態を直接セットする(T3-8で判明: この初期値を
// 入れないと、LCDをROM側で明示的に有効化しない一部のテストROM、例えば
// mooneye/acceptance/halt_ime0_ei が VBlank 割り込みを永遠に待ち続けてしまう)。
// 値は Pan Docs "Power Up Sequence" および BubiBoy Bus.fs の postBootIo で実測値として
// 採用されている DMG の post-boot register state: LCDC=0x91(画面ON・BG/OBJ有効・
// タイルデータ0x8000・BGマップ0x9800)、STAT=0x80(割り込み許可ビットはすべて0)、
// BGP=0xFC、OBP0=OBP1=0xFF。SCY/SCX/LYC/WY/WXは0。
ppu_power_on :: proc(p: ^Ppu) {
	p.lcdc = 0x91
	p.stat_enable = 0
	p.scy = 0
	p.scx = 0
	p.lyc = 0
	p.bgp = 0xFC
	p.obp0 = 0xFF
	p.obp1 = 0xFF
	p.wy = 0
	p.wx = 0
	p.ly = 0
	p.dot = 0
	p.mode = .OamScan
	p.window_line = 0
	p.stat_irq_line = false
	ppu_update_lyc_equal(p)
}

// --- モードタイミング(T3-2) ---
// 参照: ~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Lcd.fs(tick/modeFor)、Pan Docs "Rendering"/"STAT modes"。
//
// 1ライン=456 T-cycle。モード2(OAM scan)=80、モード3(描画)=172固定(可変長は実装しない)、
// 残りモード0(HBlank)。LY0-143が可視、144でVBlank割り込み+モード1、LY153の後LY=0へ。
// LCDC bit7=0(LCD off)中はLY=0・モード0固定でtickしない。

CYCLES_PER_LINE :: 456
MODE2_DOTS :: 80 // OAM scan
MODE3_DOTS :: 172 // 描画(固定長。可変長のペナルティは実装しない)
LINES_PER_FRAME :: 154
VBLANK_START_LINE :: 144

@(private)
ppu_mode_for :: proc(ly: u8, dot: int) -> Ppu_Mode {
	if ly >= VBLANK_START_LINE {
		return .VBlank
	}
	if dot < MODE2_DOTS {
		return .OamScan
	}
	if dot < MODE2_DOTS + MODE3_DOTS {
		return .Draw
	}
	return .HBlank
}

// ppu_stat_condition_line は STAT blocking 用の「現在成立している割り込み条件の OR」を返す:
// bit6(LYC==LY)、bit5(モード2)、bit4(モード1/VBlank)、bit3(モード0/HBlank)。
// モード3(描画中)には対応する STAT 割り込み源が無い。
@(private)
ppu_stat_condition_line :: proc(p: ^Ppu) -> bool {
	if p.lyc_equal && p.stat_enable & STAT_BIT_LYC_INT != 0 {
		return true
	}
	switch p.mode {
	case .OamScan:
		return p.stat_enable & STAT_BIT_OAM_INT != 0
	case .VBlank:
		return p.stat_enable & STAT_BIT_VBLANK_INT != 0
	case .HBlank:
		return p.stat_enable & STAT_BIT_HBLANK_INT != 0
	case .Draw:
		return false
	}
	return false
}

// ppu_update_stat_irq は STAT blocking(立ち上がりエッジでのみ発火)を実装する。
// STAT/LYC/LCDC への書き込み後と、ppu_tick でのモード/LY変化後の両方で呼ぶ。
@(private)
ppu_update_stat_irq :: proc(bus: ^Bus) {
	p := &bus.ppu
	line := ppu_stat_condition_line(p)
	if line && !p.stat_irq_line {
		interrupt_request(bus, .Stat)
	}
	p.stat_irq_line = line
}

// ppu_enable は LCDC bit7 が 0→1 になったときの初期化(ラインの先頭から再開)。
@(private)
ppu_enable :: proc(p: ^Ppu) {
	p.ly = 0
	p.dot = 0
	p.mode = .OamScan
	p.window_line = 0
	ppu_update_lyc_equal(p)
}

// ppu_disable は LCDC bit7 が 1→0 になったときの状態固定(LY=0・モード0)。
@(private)
ppu_disable :: proc(p: ^Ppu) {
	p.ly = 0
	p.dot = 0
	p.mode = .HBlank
	ppu_update_lyc_equal(p)
}

// ppu_tick は t_cycles ぶん PPU の状態を進める。bus_tick から呼ばれる想定
// (architecture.md のタイミングモデル: 1 T-cycle刻みで評価する。LY/モード遷移の
// エッジをまたぐ変化を見落とさないため timer.odin と同様に1サイクルずつ進める)。
// LCDC bit7=0の間は完全に停止する(落とし穴: 何もtickしない)。
ppu_tick :: proc(bus: ^Bus, t_cycles: int) {
	p := &bus.ppu
	if p.lcdc & LCDC_BIT_LCD_ENABLE == 0 {
		return
	}

	for _ in 0 ..< t_cycles {
		prev_mode := p.mode
		p.dot += 1
		if p.dot >= CYCLES_PER_LINE {
			p.dot = 0
			p.ly += 1
			if int(p.ly) >= LINES_PER_FRAME {
				p.ly = 0
				p.window_line = 0
			}
			ppu_update_lyc_equal(p)
		}
		p.mode = ppu_mode_for(p.ly, p.dot)

		if prev_mode != .VBlank && p.mode == .VBlank {
			interrupt_request(bus, .VBlank)
		}
		if prev_mode == .Draw && p.mode == .HBlank {
			ppu_render_scanline(bus)
		}

		// STAT blocking: 条件の OR が変化しうるのは LYC 一致・モードが変わった瞬間だけだが、
		// 判定自体は毎 T-cycle 行っても安価なので一律ここで評価する(取りこぼし防止)。
		ppu_update_stat_irq(bus)
	}
}

// rgb555_to_argb はCGBパレットRAMの1色(リトルエンディアン2バイト、bit4-0=R, 9-5=G, 14-10=B)を
// ARGBへ変換する(T6-4、architecture.md固定の変換式 `(c<<3)|(c>>2)` をそのまま使う。
// BubiBoyのガンマ補正/色滲みテーブルは使わない、フェーズ6タスク指定の決定)。
@(private)
rgb555_to_argb :: proc(raw: u16) -> u32 {
	expand := proc(c5: u16) -> u32 {
		c := u32(c5 & 0x1F)
		return (c << 3) | (c >> 2)
	}
	r := expand(raw & 0x1F)
	g := expand((raw >> 5) & 0x1F)
	b := expand((raw >> 10) & 0x1F)
	return 0xFF000000 | (r << 16) | (g << 8) | b
}

// cgb_palette_color はパレットRAM(BG/OBJいずれか)からpalette番号(0-7)・color_number(0-3)の
// 色を引きARGBへ変換する(T6-4)。1色=2バイト、パレット1本=8バイト(4色×2バイト)。
@(private)
cgb_palette_color :: proc(ram: ^[PALETTE_RAM_SIZE]u8, palette: u8, color_number: u8) -> u32 {
	index := (int(palette & 0x07) * 8 + int(color_number & 0x03) * 2) & 0x3F
	raw := u16(ram[index]) | (u16(ram[index + 1]) << 8)
	return rgb555_to_argb(raw)
}

// dmg_shade は BGP/OBPn から取り出した2bitシェード番号(0-3)を DMG 4階調の
// ARGB カラーへ変換する(T3-3、素直なグレー表現。BluePrint/phase-03指定)。
@(private)
dmg_shade :: proc(shade: u8) -> u32 {
	switch shade & 0x03 {
	case 0:
		return DMG_SHADE_0
	case 1:
		return DMG_SHADE_1
	case 2:
		return DMG_SHADE_2
	case:
		return DMG_SHADE_3
	}
}

// bg_tile_data_addr はタイルインデックスからタイルデータの先頭アドレスを求める
// (T3-3)。LCDC bit4=1: 0x8000 起点の unsigned index。bit4=0: 0x9000 起点の
// signed index(落とし穴: 基点は0x9000、i8キャストで計算する)。
@(private)
bg_tile_data_addr :: proc(lcdc: u8, tile_index: u8, row_in_tile: int) -> u16 {
	if lcdc & LCDC_BIT_BG_WIN_TILES != 0 {
		return u16(0x8000 + int(tile_index) * 16 + row_in_tile * 2)
	}
	signed_index := int(i8(tile_index))
	return u16(0x9000 + signed_index * 16 + row_in_tile * 2)
}

// bg_tile_pixel_color_number は VRAM バンク0上の2bppタイルデータ1行から指定列の
// カラー番号(0-3、パレット適用前)を取り出す。bit7が左端ピクセル。
// DMGモード(バンク0固定)およびCGBのバンク0選択タイル向け(T3-3、T6-2で bank 引数を追加)。
@(private)
bg_tile_pixel_color_number :: proc(bus: ^Bus, tile_addr: u16, col_in_tile: int) -> u8 {
	return tile_pixel_color_number(bus, 0, tile_addr, col_in_tile)
}

// tile_pixel_color_number は bg_tile_pixel_color_number の任意バンク版(T6-2)。
// CGB の BG/ウィンドウ/OBJ いずれも属性bit3(またはOAM属性bit3)でバンク0/1を選ぶ。
@(private)
tile_pixel_color_number :: proc(bus: ^Bus, bank: u8, tile_addr: u16, col_in_tile: int) -> u8 {
	low := bus_vram_read_bank(bus, bank, tile_addr)
	high := bus_vram_read_bank(bus, bank, tile_addr + 1)
	shift := uint(7 - col_in_tile)
	low_bit := (low >> shift) & 0x01
	high_bit := (high >> shift) & 0x01
	return low_bit | (high_bit << 1)
}

// Bg_Pixel はタイルマップ1ピクセル分の解決結果(T6-2)。DMGモードでは palette=0・
// priority=false 固定(属性バイトはCGBモードのときだけバンク1から読む)。
@(private = "file")
Bg_Pixel :: struct {
	color_number: u8, // 0-3、パレット適用前
	palette:      u8, // CGB属性bit2-0(BGパレット番号)。DMGでは常に0
	priority:     bool, // CGB属性bit7(BG-to-OBJ優先)。DMGでは常にfalse
}

// tile_map_pixel はタイルマップ(BG/ウィンドウ共通の形式)上の座標(source_x, source_y)が
// 指すタイルのピクセルを解決する(T6-2)。CGBモードでは「バンク1のタイルマップと同アドレス」
// (落とし穴)から属性バイトを読み、Y/Xフリップとタイルデータバンク選択に反映する。
@(private)
tile_map_pixel :: proc(bus: ^Bus, map_base: u16, lcdc: u8, source_x, source_y: int) -> Bg_Pixel {
	tile_col := source_x / 8
	tile_row := source_y / 8
	tile_map_addr := map_base + u16(tile_row * 32 + tile_col)
	tile_index := bus_vram_read_bank(bus, 0, tile_map_addr)

	attr: u8 = 0
	if bus.mode == .Cgb {
		attr = bus_vram_read_bank(bus, 1, tile_map_addr)
	}

	row_in_tile := source_y % 8
	col_in_tile := source_x % 8
	if attr & CGB_ATTR_Y_FLIP != 0 {
		row_in_tile = 7 - row_in_tile
	}
	if attr & CGB_ATTR_X_FLIP != 0 {
		col_in_tile = 7 - col_in_tile
	}

	tile_bank: u8 = 0
	if attr & CGB_ATTR_BANK != 0 {
		tile_bank = 1
	}

	tile_addr := bg_tile_data_addr(lcdc, tile_index, row_in_tile)
	color_number := tile_pixel_color_number(bus, tile_bank, tile_addr, col_in_tile)

	return Bg_Pixel{color_number = color_number, palette = attr & CGB_ATTR_PALETTE_MASK, priority = attr & CGB_ATTR_BG_PRIORITY != 0}
}

// ppu_render_scanline は1ライン分をframebufferに描く(T3-3: BG、T3-4: ウィンドウ、
// T3-5: スプライト)。
// LCDC bit0=0のときBG・ウィンドウとも白一色になる(DMGではbit0がBG&ウィンドウ全体の
// 有効/無効を兼ねる。このときも bg_color_index は0にする。T3-5のスプライト優先度
// 判定でBG不透明扱いされないようにするため)。スプライトはbit0とは独立にbit1で
// 制御されるため、bit0=0でも(bit1が有効なら)描画され続ける。
// T6-5の落とし穴: CGBモードではLCDC bit0の意味が変わり「BG/ウィンドウのマスタープライオリティ」
// になる(0でもBG/ウィンドウは通常どおり描画され続け、OBJが常にBGより前面になるだけ。
// Pan Docs "LCDC.0")。そのためこの白一色化・早期returnはDMGモード限定で行う。
@(private)
ppu_render_scanline :: proc(bus: ^Bus) {
	p := &bus.ppu
	if int(p.ly) >= SCREEN_HEIGHT {
		return
	}
	line_start := int(p.ly) * SCREEN_WIDTH

	if bus.mode != .Cgb && p.lcdc & LCDC_BIT_BG_ENABLE == 0 {
		for x in 0 ..< SCREEN_WIDTH {
			p.framebuffer[line_start + x] = DMG_SHADE_0
			p.bg_color_index[x] = 0
			p.bg_cgb_palette[x] = 0
			p.bg_cgb_priority[x] = false
		}
		// 落とし穴: LCDC bit0=0はBG/ウィンドウのみを白くする。スプライトはbit1が
		// 有効なら(DMGでは)独立して表示され続ける(Pan Docs "LCDC.0")。
		ppu_render_sprites(bus, line_start)
		return
	}

	bg_map_base: u16 = 0x9800
	if p.lcdc & LCDC_BIT_BG_MAP != 0 {
		bg_map_base = 0x9C00
	}

	win_map_base: u16 = 0x9800
	if p.lcdc & LCDC_BIT_WIN_MAP != 0 {
		win_map_base = 0x9C00
	}

	// ウィンドウがこのラインで実際に描画されるか(T3-4: 内部ラインカウンタを
	// LYで代用するとdmg-acid2が落ちる落とし穴。LY>=WYの間だけ、かつ実際に
	// 少なくとも1ピクセル描画するラインだけで window_line を進める)。
	win_enabled := p.lcdc & LCDC_BIT_WIN_ENABLE != 0
	wx_minus7 := int(p.wx) - 7 // WX=7が画面左端(落とし穴)
	win_visible_this_line := win_enabled && int(p.ly) >= int(p.wy) && wx_minus7 < SCREEN_WIDTH

	for x in 0 ..< SCREEN_WIDTH {
		pixel: Bg_Pixel
		if win_visible_this_line && x >= wx_minus7 {
			// ウィンドウの行はLYではなく window_line(実際に描いたラインだけ+1)で数える。
			pixel = tile_map_pixel(bus, win_map_base, p.lcdc, x - wx_minus7, p.window_line)
		} else {
			source_x := (x + int(p.scx)) & 0xFF // 256x256マップ内でラップアラウンド
			source_y := (int(p.ly) + int(p.scy)) & 0xFF
			pixel = tile_map_pixel(bus, bg_map_base, p.lcdc, source_x, source_y)
		}

		// ウィンドウ画素もスプライト優先度判定では「BG扱い」なので同じバッファに記録する。
		p.bg_color_index[x] = pixel.color_number
		p.bg_cgb_palette[x] = pixel.palette
		p.bg_cgb_priority[x] = pixel.priority
		// T6-4: CGBモードはパレットRAM(BGP/OBPは無視)、DMGモードは従来どおりBGPのグレー4階調。
		if bus.mode == .Cgb {
			p.framebuffer[line_start + x] = cgb_palette_color(&bus.bg_palette_ram, pixel.palette, pixel.color_number)
		} else {
			shade := (p.bgp >> (pixel.color_number * 2)) & 0x03
			p.framebuffer[line_start + x] = dmg_shade(shade)
		}
	}

	if win_visible_this_line {
		p.window_line += 1
	}

	ppu_render_sprites(bus, line_start)
}

// Oam_Sprite は1ラインの描画対象として収集したOAMエントリのスナップショット(T3-5)。
@(private = "file")
Oam_Sprite :: struct {
	oam_index: int, // 0-39(同X時のタイブレーク用。小さいほど優先)
	x:         int, // 画面X座標(OAMのX-8。画面外もありうる)
	y:         int, // 画面Y座標(OAMのY-16)
	tile:      u8,
	attr:      u8,
}

// ppu_collect_line_sprites は OAM を先頭(index0)から走査し、このラインに掛かる
// スプライトを最初の10個まで集める(落とし穴: X座標に関係なくOAM順で先着10個。
// 画面外Xのスプライトも枠を消費する)。
@(private)
ppu_collect_line_sprites :: proc(bus: ^Bus, sprite_height: int, sprites: ^[10]Oam_Sprite) -> int {
	count := 0
	ly := int(bus.ppu.ly)
	for i in 0 ..< 40 {
		if count >= 10 {
			break
		}
		base := i * 4
		y := int(bus.oam[base + 0]) - 16
		y_in_sprite := ly - y
		if y_in_sprite < 0 || y_in_sprite >= sprite_height {
			continue
		}
		sprites[count] = Oam_Sprite {
			oam_index = i,
			x         = int(bus.oam[base + 1]) - 8,
			y         = y,
			tile      = bus.oam[base + 2],
			attr      = bus.oam[base + 3],
		}
		count += 1
	}
	return count
}

// ppu_sort_sprites_by_priority は収集済みスプライトを DMG の優先度順
// (X座標が小さいほど優先、同Xなら OAM 順(indexが小さいほど優先))に並べ替える
// (挿入ソート、最大10件なので十分高速)。
@(private)
ppu_sort_sprites_by_priority :: proc(sprites: ^[10]Oam_Sprite, count: int) {
	for i in 1 ..< count {
		cur := sprites[i]
		j := i - 1
		for j >= 0 && (sprites[j].x > cur.x || (sprites[j].x == cur.x && sprites[j].oam_index > cur.oam_index)) {
			sprites[j + 1] = sprites[j]
			j -= 1
		}
		sprites[j + 1] = cur
	}
}

// cgb_obj_wins_over_bg はCGBモードのBG-to-OBJ優先度表(Pan Docs "BG-to-OBJ Priority in CGB
// Mode")を実装する(T6-5)。呼び出し側は「trueならOBJを描画してよい、falseならBGを残す」
// として使う(OBJ側のcolor_number=0=透明は呼び出し側で既に除外済みの前提)。
// 表(優先順): (1) LCDC bit0=0(マスタープライオリティ無効)ならOBJが常に勝つ。
// (2) BGのcolor_numberが0(透明)ならOBJが勝つ。(3) BG属性bit7(bg_priority)が立っていれば
// BGが勝つ。(4) OAM属性bit7(oam_priority)が立っていればBGが勝つ。(5) それ以外はOBJが勝つ。
@(private)
cgb_obj_wins_over_bg :: proc(p: ^Ppu, bg_color_number: u8, bg_priority: bool, oam_priority: bool) -> bool {
	if p.lcdc & LCDC_BIT_BG_ENABLE == 0 {
		return true
	}
	if bg_color_number == 0 {
		return true
	}
	if bg_priority {
		return false
	}
	if oam_priority {
		return false
	}
	return true
}

// ppu_render_sprites はこのラインのスプライト(8x8/8x16)を優先度込みで描画する(T3-5、
// CGBのOAM順優先度・BG-to-OBJ優先度表はT6-5)。
// DMGの優先度: X座標が小さいスプライトが勝つ(同Xなら OAM 順)。CGBの優先度: X座標に
// 関係なくOAM順(先頭が勝つ)。一度確定したピクセルは他のスプライトに上書きされない
// (pixel_owned で管理、この「スプライト間」の優先度は「スプライトとBGの間」の優先度
// (cgb_bg_wins_over_obj/DMGのattr bit7)とは独立)。スプライトのカラー0は常に透明。
@(private)
ppu_render_sprites :: proc(bus: ^Bus, line_start: int) {
	p := &bus.ppu
	if p.lcdc & LCDC_BIT_OBJ_ENABLE == 0 {
		return
	}

	sprite_height := 8
	if p.lcdc & LCDC_BIT_OBJ_SIZE != 0 {
		sprite_height = 16
	}

	sprites: [10]Oam_Sprite
	count := ppu_collect_line_sprites(bus, sprite_height, &sprites)
	if count == 0 {
		return
	}
	// 落とし穴(T6-5): CGBではOAM順優先度(先頭が勝つ)なのでソートしない
	// (ppu_collect_line_sprites が既にOAM index0からの走査順で詰めている)。
	// DMGモードのみX座標優先(同Xなら OAM 順)にソートする。
	if bus.mode != .Cgb {
		ppu_sort_sprites_by_priority(&sprites, count)
	}

	pixel_owned: [SCREEN_WIDTH]bool

	for s in sprites[:count] {
		tile_index := s.tile
		if sprite_height == 16 {
			tile_index &= 0xFE // 落とし穴: 8x16では下位bit無視(タイルペアの先頭に丸める)
		}

		y_in_sprite := int(p.ly) - s.y
		if s.attr & OAM_ATTR_Y_FLIP != 0 {
			y_in_sprite = sprite_height - 1 - y_in_sprite
		}
		tile_offset: u8 = 0
		if sprite_height == 16 && y_in_sprite >= 8 {
			tile_offset = 1
		}
		row_in_tile := y_in_sprite % 8
		tile_addr := u16(0x8000 + int(tile_index + tile_offset) * 16 + row_in_tile * 2)

		// T6-2: CGBのOAM属性bit3はタイルデータの読み出し元VRAMバンクを選ぶ(DMGモードでは
		// この属性ビット自体を無視してバンク0固定)。
		sprite_tile_bank: u8 = 0
		if bus.mode == .Cgb && s.attr & CGB_ATTR_BANK != 0 {
			sprite_tile_bank = 1
		}

		for col in 0 ..< 8 {
			x := s.x + col
			if x < 0 || x >= SCREEN_WIDTH || pixel_owned[x] {
				continue
			}

			source_col := col
			if s.attr & OAM_ATTR_X_FLIP != 0 {
				source_col = 7 - col
			}
			color_number := tile_pixel_color_number(bus, sprite_tile_bank, tile_addr, source_col)
			if color_number == 0 {
				continue // スプライトのカラー0は透明(ピクセルの所有権も取らない)
			}

			pixel_owned[x] = true // スプライト間優先度でこのピクセルはこのスプライトが確定(BG優先度とは独立)

			if bus.mode == .Cgb {
				if !cgb_obj_wins_over_bg(p, p.bg_color_index[x], p.bg_cgb_priority[x], s.attr & OAM_ATTR_BG_PRIORITY != 0) {
					continue // BGが前面(T6-5の優先度表)
				}
			} else if s.attr & OAM_ATTR_BG_PRIORITY != 0 && p.bg_color_index[x] != 0 {
				continue // BGカラー1-3の上には描かない(DMGの優先度規則)
			}

			// T6-4: CGBモードはOAM属性bit2-0のパレット番号でパレットRAMを引く。
			// DMGモードは従来どおりOBP0/OBP1(attr bit4で選択)。
			if bus.mode == .Cgb {
				cgb_palette := s.attr & CGB_ATTR_PALETTE_MASK
				p.framebuffer[line_start + x] = cgb_palette_color(&bus.obj_palette_ram, cgb_palette, color_number)
			} else {
				palette := p.obp0
				if s.attr & OAM_ATTR_PALETTE != 0 {
					palette = p.obp1
				}
				shade := (palette >> (color_number * 2)) & 0x03
				p.framebuffer[line_start + x] = dmg_shade(shade)
			}
		}
	}
}
