package tests

import "core:testing"
import core "bbl:core"

// T3-4: ウィンドウ描画の単体テスト。
// DoD: WY/WX 指定でウィンドウ切り替わり位置のピクセル検証。
// 途中で WY を跨いだ場合の内部カウンタ挙動(LYで代用するとdmg-acid2が落ちる落とし穴)。

@(private = "file")
tick_n_lines :: proc(bus: ^core.Bus, n: int) {
	for _ in 0 ..< n {
		core.bus_tick(bus, core.CYCLES_PER_LINE)
	}
}

@(test)
test_ppu_window_switches_at_wx_wy_boundary :: proc(t: ^testing.T) {
	bus: core.Bus

	// BG用タイル2(0x9C00マップ、unsigned): 全8行をcolor1で埋める(どのLYでも同じ色になるように)。
	for row in 0 ..< 8 {
		core.bus_write(&bus, u16(0x8000 + 2 * 16 + row * 2 + 0), 0xFF)
		core.bus_write(&bus, u16(0x8000 + 2 * 16 + row * 2 + 1), 0x00)
	}
	// ウィンドウ用タイル1(0x9800マップ): 全8行をcolor3で埋める。
	for row in 0 ..< 8 {
		core.bus_write(&bus, u16(0x8000 + 1 * 16 + row * 2 + 0), 0xFF)
		core.bus_write(&bus, u16(0x8000 + 1 * 16 + row * 2 + 1), 0xFF)
	}

	// BGマップ(0x9C00): x=42(tile_col5)・x=50を含むtile_col6 をタイル2に。
	// LY=5(tile_row0)とLY=10(tile_row1)の両方で参照されるため両方の行に書く。
	core.bus_write(&bus, 0x9C00 + 0 * 32 + 5, 2)
	core.bus_write(&bus, 0x9C00 + 0 * 32 + 6, 2)
	core.bus_write(&bus, 0x9C00 + 1 * 32 + 5, 2)
	core.bus_write(&bus, 0x9C00 + 1 * 32 + 6, 2)
	// ウィンドウマップ(0x9800): source_x=0(tile_col0)をタイル1に。
	core.bus_write(&bus, 0x9800 + 0, 1)

	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	core.bus_write(&bus, core.WX_ADDR, 50) // wx-7=43
	core.bus_write(&bus, core.WY_ADDR, 10)

	// LCD on, unsignedタイル, BGマップ0x9C00, ウィンドウ有効, BG有効
	LCDC :: 0x80 | 0x10 | 0x08 | 0x20 | 0x01
	core.bus_write(&bus, core.LCDC_ADDR, LCDC)

	// LY=5(<WY=10): ウィンドウはまだ表示されず、x=43もBGが見えるはず。
	tick_n_lines(&bus, 6) // renders ly=0..5
	got_before_wy := bus.ppu.framebuffer[5 * core.SCREEN_WIDTH + 43]
	testing.expectf(
		t,
		got_before_wy == core.DMG_SHADE_1,
		"LY(5)<WY(10)のときはBGが見えるはず, got=%08X",
		got_before_wy,
	)

	// LY=10(>=WY): x=42(<WX-7=43)はBG、x=43(>=WX-7)はウィンドウが見えるはず。
	tick_n_lines(&bus, 5) // renders ly=6..10
	got_bg_side := bus.ppu.framebuffer[10 * core.SCREEN_WIDTH + 42]
	testing.expectf(t, got_bg_side == core.DMG_SHADE_1, "x=42(WX境界の左)はBGのはず, got=%08X", got_bg_side)

	got_win_side := bus.ppu.framebuffer[10 * core.SCREEN_WIDTH + 43]
	testing.expectf(
		t,
		got_win_side == core.DMG_SHADE_3,
		"x=43(WX境界、WX-7以降)はウィンドウのはず, got=%08X",
		got_win_side,
	)
}

