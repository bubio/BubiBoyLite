package tests

import "core:testing"
import core "bbl:core"

// MBC1(mbc.odin)の単体テスト(T4-2)。cpu_instrs.gb 統合版(blargg_test.odin)とは別に、
// テスト ROM がカバーしない境界値(バンク0の1への読み替え、モード切替、RAM有効化)を固定する
// (testing.md「単体テストの方針」)。

// make_mbc1_rom は type=0x01(MBC1、RAM/バッテリー無し)のヘッダを持つ合成ROMを作る。
// bank_index にマーカーバイトを1つ置き、そのバンクが選択されたかを検出できるようにする。
@(private = "file")
make_mbc1_rom :: proc(rom_size_code: u8, bank_count: int) -> []u8 {
	size := 16 * 1024 * bank_count
	rom := make([]u8, size)
	rom[core.HEADER_TYPE_ADDR] = 0x01 // MBC1
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x00
	// 各バンクの先頭バイトに「このバンクの番号」を書いておく(読み出し確認用マーカー)。
	for bank in 0 ..< bank_count {
		rom[bank * 0x4000] = u8(bank)
	}
	return rom
}

@(test)
test_mbc1_bank0_write_reads_back_as_bank1 :: proc(t: ^testing.T) {
	// rom_size_code=0x04 -> 512KiB -> 32バンク。落とし穴: 5bitレジスタが0なら1に読み替える
	// 判定はマスク後に行う(0x20を書いても low5=0->1になる)。
	rom := make_mbc1_rom(0x04, 32)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	ok := core.bus_load_rom(&bus, rom)
	testing.expect(t, ok)

	core.bus_write(&bus, 0x2000, 0x00) // バンク0を指定 -> 1に読み替え
	testing.expect(t, core.bus_read(&bus, 0x4000) == 1, "0を書いても実際に選択されるのはバンク1")
}

@(test)
test_mbc1_bank0_region_always_reads_bank0_in_rom_mode :: proc(t: ^testing.T) {
	rom := make_mbc1_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x2000, 0x01)
	testing.expect(t, core.bus_read(&bus, 0x0000) == 0, "0000-3FFFは(ROMモードでは)常にバンク0")
	testing.expect(t, core.bus_read(&bus, 0x4000) == 1, "4000-7FFFは選択したバンク")
}

@(test)
test_mbc1_upper_bank_combines_high2_and_low5 :: proc(t: ^testing.T) {
	// 128バンク(2MiB、rom_size_code=0x06)。high2=1, low5=1 -> バンク 0x21=33。
	rom := make_mbc1_rom(0x06, 128)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x2000, 0x01) // low5=1
	core.bus_write(&bus, 0x4000, 0x01) // high2=1
	testing.expect(t, core.bus_read(&bus, 0x4000) == 33, "high2<<5 | low5 = 0x21 = 33")
}

@(test)
test_mbc1_bank_0x20_reads_back_as_0x21 :: proc(t: ^testing.T) {
	// 落とし穴の核心: 0x20/0x40/0x60を書いても low5部分は5bitマスク後0になり1に読み替えられる
	// ため、実際に選ばれるのは 0x21/0x41/0x61(Mooneye mbc1/rom_512kb 系が検査する挙動)。
	rom := make_mbc1_rom(0x06, 128)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x4000, 0x01) // high2=1 (0x20 相当の上位ビット)
	core.bus_write(&bus, 0x2000, 0x20) // low5 = 0x20 & 0x1F = 0 -> 1 に読み替え
	testing.expect(t, core.bus_read(&bus, 0x4000) == 0x21, "0x20書き込み時も実際は0x21が選ばれる")
}

@(test)
test_mbc1_mode_switch_affects_0000_3fff_region :: proc(t: ^testing.T) {
	rom := make_mbc1_rom(0x06, 128)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x4000, 0x01) // high2=1
	core.bus_write(&bus, 0x6000, 0x00) // モード=ROM(既定)
	testing.expect(t, core.bus_read(&bus, 0x0000) == 0, "ROMモードでは0000-3FFFは常にバンク0")

	core.bus_write(&bus, 0x6000, 0x01) // モード=RAM(0000-3FFFにもhigh2が効く)
	testing.expect(t, core.bus_read(&bus, 0x0000) == 32, "RAMモードでは0000-3FFFがhigh2<<5になる")
}

@(test)
test_mbc1_ram_enable_and_disable :: proc(t: ^testing.T) {
	rom := make_mbc1_rom(0x04, 32)
	defer delete(rom)
	rom[core.HEADER_TYPE_ADDR] = 0x03 // MBC1+RAM+BATTERY
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02 // 8KiB

	bus: core.Bus
	defer core.bus_destroy(&bus)
	ok := core.bus_load_rom(&bus, rom)
	testing.expect(t, ok)

	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "RAM無効時は0xFFを読む")
	core.bus_write(&bus, 0xA000, 0x42)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "RAM無効時の書き込みは無視される")

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化(下位4bit=0x0A)
	core.bus_write(&bus, 0xA000, 0x42)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x42, "RAM有効時は書き込み・読み出しできる")

	core.bus_write(&bus, 0x0000, 0x00) // RAM無効化
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "RAM無効化後は再び0xFF")
}

@(test)
test_mbc1_ram_bank_switches_in_ram_mode :: proc(t: ^testing.T) {
	// 32KiB RAM(4バンク)。RAMモードでは high2 が RAM バンクにもなる。
	rom := make_mbc1_rom(0x00, 2)
	defer delete(rom)
	rom[core.HEADER_TYPE_ADDR] = 0x03
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x03 // 32KiB

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0x6000, 0x01) // モード=RAM

	core.bus_write(&bus, 0x4000, 0x00) // RAMバンク0
	core.bus_write(&bus, 0xA000, 0x11)

	core.bus_write(&bus, 0x4000, 0x01) // RAMバンク1
	core.bus_write(&bus, 0xA000, 0x22)

	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x22, "バンク1に書いた値がそのまま読める")

	core.bus_write(&bus, 0x4000, 0x00) // バンク0へ戻す
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x11, "バンク0の値は独立して保持されている")
}
