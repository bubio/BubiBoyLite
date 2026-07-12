package tests

import "core:fmt"
import "core:os"
import "core:testing"
import app "bbl:app"
import core "bbl:core"

// RTC永続化(.rtc、T7-3)のテスト。core.mbc_export_rtc/mbc_import_rtc と app.rtc_save/rtc_load の
// 両方を検証する(mbc3_test.odin の make_mbc3_rtc_rom と同じ流儀で type=0x10 の合成ROMを使う)。

@(private = "file")
make_rtc_test_rom :: proc() -> []u8 {
	rom := make([]u8, 16 * 1024 * 2)
	rom[core.HEADER_TYPE_ADDR] = 0x10 // MBC3+TIMER+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = 0x00
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02
	return rom
}

@(test)
test_rtc_path_replaces_extension :: proc(t: ^testing.T) {
	testing.expect(t, app.rtc_path_for_rom("game.gbc") == "game.rtc")
	testing.expect(t, app.rtc_path_for_rom("/roms/dir.with.dots/game.gbc") == "/roms/dir.with.dots/game.rtc")
}

@(test)
test_rtc_file_write_load_round_trip :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	rtc_path := fmt.tprintf("%s/bbl_rtc_test_roundtrip.rtc", tmp_dir)
	bak_path := fmt.tprintf("%s.bak", rtc_path)
	defer os.remove(rtc_path)
	defer os.remove(bak_path)

	snapshot := app.Rtc_Snapshot {
		rtc            = [5]u8{10, 20, 5, 100, 0x00},
		latched_rtc    = [5]u8{9, 19, 4, 99, 0x00},
		latch_prepared = true,
		rtc_base_unix  = 1_700_000_000,
	}
	testing.expect(t, app.rtc_save(rtc_path, snapshot))

	loaded, ok := app.rtc_load(rtc_path)
	testing.expect(t, ok)
	testing.expect(t, loaded.rtc == snapshot.rtc)
	testing.expect(t, loaded.latched_rtc == snapshot.latched_rtc)
	testing.expect(t, loaded.latch_prepared == snapshot.latch_prepared)
	testing.expect(t, loaded.rtc_base_unix == snapshot.rtc_base_unix)
}

@(test)
test_rtc_load_missing_file_returns_not_ok :: proc(t: ^testing.T) {
	_, ok := app.rtc_load("this_rtc_should_not_exist_bbl_test.rtc")
	testing.expect(t, !ok)
}

@(test)
test_rtc_load_rejects_bad_magic :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	rtc_path := fmt.tprintf("%s/bbl_rtc_test_badmagic.rtc", tmp_dir)
	bak_path := fmt.tprintf("%s.bak", rtc_path)
	defer os.remove(rtc_path)
	defer os.remove(bak_path)

	bogus := make([]u8, app.RTC_FILE_SIZE)
	defer delete(bogus)
	testing.expect(t, app.save_ram_write_atomic(rtc_path, bogus)) // 全ゼロ = マジック不一致

	_, ok := app.rtc_load(rtc_path)
	testing.expect(t, !ok)
}

// test_rtc_export_import_round_trip は core.mbc_export_rtc/mbc_import_rtc がMBC3のRTC状態を
// 過不足なく往復させることを検証する。
@(test)
test_rtc_export_import_round_trip :: proc(t: ^testing.T) {
	rom := make_rtc_test_rom()
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(emu, rom)
	testing.expect(t, ok)

	base_time: i64 = 1_600_000_000
	core.emulator_set_wall_clock(emu, base_time)
	core.emulator_set_wall_clock(emu, base_time + 30) // ライブRTCのSを30に進める

	rtc, latched_rtc, latch_prepared, rtc_base_unix, export_ok := core.mbc_export_rtc(&emu.bus.cart)
	testing.expect(t, export_ok)
	testing.expect(t, rtc[0] == 30, "ライブRTCのSが30になっているはず")
	testing.expect(t, rtc_base_unix == base_time + 30)

	import_ok := core.mbc_import_rtc(&emu.bus.cart, rtc, latched_rtc, latch_prepared, rtc_base_unix)
	testing.expect(t, import_ok)
}

