package tests

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:testing"
import core "bbl:core"

// src/core/savestate.odin の単体テスト(T7-1/T7-2)。
// T7-5(フェーズ7のマイルストーン)はテストROMを使った決定性の統合テスト
// (test_savestate_deterministic_replay_after_restore、ファイル末尾)を同じファイルに追加する。

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

// --- T7-5: フェーズ7のマイルストーン(テストROMを使った決定性の統合テスト) ---
//
// testing.md「単体テストの方針」どおり ROM 未取得時はスキップする(fetch_test_roms.sh
// 未実行のローカル環境を壊さない)。
//
// ROM/フレーム数の選び方(advisor助言): 「save した瞬間の画面が既に静止している」テストは
// 保存漏れフィールドがあっても両方のハッシュが偶然一致してしまい、何も検証しないに等しい。
// Blargg cpu_instrs個別テスト 01-special.gb はタイトル画面が数フレームかけて描画される
// (frame0-3:無地→frame4-8:テキスト描画中に複数回変化→frame8以降で一旦静止)ことを
// 事前に確認済み(scratchpadでの調査、検証ログ参照)。そこで N=2(まだ無地)で保存し、
// M=6(frame2→8、画面が実際に動いている区間)を「保存直後に一度実行して基準ハッシュを記録」
// →「同じ保存データから復元してもう一度同じM フレームを実行」という手順で完全一致を見る。
@(private = "file")
SAVESTATE_MILESTONE_ROM_PATH :: "tests/roms/blargg/cpu_instrs/individual/01-special.gb"

@(private = "file")
SAVESTATE_MILESTONE_N_FRAMES :: 2 // 保存前に実行するフレーム数(まだ画面が静止していない時点)
@(private = "file")
SAVESTATE_MILESTONE_M_FRAMES :: 6 // 保存後、ハッシュ記録までに実行するフレーム数(画面が変化する区間)

@(private = "file")
framebuffer_hash :: proc(emu: ^core.Emulator) -> u64 {
	fb := mem.byte_slice(&emu.bus.ppu.framebuffer, size_of(emu.bus.ppu.framebuffer))
	return hash.fnv64a(fb)
}

@(test)
test_savestate_deterministic_replay_after_restore :: proc(t: ^testing.T) {
	if !os.exists(SAVESTATE_MILESTONE_ROM_PATH) {
		fmt.printfln(
			"savestate_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			SAVESTATE_MILESTONE_ROM_PATH,
		)
		return
	}

	data, err := os.read_entire_file(SAVESTATE_MILESTONE_ROM_PATH, context.allocator)
	testing.expectf(t, err == nil, "savestate_test: ROM を読み込めません: %v", err)
	if err != nil {
		return
	}
	defer delete(data)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	defer delete(emu.bus.serial_log) // Blarggが結果をシリアルへ書くため確保される(rom_runner.odinと同じ後始末)
	loaded := core.emulator_load_rom(emu, data)
	testing.expect(t, loaded)
	if !loaded {
		return
	}

	for _ in 0 ..< SAVESTATE_MILESTONE_N_FRAMES {
		core.emulator_run_frame(emu)
	}
	hash_at_save := framebuffer_hash(emu)

	saved := core.savestate_write(emu)
	defer delete(saved)

	// 1回目: 保存直後からMフレーム実行して基準ハッシュを記録する。
	for _ in 0 ..< SAVESTATE_MILESTONE_M_FRAMES {
		core.emulator_run_frame(emu)
	}
	hash_after_first_replay := framebuffer_hash(emu)

	// 画面が実際に動いている区間を選んだことの確認(落とし穴チェック: ここが等しいままだと
	// 「常に同じハッシュになるだけの無意味なテスト」になってしまう)。
	testing.expect(
		t,
		hash_after_first_replay != hash_at_save,
		"savestate_test: 選んだフレーム区間で画面が変化していない(テストが無意味になっている)",
	)

	// 2回目: 同じ保存データから復元し、同じMフレームをもう一度実行する。
	load_err := core.savestate_read(emu, saved)
	testing.expect(t, load_err == .None)

	for _ in 0 ..< SAVESTATE_MILESTONE_M_FRAMES {
		core.emulator_run_frame(emu)
	}
	hash_after_second_replay := framebuffer_hash(emu)

	testing.expectf(
		t,
		hash_after_first_replay == hash_after_second_replay,
		"savestate_test: 復元後の再生がハッシュ不一致(保存漏れフィールドの疑い): got=0x%016X expected=0x%016X",
		hash_after_second_replay,
		hash_after_first_replay,
	)
}

