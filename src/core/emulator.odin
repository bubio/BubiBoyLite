package core

// エミュレータ全体の統合。フェーズ 0 では骨格とテストパターン描画のみ。
// SDL2 に一切依存しない（architecture.md「core と app の分離」）。

Emulator :: struct {
	framebuffer: [SCREEN_WIDTH * SCREEN_HEIGHT]u32, // ARGB (0xAARRGGBB)、行優先
}

// emulator_render_test_pattern は横グラデーション + 縦グラデーション + 四隅マーカーを
// framebuffer に書き込む。SDL2 ウィンドウの表示経路を目視確認するためのもの。
emulator_render_test_pattern :: proc(emu: ^Emulator) {
	for y in 0 ..< SCREEN_HEIGHT {
		for x in 0 ..< SCREEN_WIDTH {
			r := u32(x * 255 / (SCREEN_WIDTH - 1))
			g := u32(y * 255 / (SCREEN_HEIGHT - 1))
			b: u32 = 128
			emu.framebuffer[y * SCREEN_WIDTH + x] = 0xFF000000 | (r << 16) | (g << 8) | b
		}
	}

	marker_size :: 8
	draw_marker(emu, 0, 0, marker_size, 0xFFFF0000) // 左上: 赤
	draw_marker(emu, SCREEN_WIDTH - marker_size, 0, marker_size, 0xFF00FF00) // 右上: 緑
	draw_marker(emu, 0, SCREEN_HEIGHT - marker_size, marker_size, 0xFF0000FF) // 左下: 青
	draw_marker(emu, SCREEN_WIDTH - marker_size, SCREEN_HEIGHT - marker_size, marker_size, 0xFFFFFFFF) // 右下: 白
}

@(private)
draw_marker :: proc(emu: ^Emulator, x0, y0, size: int, color: u32) {
	for y in y0 ..< y0 + size {
		for x in x0 ..< x0 + size {
			emu.framebuffer[y * SCREEN_WIDTH + x] = color
		}
	}
}