// test_rtc_advances_after_reload_with_later_wall_clock はT7-3のDoD本体:
// 保存→「1時間後」を注入してロード→RTCが1時間進んでいることを確認する。
@(test)
test_rtc_advances_after_reload_with_later_wall_clock :: proc(t: ^testing.T) {
	rom := make_rtc_test_rom()
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	save_time: i64 = 1_650_000_000
	core.emulator_set_wall_clock(emu, save_time) // 基準点を打つ(経過秒は加算されない)

	rtc, latched_rtc, latch_prepared, rtc_base_unix, _ := core.mbc_export_rtc(&emu.bus.cart)

	// 「プロセス終了→1時間後に再起動」を模擬: 新しいEmulatorへ書き出した値をインポートし、
	// 1時間後のUNIX時刻を供給する。
	reloaded := new(core.Emulator)
	defer free(reloaded)
	defer core.bus_destroy(&reloaded.bus)
	rom2 := make_rtc_test_rom()
	defer delete(rom2)
	_ = core.emulator_load_rom(reloaded, rom2)

	testing.expect(t, core.mbc_import_rtc(&reloaded.bus.cart, rtc, latched_rtc, latch_prepared, rtc_base_unix))
	one_hour_later := save_time + 3600
	core.emulator_set_wall_clock(reloaded, one_hour_later)

	// ラッチしてから読む(実機と同じ、latched_rtcを読む)。
	core.bus_write(&reloaded.bus, 0x0000, 0x0A)
	core.bus_write(&reloaded.bus, 0x6000, 0x00)
	core.bus_write(&reloaded.bus, 0x6000, 0x01)

	core.bus_write(&reloaded.bus, 0x4000, 0x0A) // H
	testing.expect(t, core.bus_read(&reloaded.bus, 0xA000) == 1, "1時間経過でHが1になっているはず")
}

// test_rtc_halted_does_not_advance_across_reload はDH bit6(停止)が立っている間は
// 経過時間を加算しないことを確認する。
@(test)
test_rtc_halted_does_not_advance_across_reload :: proc(t: ^testing.T) {
	rom := make_rtc_test_rom()
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(emu, rom)

	save_time: i64 = 1_650_000_000
	core.emulator_set_wall_clock(emu, save_time)

	core.bus_write(&emu.bus, 0x0000, 0x0A)
	core.bus_write(&emu.bus, 0x4000, 0x0C) // DH選択
	core.bus_write(&emu.bus, 0xA000, 0x40) // 停止ビット(bit6)を立てる

	rtc, latched_rtc, latch_prepared, rtc_base_unix, _ := core.mbc_export_rtc(&emu.bus.cart)
	testing.expect(t, rtc[4] & 0x40 != 0, "エクスポートしたRTCにも停止ビットが残っているはず")

	reloaded := new(core.Emulator)
	defer free(reloaded)
	defer core.bus_destroy(&reloaded.bus)
	rom2 := make_rtc_test_rom()
	defer delete(rom2)
	_ = core.emulator_load_rom(reloaded, rom2)

	testing.expect(t, core.mbc_import_rtc(&reloaded.bus.cart, rtc, latched_rtc, latch_prepared, rtc_base_unix))
	core.emulator_set_wall_clock(reloaded, save_time + 3600) // 1時間後を注入

	core.bus_write(&reloaded.bus, 0x0000, 0x0A)
	core.bus_write(&reloaded.bus, 0x6000, 0x00)
	core.bus_write(&reloaded.bus, 0x6000, 0x01) // ラッチ

	core.bus_write(&reloaded.bus, 0x4000, 0x0A) // H
	testing.expect(t, core.bus_read(&reloaded.bus, 0xA000) == 0, "停止中は経過時間を注入してもHは進まないはず")
}
