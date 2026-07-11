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
OAM_ATTR_PALETTE :: 0x10

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
		p.lcdc = value
	case STAT_ADDR:
		p.stat_enable = value & STAT_WRITABLE_MASK
	case SCY_ADDR:
		p.scy = value
	case SCX_ADDR:
		p.scx = value
	case LY_ADDR:
	// 読み取り専用: 書き込みは無視(落とし穴: リセットではない)
	case LYC_ADDR:
		p.lyc = value
		ppu_update_lyc_equal(p)
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