@(test)
test_ppu_window_internal_line_counter_not_ly_substitute :: proc(t: ^testing.T) {
	bus: core.Bus

	// ウィンドウ用タイル0(unsigned、0x8000起点): タイル内の行ごとに異なる2bppパターンを
	// 書き込み、どのタイル内行(row_in_tile = window_line % 8)が使われたかを判別できるようにする。
	core.bus_write(&bus, 0x8000 + 0, 0xFF) // row0: low
	core.bus_write(&bus, 0x8000 + 1, 0x00) // row0: high => color1
	core.bus_write(&bus, 0x8000 + 2, 0x00) // row1: low
	core.bus_write(&bus, 0x8000 + 3, 0xFF) // row1: high => color2
	core.bus_write(&bus, 0x8000 + 6, 0x00) // row3: low
	core.bus_write(&bus, 0x8000 + 7, 0x00) // row3: high => color0

	// BG用タイル5: 全8行をcolor1で埋める(どのLYでも同じ色になるように、ウィンドウ非表示時の対照用)。
	for row in 0 ..< 8 {
		core.bus_write(&bus, u16(0x8000 + 5 * 16 + row * 2 + 0), 0xFF)
		core.bus_write(&bus, u16(0x8000 + 5 * 16 + row * 2 + 1), 0x00)
	}

	// タイルマップ: BGは0x9C00(LCDC bit3=1)、ウィンドウは0x9800(LCDC bit6=0、デフォルト)。
	core.bus_write(&bus, 0x9C00 + 0, 5) // BG tile(0,0) -> タイル5
	// ウィンドウ tile(0,0) は書かなければ0のままなのでタイル0を指す(デフォルトでOK)。

	core.bus_write(&bus, core.BGP_ADDR, 0xE4)
	core.bus_write(&bus, core.WY_ADDR, 0)
	core.bus_write(&bus, core.WX_ADDR, 7) // wx-7=0、画面左端から表示

	LCDC_WIN_ON :: 0x80 | 0x10 | 0x08 | 0x20 | 0x01 // LCD on, unsigned, BGマップ0x9C00, ウィンドウ有効, BG有効
	LCDC_WIN_OFF :: 0x80 | 0x10 | 0x08 | 0x01 // ウィンドウ無効(bit5=0)、他は同じ

	// line0: ウィンドウ有効(window_line=0で描画 -> 使用後1になる)
	core.bus_write(&bus, core.LCDC_ADDR, LCDC_WIN_ON)
	tick_n_lines(&bus, 1)
	got0 := bus.ppu.framebuffer[0]
	testing.expectf(t, got0 == core.DMG_SHADE_1, "line0: window_line=0(color1)のはず, got=%08X", got0)

	// line1,2: ウィンドウ無効化(BGが見える。window_lineは進まないはず)
	core.bus_write(&bus, core.LCDC_ADDR, LCDC_WIN_OFF)
	tick_n_lines(&bus, 2)
	got1 := bus.ppu.framebuffer[1 * core.SCREEN_WIDTH]
	testing.expectf(t, got1 == core.DMG_SHADE_1, "line1: BGのcolor1が見えるはず, got=%08X", got1)

	// line3: ウィンドウ再度有効化。LY=3だがwindow_lineは1のまま(0→1で止まっていた)ため
	// row_in_tile=1(color2)が使われるべき。LYをそのまま使う実装だとLY-WY=3でrow_in_tile=3
	// (color0)になってしまう(落とし穴の直接的な検出)。
	core.bus_write(&bus, core.LCDC_ADDR, LCDC_WIN_ON)
	tick_n_lines(&bus, 1)
	got3 := bus.ppu.framebuffer[3 * core.SCREEN_WIDTH]
	testing.expectf(
		t,
		got3 == core.DMG_SHADE_2,
		"line3: window_line=1(color2)のはず(LY-WYを直接使うと誤ってcolor0になる), got=%08X",
		got3,
	)
}
