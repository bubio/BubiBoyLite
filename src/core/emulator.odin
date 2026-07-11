package core

// エミュレータ全体の統合。SDL2 に一切依存しない（architecture.md「core と app の分離」）。
// フェーズ0で追加したテストパターン描画(framebuffer)に加え、T3-6でCpu/Busを組み込み
// emulator_step/emulator_run_frameを実装した(ROM実行時の実映像はbus.ppu.framebufferに
// 出る。architecture.md「実行」/「core が外界に公開するインターフェイス」)。

Emulator :: struct {
	framebuffer: [SCREEN_WIDTH * SCREEN_HEIGHT]u32, // ARGB (0xAARRGGBB)、行優先。ROM未ロード時のテストパターン専用
	cpu:         Cpu,
	bus:         Bus,
}

// emulator_load_rom はカートリッジ(ヘッダ解析 + MBC 初期化、T4-1/T4-2)をロードし、CPUを
// ブートROM完了直後の状態(references.md「ブート後レジスタ初期値」)にリセットする。
// 失敗時は emu.bus.cart_load_error に理由が残る(cartridge_error_message で整形できる)。
// rom_data の所有権は呼び出し側に残る(bus.cart.rom はスライスをそのまま参照するだけなので、
// Emulator が使われている間は呼び出し側が rom_data を解放しないこと)。
emulator_load_rom :: proc(emu: ^Emulator, rom_data: []u8) -> bool {
	if !bus_load_rom(&emu.bus, rom_data) {
		return false
	}
	bus_power_on(&emu.bus)
	cpu_reset(&emu.cpu, .DMG)
	return true
}

// emulator_set_wall_clock は MBC3 RTC(T4-4)へ現在時刻(UNIX秒)を供給する。
// core は時計を直接読まない方針(architecture.md「エラー処理」と同じ「core は外界に依存しない」
// 原則、テスト容易性のため)なので、壁時計の取得は app 側の責務になる。RTC を持たない
// カートリッジでは何もしない(mbc_sync_wall_clock 内でガードする)。
emulator_set_wall_clock :: proc(emu: ^Emulator, unix_seconds: i64) {
	mbc_sync_wall_clock(&emu.bus.cart, unix_seconds)
}

// emulator_step は1命令ぶんCPUを実行する(architecture.md「実行」)。戻り値は消費したT-cycle数。
emulator_step :: proc(emu: ^Emulator) -> int {
	return cpu_step(&emu.cpu, &emu.bus)
}

// emulator_run_frame は1フレーム(70224 T-cycle)ぶん実行する(architecture.md「実行」)。
// cpu_stepは命令単位でしか止まれず1フレームちょうどでは終わらない(オーバーシュートする)ため、
// 累計サイクル数(emu.bus.cycles)を基準に「フレーム開始時点+70224に達するまで」ループする。
// 余剰分は自然に次フレームへ持ち越されるので、毎フレーム0から数え直す方式(誤差が蓄積して
// ドリフトする)は採らない。
emulator_run_frame :: proc(emu: ^Emulator) {
	frame_end := emu.bus.cycles + CYCLES_PER_FRAME
	for emu.bus.cycles < frame_end {
		cpu_step(&emu.cpu, &emu.bus)
	}
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