// test_savestate_deterministic_replay_after_restore_cgb は上と同じ手順を CGB モードの
// ROM(cgb-acid2)で行う(advisor助言: 上のテストは 01-special.gb がDMGモードで起動するため
// パレットRAM・VRAMバンク1・WRAMバンク2-7・BCPS/OCPSといったCGB専用フィールドを一度も
// 動かさない。それらのフィールドで書き込み/読み出しの順序がずれていても、常にデフォルト値
// (ゼロ)のままなら両方のwriteが偶然一致してこのテストは検出できない。CGB ROMで同じ手順を
// 踏むことで、その死角を塞ぐ)。
// フレーム区間は事前にscratchpadでフレーム毎のframebufferハッシュを調査して選定
// (frame0-12:無地→frame13で変化開始→frame14で確定・以後静止。落とし穴チェックのため
// N=10(まだ無地)で保存しM=6(frame10→16、frame13の変化を跨ぐ)を実行する)。
@(private = "file")
CGB_MILESTONE_ROM_PATH :: "tests/roms/acid2/cgb-acid2.gbc"

@(private = "file")
CGB_MILESTONE_N_FRAMES :: 10
@(private = "file")
CGB_MILESTONE_M_FRAMES :: 6

@(test)
test_savestate_deterministic_replay_after_restore_cgb :: proc(t: ^testing.T) {
	if !os.exists(CGB_MILESTONE_ROM_PATH) {
		fmt.printfln(
			"savestate_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			CGB_MILESTONE_ROM_PATH,
		)
		return
	}

	data, err := os.read_entire_file(CGB_MILESTONE_ROM_PATH, context.allocator)
	testing.expectf(t, err == nil, "savestate_test: ROM を読み込めません: %v", err)
	if err != nil {
		return
	}
	defer delete(data)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	loaded := core.emulator_load_rom(emu, data)
	testing.expect(t, loaded)
	if !loaded {
		return
	}
	testing.expectf(t, emu.bus.mode == .Cgb, "savestate_test: cgb-acid2.gbc は Cgb モードで起動するはず")

	for _ in 0 ..< CGB_MILESTONE_N_FRAMES {
		core.emulator_run_frame(emu)
	}
	hash_at_save := framebuffer_hash(emu)

	saved := core.savestate_write(emu)
	defer delete(saved)

	for _ in 0 ..< CGB_MILESTONE_M_FRAMES {
		core.emulator_run_frame(emu)
	}
	hash_after_first_replay := framebuffer_hash(emu)

	testing.expect(
		t,
		hash_after_first_replay != hash_at_save,
		"savestate_test: 選んだフレーム区間で画面が変化していない(CGBテストが無意味になっている)",
	)

	load_err := core.savestate_read(emu, saved)
	testing.expect(t, load_err == .None)

	for _ in 0 ..< CGB_MILESTONE_M_FRAMES {
		core.emulator_run_frame(emu)
	}
	hash_after_second_replay := framebuffer_hash(emu)

	testing.expectf(
		t,
		hash_after_first_replay == hash_after_second_replay,
		"savestate_test: CGB復元後の再生がハッシュ不一致(パレットRAM/VRAMバンク1/WRAMバンク等の保存漏れの疑い): got=0x%016X expected=0x%016X",
		hash_after_second_replay,
		hash_after_first_replay,
	)
}
