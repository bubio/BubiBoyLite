package tests

import "core:testing"
import core "bbl:core"

// MBC5(mbc.odin)の単体テスト(T4-5)。落とし穴: MBC1/2/3と違いバンク0をそのまま
// 4000-7FFFに指定できる(0→1の読み替えをしない)。

// make_mbc5_rom は type=0x1B(MBC5+RAM+BATTERY)のヘッダを持つ合成ROMを作る。
@(private = "file")
make_mbc5_rom :: proc(rom_size_code: u8, bank_count: int) -> []u8 {
	size := 16 * 1024 * bank_count
	rom := make([]u8, size)
	rom[core.HEADER_TYPE_ADDR] = 0x1B // MBC5+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x03 // 32KiB
	for bank in 0 ..< bank_count {
		rom[bank * 0x4000] = u8(bank)
	}
	return rom
}

@(test)
test_mbc5_powers_on_with_bank1_selected :: proc(t: ^testing.T) {
	rom := make_mbc5_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	ok := core.bus_load_rom(&bus, rom)
	testing.expect(t, ok)

	testing.expect(t, core.bus_read(&bus, 0x4000) == 1, "電源投入直後はバンク1")
}

@(test)
test_mbc5_can_select_bank_zero_without_substitution :: proc(t: ^testing.T) {
	rom := make_mbc5_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x2000, 0x00) // 明示的にバンク0を指定
	testing.expect(
		t,
		core.bus_read(&bus, 0x4000) == 0,
		"MBC5はバンク0をそのまま選択できる(MBC1のような1への読み替えをしない)",
	)
}

@(test)
test_mbc5_high_bit_selects_banks_above_255 :: proc(t: ^testing.T) {
	// rom_size_code=0x07 -> 4MiB -> 256バンク(0-255)。3000-3FFFのbit8で256以上を表す
	// テストとして、bank_count=257にして low8=0x00 と high1=1 の組み合わせでバンク256を選ぶ。
	rom := make_mbc5_rom(0x07, 257)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x2000, 0x00) // low8=0
	core.bus_write(&bus, 0x3000, 0x01) // high1=1 -> バンク = (1<<8)|0 = 256
	testing.expect(t, core.bus_read(&bus, 0x4000) == 0, "バンク256のマーカーバイトは0(257バンク中のインデックス256)")
}

@(test)
test_mbc5_low8_and_high1_combine :: proc(t: ^testing.T) {
	rom := make_mbc5_rom(0x07, 257)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x2000, 0x05) // low8=5
	core.bus_write(&bus, 0x3000, 0x00) // high1=0
	testing.expect(t, core.bus_read(&bus, 0x4000) == 5)

	core.bus_write(&bus, 0x2000, 0x05)
	core.bus_write(&bus, 0x3000, 0x01) // high1=1 -> バンク = 0x105 = 261
	testing.expect(t, core.bus_read(&bus, 0x4000) == 5, "バンク261(=257で剰余)のマーカー")
}

@(test)
test_mbc5_ram_enable_and_bank_select :: proc(t: ^testing.T) {
	rom := make_mbc5_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "RAM無効時は0xFF")

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0x4000, 0x00) // RAMバンク0
	core.bus_write(&bus, 0xA000, 0x11)
	core.bus_write(&bus, 0x4000, 0x02) // RAMバンク2
	core.bus_write(&bus, 0xA000, 0x22)

	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x22)
	core.bus_write(&bus, 0x4000, 0x00)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x11, "RAMバンクは独立して保持される")

	core.bus_write(&bus, 0x0000, 0x00) // RAM無効化
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF)
}
