package tests

import "core:fmt"
import "core:os"
import "core:testing"
import app "bbl:app"

// src/app/saveram.odin の単体テスト(T4-6)。パス導出とアトミック書き込み/読み込みの
// ラウンドトリップを検証する(cli_test.odin と同様、bbl:app を直接importする既存の慣習に従う)。

@(test)
test_save_ram_path_replaces_extension :: proc(t: ^testing.T) {
	testing.expect(t, app.save_ram_path_for_rom("game.gbc") == "game.sav")
	testing.expect(t, app.save_ram_path_for_rom("game.gb") == "game.sav")
	testing.expect(t, app.save_ram_path_for_rom("/roms/dir.with.dots/game.gbc") == "/roms/dir.with.dots/game.sav")
}

@(test)
test_save_ram_path_without_extension_appends_sav :: proc(t: ^testing.T) {
	testing.expect(t, app.save_ram_path_for_rom("game") == "game.sav")
}

@(test)
test_save_ram_write_atomic_and_load_roundtrip :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	save_path := fmt.tprintf("%s/bbl_saveram_test_roundtrip.sav", tmp_dir)
	bak_path := fmt.tprintf("%s.bak", save_path)
	defer os.remove(save_path)
	defer os.remove(bak_path)

	data1 := []u8{0x01, 0x02, 0x03, 0x04}
	testing.expect(t, app.save_ram_write_atomic(save_path, data1))

	loaded1, ok1 := app.save_ram_load(save_path)
	testing.expect(t, ok1)
	defer delete(loaded1)
	testing.expect(t, len(loaded1) == len(data1) && loaded1[0] == 0x01 && loaded1[3] == 0x04)

	// 2回目の書き込みでは.bakが作られ、本体は新しい内容に置き換わる。
	data2 := []u8{0xAA, 0xBB}
	testing.expect(t, app.save_ram_write_atomic(save_path, data2))

	loaded2, ok2 := app.save_ram_load(save_path)
	testing.expect(t, ok2)
	defer delete(loaded2)
	testing.expect(t, len(loaded2) == 2 && loaded2[0] == 0xAA && loaded2[1] == 0xBB)

	testing.expect(t, os.exists(bak_path), ".bakファイルが作られている")
}

@(test)
test_save_ram_load_missing_file_returns_not_ok :: proc(t: ^testing.T) {
	_, ok := app.save_ram_load("this_path_should_not_exist_bbl_test.sav")
	testing.expect(t, !ok)
}
