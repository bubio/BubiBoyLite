package tests

import "core:testing"
import core "bbl:core"

// Gb_Mode 判定(T6-1)の単体テスト。emulator_load_rom がヘッダ 0x0143 のみを見て
// (拡張子ではなく)モードを判定し、cpu_reset に正しいモードを渡すことを検証する。
// DoD: .gbc ヘッダ(0x80/0xC0)で A=0x11、DMG ヘッダ(それ以外)で A=0x01。

@(private = "file")
make_minimal_rom :: proc(cgb_flag: u8, mbc_type: u8 = 0x00) -> []u8 {
	rom := make([]u8, 0x8000)
	rom[core.HEADER_CGB_FLAG_ADDR] = cgb_flag
	rom[core.HEADER_TYPE_ADDR] = mbc_type // 0x00 = ROM only
	rom[core.HEADER_ROM_SIZE_ADDR] = 0x00 // 32KiB
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x00 // RAM無し
	return rom
}

@(test)
test_emulator_load_rom_cgb_enhanced_flag_selects_cgb_mode :: proc(t: ^testing.T) {
	rom := make_minimal_rom(0x80)
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(&emu, rom)
	testing.expect(t, ok, "ROM ロードに失敗した")
	testing.expect(t, emu.bus.mode == .Cgb, "0x80(Cgb_Enhanced)は Cgb モードで起動するはず")
	testing.expectf(t, emu.cpu.a == 0x11, "CGB 起動時は A=0x11 のはず, got=0x%02X", emu.cpu.a)
}

@(test)
test_emulator_load_rom_cgb_only_flag_selects_cgb_mode :: proc(t: ^testing.T) {
	rom := make_minimal_rom(0xC0)
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(&emu, rom)
	testing.expect(t, ok, "ROM ロードに失敗した")
	testing.expect(t, emu.bus.mode == .Cgb, "0xC0(Cgb_Only)も Cgb モードで起動するはず")
	testing.expectf(t, emu.cpu.a == 0x11, "CGB 起動時は A=0x11 のはず, got=0x%02X", emu.cpu.a)
}

@(test)
test_emulator_load_rom_dmg_flag_selects_dmg_mode :: proc(t: ^testing.T) {
	rom := make_minimal_rom(0x00)
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(&emu, rom)
	testing.expect(t, ok, "ROM ロードに失敗した")
	testing.expect(t, emu.bus.mode == .Dmg, "CGBフラグ無しは Dmg モードで起動するはず")
	testing.expectf(t, emu.cpu.a == 0x01, "DMG 起動時は A=0x01 のはず, got=0x%02X", emu.cpu.a)
}
