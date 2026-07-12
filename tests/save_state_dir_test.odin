package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "bbl:app"
import core "bbl:core"

// src/app/saveram.odin, statefile.odin の保存先ディレクトリ設定(T8-4)の単体テスト。
// BluePrint「セーブ、ステートファイルの場所」: デフォルトはROMと同じ場所、bbl.ini の
// save_dir/state_dir で変更可能。パスの組み立て自体は純粋関数だが、ディレクトリ作成を
// 伴うものは statefile_test.odin の慣習(os.temp_dir + テスト用合成ROM)に合わせる。

@(private = "file")
make_dir_test_rom :: proc() -> []u8 {
	rom := make([]u8, 16 * 1024 * 2)
	rom[core.HEADER_TYPE_ADDR] = 0x03 // MBC1+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = 0x00
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02
	return rom
}

@(test)
test_rom_dir_and_stem :: proc(t: ^testing.T) {
	testing.expect(t, app.rom_dir("/roms/sub/game.gbc") == "/roms/sub")
	testing.expect(t, app.rom_dir("game.gbc") == ".")
	testing.expect(t, app.rom_stem("/roms/sub/game.gbc") == "game")
	testing.expect(t, app.rom_stem("game.gbc") == "game")
	testing.expect(t, app.rom_stem("/roms/dir.with.dots/game.gbc") == "game")
}

@(test)
test_save_ram_path_with_empty_dir_matches_default :: proc(t: ^testing.T) {
	rom_path := "/roms/game.gbc"
	testing.expect(
		t,
		app.save_ram_path_for_rom_with_dir(rom_path, "") == app.save_ram_path_for_rom(rom_path),
	)
}

@(test)
test_rtc_path_with_empty_dir_matches_default :: proc(t: ^testing.T) {
	rom_path := "/roms/game.gbc"
	testing.expect(t, app.rtc_path_for_rom_with_dir(rom_path, "") == app.rtc_path_for_rom(rom_path))
}

@(test)
test_state_path_with_empty_dir_matches_default :: proc(t: ^testing.T) {
	rom_path := "/roms/game.gbc"
	testing.expect(
		t,
		app.state_path_for_rom_with_dir(rom_path, 1, "") == app.state_path_for_rom(rom_path, 1),
	)
	testing.expect(
		t,
		app.state_path_for_rom_with_dir(rom_path, 3, "") == app.state_path_for_rom(rom_path, 3),
	)
}

@(test)
test_save_ram_path_with_explicit_dir_creates_and_joins :: proc(t: ^testing.T) {
	tmp_root, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_root)

	tmp_base := fmt.tprintf("%s/bbl_test_save_dir", tmp_root)
	defer os.remove_all(tmp_base)

	rom_path := "/some/where/mygame.gbc"
	path := app.save_ram_path_for_rom_with_dir(rom_path, tmp_base)
	testing.expect(t, strings.has_prefix(path, tmp_base))
	testing.expect(t, strings.has_suffix(path, "mygame.sav"))
	testing.expect(t, os.exists(tmp_base), "設定したディレクトリが作成されているはず")
}

@(test)
test_state_path_with_explicit_dir_and_slot :: proc(t: ^testing.T) {
	tmp_root, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_root)

	tmp_base := fmt.tprintf("%s/bbl_test_state_dir", tmp_root)
	defer os.remove_all(tmp_base)

	rom_path := "/some/where/mygame.gbc"
	path1 := app.state_path_for_rom_with_dir(rom_path, 1, tmp_base)
	path2 := app.state_path_for_rom_with_dir(rom_path, 2, tmp_base)
	testing.expect(t, strings.has_suffix(path1, "mygame.state"))
	testing.expect(t, strings.has_suffix(path2, "mygame.state2"))
	testing.expect(t, strings.has_prefix(path1, tmp_base))
}

@(test)
test_resolve_and_ensure_dir_falls_back_on_unwritable_path :: proc(t: ^testing.T) {
	// 書き込み不可/作成不能なパスを指定した場合、ROMと同じディレクトリへフォールバックし、
	// クラッシュしないことを確認する(T8-4「落とし穴」)。/dev/null をディレクトリの
	// 親として使うと mkdir が確実に失敗する(/dev/null はファイルであってディレクトリではない)。
	rom_path := "/roms/game.gbc"
	bogus := "/dev/null/this/cannot/be/a/directory"
	dir := app.resolve_and_ensure_dir(bogus, rom_path)
	defer delete(dir)
	testing.expect(t, dir == app.rom_dir(rom_path), "作成失敗時はROMと同じディレクトリにフォールバックするはず")
}

@(test)
test_expand_path_tilde :: proc(t: ^testing.T) {
	home, home_ok := os.lookup_env("HOME", context.temp_allocator)
	if !home_ok {
		return // HOME未設定の環境ではスキップ(CI等の特殊環境向け)
	}
	expanded := app.expand_path("~/bbl_saves")
	defer delete(expanded)
	expected := fmt.tprintf("%s/bbl_saves", home)
	testing.expect(t, expanded == expected)
}

@(test)
test_expand_path_env_var :: proc(t: ^testing.T) {
	os.set_env("BBL_TEST_VAR", "/tmp/bbl_test_env")
	defer os.unset_env("BBL_TEST_VAR")

	expanded := app.expand_path("$BBL_TEST_VAR/saves")
	defer delete(expanded)
	testing.expect(t, expanded == "/tmp/bbl_test_env/saves")
}

@(test)
test_expand_path_no_special_chars_passthrough :: proc(t: ^testing.T) {
	expanded := app.expand_path("/absolute/path/saves")
	defer delete(expanded)
	testing.expect(t, expanded == "/absolute/path/saves")
}

@(test)
test_state_save_load_round_trip_with_explicit_dir :: proc(t: ^testing.T) {
	tmp_root, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_root)

	tmp_base := fmt.tprintf("%s/bbl_test_state_roundtrip", tmp_root)
	defer os.remove_all(tmp_base)

	rom_path := fmt.tprintf("%s/roundtrip_game.gbc", tmp_root)

	rom := make_dir_test_rom()
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	testing.expect(t, core.emulator_load_rom(emu, rom))

	ok := app.state_save_with_dir(emu, rom_path, 1, tmp_base)
	testing.expect(t, ok)

	state_path := app.state_path_for_rom_with_dir(rom_path, 1, tmp_base)
	testing.expect(t, os.exists(state_path))

	loaded := new(core.Emulator)
	defer free(loaded)
	defer core.bus_destroy(&loaded.bus)
	testing.expect(t, core.emulator_load_rom(loaded, rom))
	load_err, load_ok := app.state_load_with_dir(loaded, rom_path, 1, tmp_base)
	testing.expect(t, load_ok)
	testing.expect(t, load_err == .None)
}
