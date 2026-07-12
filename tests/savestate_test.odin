package tests

import "core:testing"
import core "bbl:core"

// src/core/savestate.odin の単体テスト(T7-1/T7-2)。
// T7-5 では同じファイルにテストROMを使った決定性の統合テストを追加する。

// make_savestate_test_rom は type=0x03(MBC1+RAM+BATTERY)のヘッダを持つ合成ROMを作る
// (mbc3_test.odin の make_mbc3_rtc_rom と同じ流儀)。MBC1 を使うのは savestate 側の
// mbc union デコード経路(タグ1)を実際に運動させるため。
@(private = "file")
make_savestate_test_rom :: proc(rom_size_code: u8, bank_count: int) -> []u8 {
	size := 16 * 1024 * bank_count
	rom := make([]u8, size)
	rom[core.HEADER_TYPE_ADDR] = 0x03 // MBC1+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02 // 8KiB
	rom[0x014E] = 0x12
	rom[0x014F] = 0x34
	for bank in 0 ..< bank_count {
		rom[bank * 0x4000] = u8(bank)
	}
	return rom
}

// advance_emu_a_bit は CPU/PPU/APU/Timer に非ゼロの内部状態を作るため、ROM を軽く実行する
// (全フィールド0のままだと復元漏れがあっても検出できないため)。
@(private = "file")
advance_emu_a_bit :: proc(emu: ^core.Emulator, frames: int) {
	for _ in 0 ..< frames {
		core.emulator_run_frame(emu)
	}
}

@(test)
test_savestate_write_is_deterministic :: proc(t: ^testing.T) {
	rom := make_savestate_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(emu, rom)
	testing.expect(t, ok)

	advance_emu_a_bit(emu, 3)

	data1 := core.savestate_write(emu)
	defer delete(data1)
	data2 := core.savestate_write(emu)
	defer delete(data2)

	testing.expect(t, len(data1) == len(data2), "同じ状態からのwriteは同じ長さのはず")
	testing.expect(t, len(data1) == core.savestate_expected_size(emu), "実際の出力長はsavestate_expected_sizeと一致するはず")

	equal := true
	for i in 0 ..< len(data1) {
		if data1[i] != data2[i] {
			equal = false
			break
		}
	}
	testing.expect(t, equal, "write→write は決定的にバイト列が一致するはず")
}

@(test)
test_savestate_round_trip_restores_all_fields :: proc(t: ^testing.T) {
	rom := make_savestate_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(emu, rom)
	testing.expect(t, ok)

	advance_emu_a_bit(emu, 5)

	// MBC1のRAMに書き込み、外部RAMバイトも復元対象に含める。
	core.bus_write(&emu.bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&emu.bus, 0xA000, 0x77)

	saved := core.savestate_write(emu)
	defer delete(saved)

	advance_emu_a_bit(emu, 10) // 保存後にさらに状態を変える
	core.bus_write(&emu.bus, 0xA000, 0x99) // 保存後にRAMも書き換える

	load_err := core.savestate_read(emu, saved)
	testing.expect(t, load_err == .None)

	// write→readの直後にもう一度writeすると、最初のsavedと完全一致するはず(決定性の別角度からの確認)。
	resaved := core.savestate_write(emu)
	defer delete(resaved)
	testing.expect(t, len(saved) == len(resaved))
	equal := true
	for i in 0 ..< len(saved) {
		if saved[i] != resaved[i] {
			equal = false
			break
		}
	}
	testing.expect(t, equal, "復元後の再writeは保存時のバイト列と一致するはず")

	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 0x77, "外部RAMも復元されているはず")
}

@(test)
test_savestate_read_rejects_bad_magic :: proc(t: ^testing.T) {
	rom := make_savestate_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	saved := core.savestate_write(emu)
	defer delete(saved)

	corrupt := make([]u8, len(saved))
	defer delete(corrupt)
	copy(corrupt, saved)
	corrupt[0] = 'X' // マジックを壊す

	// 復元前の状態を記憶しておき、失敗後に無傷であることを確認する。
	pc_before := emu.cpu.pc
	err := core.savestate_read(emu, corrupt)
	testing.expect(t, err == .Bad_Magic)
	testing.expect(t, emu.cpu.pc == pc_before, "マジック不一致では現在の状態が変わらないはず")
}

@(test)
test_savestate_read_rejects_version_mismatch :: proc(t: ^testing.T) {
	rom := make_savestate_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	saved := core.savestate_write(emu)
	defer delete(saved)

	corrupt := make([]u8, len(saved))
	defer delete(corrupt)
	copy(corrupt, saved)
	corrupt[4] = 0xFF // バージョンフィールドの最下位バイトを壊す(=1ではなくなる)

	pc_before := emu.cpu.pc
	err := core.savestate_read(emu, corrupt)
	testing.expect(t, err == .Version_Mismatch)
	testing.expect(t, emu.cpu.pc == pc_before)
}

@(test)
test_savestate_read_rejects_rom_checksum_mismatch :: proc(t: ^testing.T) {
	rom := make_savestate_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	saved := core.savestate_write(emu)
	defer delete(saved)

	corrupt := make([]u8, len(saved))
	defer delete(corrupt)
	copy(corrupt, saved)
	corrupt[8] ~= 0xFF // ROMチェックサムの1バイト目を反転

	pc_before := emu.cpu.pc
	err := core.savestate_read(emu, corrupt)
	testing.expect(t, err == .Rom_Checksum_Mismatch)
	testing.expect(t, emu.cpu.pc == pc_before)
}

@(test)
test_savestate_read_rejects_too_small :: proc(t: ^testing.T) {
	rom := make_savestate_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	saved := core.savestate_write(emu)
	defer delete(saved)

	truncated := saved[:len(saved) - 100]

	pc_before := emu.cpu.pc
	err := core.savestate_read(emu, truncated)
	testing.expect(t, err == .Too_Small)
	testing.expect(t, emu.cpu.pc == pc_before)

	// ヘッダすら読めない極端なケースもToo_Smallになるはず。
	tiny := saved[:4]
	err2 := core.savestate_read(emu, tiny)
	testing.expect(t, err2 == .Too_Small)
}
