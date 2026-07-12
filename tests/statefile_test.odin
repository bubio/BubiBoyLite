package tests

import "core:fmt"
import "core:os"
import "core:testing"
import app "bbl:app"
import core "bbl:core"

// src/app/statefile.odin の単体テスト(T7-2)。パス導出(スロット込み)と
// state_save/state_load のアトミック書き込みラウンドトリップを検証する
// (saveram_test.odin と同じ流儀、bbl:app を直接importする既存の慣習に従う)。

@(test)
test_state_path_default_slot_replaces_extension :: proc(t: ^testing.T) {
	testing.expect(t, app.state_path_for_rom("game.gbc", 1) == "game.state")
	testing.expect(t, app.state_path_for_rom("/roms/dir.with.dots/game.gbc", 1) == "/roms/dir.with.dots/game.state")
}

@(test)
test_state_path_numbered_slots :: proc(t: ^testing.T) {
	testing.expect(t, app.state_path_for_rom("game.gbc", 2) == "game.state2")
	testing.expect(t, app.state_path_for_rom("game.gbc", 3) == "game.state3")
	testing.expect(t, app.state_path_for_rom("game.gbc", 4) == "game.state4")
}

// make_statefile_test_rom は type=0x03(MBC1+RAM+BATTERY)の合成ROMを作る(savestate_test.odinの
// make_savestate_test_rom と同じ流儀。ROMはCartridge.romが借用するだけなので、テスト用の
// 一時ディレクトリに書き出す必要はなく、そのままメモリ上のROMをロードすればよい)。
@(private = "file")
make_statefile_test_rom :: proc() -> []u8 {
	rom := make([]u8, 16 * 1024 * 2)
	rom[core.HEADER_TYPE_ADDR] = 0x03
	rom[core.HEADER_ROM_SIZE_ADDR] = 0x00
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02
	return rom
}

@(test)
test_state_save_and_load_round_trip :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	rom_path := fmt.tprintf("%s/bbl_statefile_test_roundtrip.gbc", tmp_dir)
	state_path := app.state_path_for_rom(rom_path, 1)
	bak_path := fmt.tprintf("%s.bak", state_path)
	defer os.remove(state_path)
	defer os.remove(bak_path)

	rom := make_statefile_test_rom()
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(emu, rom)
	testing.expect(t, ok)

	for _ in 0 ..< 3 {
		core.emulator_run_frame(emu)
	}
	pc_at_save := emu.cpu.pc

	testing.expect(t, app.state_save(emu, rom_path, 1))
	testing.expect(t, os.exists(state_path))

	for _ in 0 ..< 5 {
		core.emulator_run_frame(emu) // 保存後にさらに進める
	}

	load_err, load_ok := app.state_load(emu, rom_path, 1)
	testing.expect(t, load_ok)
	testing.expect(t, load_err == .None)
	testing.expect(t, emu.cpu.pc == pc_at_save, "復元後は保存時点のPCに戻るはず")
}

@(test)
test_state_load_missing_file_returns_not_ok :: proc(t: ^testing.T) {
	rom := make_statefile_test_rom()
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	_, ok := app.state_load(emu, "this_rom_should_not_have_a_state_bbl_test.gbc", 1)
	testing.expect(t, !ok)
}

@(test)
test_state_load_error_messages_are_non_empty_for_errors :: proc(t: ^testing.T) {
	testing.expect(t, app.state_load_error_message(.None) == "")
	testing.expect(t, len(app.state_load_error_message(.Bad_Magic)) > 0)
	testing.expect(t, len(app.state_load_error_message(.Version_Mismatch)) > 0)
	testing.expect(t, len(app.state_load_error_message(.Rom_Checksum_Mismatch)) > 0)
	testing.expect(t, len(app.state_load_error_message(.Too_Small)) > 0)
}
