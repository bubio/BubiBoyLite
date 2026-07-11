package tests

import "core:testing"
import core "bbl:core"

// MBC3(+RTC)(mbc.odin)の単体テスト(T4-4)。DoD: ラッチ手順(0→1のみ有効)、
// RTCレジスタ選択の読み書き、emulator_set_wall_clock による時刻供給での進行を検証する。

// make_mbc3_rtc_rom は type=0x10(MBC3+TIMER+RAM+BATTERY)のヘッダを持つ合成ROMを作る。
@(private = "file")
make_mbc3_rtc_rom :: proc(rom_size_code: u8, bank_count: int) -> []u8 {
	size := 16 * 1024 * bank_count
	rom := make([]u8, size)
	rom[core.HEADER_TYPE_ADDR] = 0x10 // MBC3+TIMER+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02 // 8KiB
	for bank in 0 ..< bank_count {
		rom[bank * 0x4000] = u8(bank)
	}
	return rom
}

@(test)
test_mbc3_rom_bank_zero_reads_back_as_one :: proc(t: ^testing.T) {
	rom := make_mbc3_rtc_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	ok := core.bus_load_rom(&bus, rom)
	testing.expect(t, ok)

	core.bus_write(&bus, 0x2000, 0x00) // バンク0指定 -> 1に読み替え(7bit、MBC1と同じ落とし穴)
	testing.expect(t, core.bus_read(&bus, 0x4000) == 1)
}

@(test)
test_mbc3_ram_bank_select_and_readback :: proc(t: ^testing.T) {
	rom := make_mbc3_rtc_rom(0x00, 2)
	defer delete(rom)
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x03 // 32KiB(4バンク)。複数バンクの独立性を検査するため

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0x4000, 0x00) // RAMバンク0選択
	core.bus_write(&bus, 0xA000, 0x11)
	core.bus_write(&bus, 0x4000, 0x01) // RAMバンク1選択
	core.bus_write(&bus, 0xA000, 0x22)

	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x22)
	core.bus_write(&bus, 0x4000, 0x00)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x11, "RAMバンクは独立して保持される")
}

@(test)
test_mbc3_latch_requires_zero_then_one_transition :: proc(t: ^testing.T) {
	rom := make_mbc3_rtc_rom(0x00, 2)
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(&emu, rom)
	testing.expect(t, ok)

	core.emulator_set_wall_clock(&emu, 1_000) // 初回供給は基準点を打つだけ
	core.emulator_set_wall_clock(&emu, 1_005) // 5秒経過 -> ライブRTCのSは5になる

	core.bus_write(&emu.bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&emu.bus, 0x4000, 0x08) // RTC S レジスタ選択

	// 0x01をいきなり書いてもラッチされない(0->1の遷移が無いため)。
	core.bus_write(&emu.bus, 0x6000, 0x01)
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 0, "prepared無しの0x01書き込みではラッチされない")

	// 0x00 -> 0x01 の正しい手順でラッチする。
	core.bus_write(&emu.bus, 0x6000, 0x00)
	core.bus_write(&emu.bus, 0x6000, 0x01)
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 5, "0->1のラッチでライブRTCがスナップショットされる")
}

@(test)
test_mbc3_rtc_register_select_read_write_roundtrip :: proc(t: ^testing.T) {
	rom := make_mbc3_rtc_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化

	// S/M/H/DL/DHへの直接書き込み(初期時刻設定)。書いた直後はラッチしないと読めない。
	core.bus_write(&bus, 0x4000, 0x08) // S
	core.bus_write(&bus, 0xA000, 30)
	core.bus_write(&bus, 0x4000, 0x09) // M
	core.bus_write(&bus, 0xA000, 45)
	core.bus_write(&bus, 0x4000, 0x0A) // H
	core.bus_write(&bus, 0xA000, 12)

	core.bus_write(&bus, 0x6000, 0x00)
	core.bus_write(&bus, 0x6000, 0x01) // ラッチ

	core.bus_write(&bus, 0x4000, 0x08)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 30, "S")
	core.bus_write(&bus, 0x4000, 0x09)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 45, "M")
	core.bus_write(&bus, 0x4000, 0x0A)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 12, "H")
}

@(test)
test_mbc3_wall_clock_advances_rtc_across_hour_boundary :: proc(t: ^testing.T) {
	rom := make_mbc3_rtc_rom(0x00, 2)
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(&emu, rom)

	base_time: i64 = 1_700_000_000
	core.emulator_set_wall_clock(&emu, base_time) // 基準点
	// 3661秒 = 1時間1分1秒 経過させる。
	core.emulator_set_wall_clock(&emu, base_time + 3661)

	core.bus_write(&emu.bus, 0x0000, 0x0A)
	core.bus_write(&emu.bus, 0x6000, 0x00)
	core.bus_write(&emu.bus, 0x6000, 0x01) // ラッチ

	core.bus_write(&emu.bus, 0x4000, 0x08)
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 1, "S=1")
	core.bus_write(&emu.bus, 0x4000, 0x09)
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 1, "M=1")
	core.bus_write(&emu.bus, 0x4000, 0x0A)
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 1, "H=1")
}

@(test)
test_mbc3_halt_bit_stops_rtc_advancement :: proc(t: ^testing.T) {
	rom := make_mbc3_rtc_rom(0x00, 2)
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(&emu, rom)

	base_time: i64 = 2_000_000
	core.emulator_set_wall_clock(&emu, base_time)

	core.bus_write(&emu.bus, 0x0000, 0x0A)
	core.bus_write(&emu.bus, 0x4000, 0x0C) // DH選択
	core.bus_write(&emu.bus, 0xA000, 0x40) // 停止ビット(bit6)を立てる

	core.emulator_set_wall_clock(&emu, base_time + 100) // 100秒経過させようとする

	core.bus_write(&emu.bus, 0x6000, 0x00)
	core.bus_write(&emu.bus, 0x6000, 0x01) // ラッチ

	core.bus_write(&emu.bus, 0x4000, 0x08) // S
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 0, "停止中は秒が進まない")
}
