package tests

import "core:testing"
import core "bbl:core"

// MBC2(mbc.odin)の単体テスト(T4-3)。落とし穴: RAM有効化とROMバンク選択は 0000-3FFF の
// 同じアドレス帯でアドレス bit8 により区別される(MBC1と違う)。RAMは512ニブル
// (上位4bitは読むと1)、A200-BFFFはA000-A1FFのエコー。

// make_mbc2_rom は type=0x06(MBC2+BATTERY)のヘッダを持つ合成ROMを作る。
@(private = "file")
make_mbc2_rom :: proc(rom_size_code: u8, bank_count: int) -> []u8 {
	size := 16 * 1024 * bank_count
	rom := make([]u8, size)
	rom[core.HEADER_TYPE_ADDR] = 0x06 // MBC2+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x00 // MBC2はコードに関わらず内蔵RAM
	for bank in 0 ..< bank_count {
		rom[bank * 0x4000] = u8(bank)
	}
	return rom
}

@(test)
test_mbc2_bit8_zero_selects_ram_enable :: proc(t: ^testing.T) {
	rom := make_mbc2_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	ok := core.bus_load_rom(&bus, rom)
	testing.expect(t, ok)

	// addr bit8=0(例: 0x0000)への書き込みはRAM有効化として扱われる。
	core.bus_write(&bus, 0x0000, 0x0A)
	core.bus_write(&bus, 0xA000, 0x05)
	testing.expect(t, core.bus_read(&bus, 0xA000) & 0x0F == 0x05, "bit8=0の書き込みでRAMが有効化される")
}

@(test)
test_mbc2_bit8_one_selects_rom_bank :: proc(t: ^testing.T) {
	rom := make_mbc2_rom(0x01, 4) // rom_size_code=0x01 -> 64KiB -> 4バンク
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	// addr bit8=1(例: 0x0100)への書き込みはROMバンク選択として扱われる。
	core.bus_write(&bus, 0x0100, 0x03)
	testing.expect(t, core.bus_read(&bus, 0x4000) == 3, "bit8=1の書き込みはROMバンク選択")
}

@(test)
test_mbc2_rom_bank_zero_reads_back_as_one :: proc(t: ^testing.T) {
	rom := make_mbc2_rom(0x01, 4) // rom_size_code=0x01 -> 64KiB -> 4バンク
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0100, 0x00) // バンク0指定 -> 1に読み替え
	testing.expect(t, core.bus_read(&bus, 0x4000) == 1)
}

@(test)
test_mbc2_ram_nibble_mask_and_upper_bits_read_as_one :: proc(t: ^testing.T) {
	rom := make_mbc2_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0xA000, 0xFF)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "上位4bitは常に1、下位4bitは書いた値")

	core.bus_write(&bus, 0xA001, 0x03)
	testing.expect(t, core.bus_read(&bus, 0xA001) == 0xF3, "下位4bitのみ保持、上位4bitは読むと1")
}

@(test)
test_mbc2_ram_disabled_reads_ff_and_ignores_writes :: proc(t: ^testing.T) {
	rom := make_mbc2_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "RAM無効時は0xFF")
	core.bus_write(&bus, 0xA000, 0x05)
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0xFF, "RAM無効時の書き込みは無視される")
}

@(test)
test_mbc2_ram_echoes_every_0x200_bytes :: proc(t: ^testing.T) {
	rom := make_mbc2_rom(0x00, 2)
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0xA000, 0x07) // 本体(A000-A1FF)、オフセット0

	// エコーは 0x200 バイト境界で繰り返す(オフセット mod 0x200 が同じアドレスが同じ値になる)。
	testing.expect(t, core.bus_read(&bus, 0xA200) & 0x0F == 0x07, "A200(オフセット0x200)はA000(オフセット0)のエコー")
	testing.expect(t, core.bus_read(&bus, 0xB1FF) & 0x0F != 0x07, "B1FF(オフセット0x11FF→0x1FF)はA000(オフセット0)とは別セル")

	core.bus_write(&bus, 0xA201, 0x0C) // オフセット0x201 -> エコーで0x001と同じセル
	testing.expect(t, core.bus_read(&bus, 0xA001) & 0x0F == 0x0C, "エコー領域への書き込みは対応する本体セルに反映される")
}
