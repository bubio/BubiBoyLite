package tests

import "core:testing"
import core "bbl:core"

// カートリッジヘッダ解析(cartridge.odin)の単体テスト(T4-1)。
// 合成ヘッダ(実ROMではなく最小限のバイト列)で各 MBC 種別・サイズ判定・未対応種別の
// エラーを検証する。testing.md「単体テストの方針」: ヘッダ解析はテスト ROM がカバーしない
// 境界値なのでここで固定する。

// make_header は指定サイズの合成 ROM を作り、ヘッダフィールドをセットする。
// title はテストごとに省略可能(空なら 0x0134-0x0143 は 0 埋めのまま)。
@(private = "file")
make_header :: proc(
	size: int,
	type_code: u8,
	rom_size_code: u8,
	ram_size_code: u8,
	cgb_code: u8 = 0x00,
	title: string = "",
) -> []u8 {
	rom := make([]u8, size)
	for b, i in title {
		if i >= core.HEADER_TITLE_LEN {
			break
		}
		rom[core.HEADER_TITLE_START + i] = u8(b)
	}
	rom[core.HEADER_CGB_FLAG_ADDR] = cgb_code
	rom[core.HEADER_TYPE_ADDR] = type_code
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = ram_size_code
	return rom
}

@(test)
test_cartridge_rom_only_32kib :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x00, 0x00, 0x00)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Rom_Only)
	testing.expect(t, info.rom_banks == 2, "32KiB = 2 バンク")
	testing.expect(t, info.ram_size == 0)
	testing.expect(t, !info.has_battery)
	testing.expect(t, !info.has_rtc)
}

@(test)
test_cartridge_mbc1_ram_battery :: proc(t: ^testing.T) {
	// 0x03 = MBC1+RAM+BATTERY、ROMサイズコード0x04=512KiB(32バンク)、RAMコード0x02=8KiB
	rom := make_header(512 * 1024, 0x03, 0x04, 0x02)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Mbc1)
	testing.expect(t, info.rom_banks == 32)
	testing.expect(t, info.ram_size == 8 * 1024)
	testing.expect(t, info.has_battery)
	testing.expect(t, !info.has_rtc)
}

@(test)
test_cartridge_mbc1_no_ram_no_battery :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x01, 0x00, 0x00)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Mbc1)
	testing.expect(t, info.ram_size == 0)
	testing.expect(t, !info.has_battery)
}

@(test)
test_cartridge_mbc2_internal_ram_ignores_header_code :: proc(t: ^testing.T) {
	// MBC2 は 0x0149 のコードが0でも常に内蔵512バイトRAMを持つ(落とし穴、T4-1)。
	rom := make_header(0x8000, 0x06, 0x00, 0x00)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Mbc2)
	testing.expect(t, info.ram_size == 512, "MBC2は0x0149に頼らず種別で内蔵RAMサイズを決める")
	testing.expect(t, info.has_battery)
}

@(test)
test_cartridge_mbc3_timer_battery_no_ram :: proc(t: ^testing.T) {
	// 0x0F = MBC3+TIMER+BATTERY。RAMコードが非ゼロでもRAM無し種別なのでram_size=0。
	rom := make_header(0x8000, 0x0F, 0x00, 0x03)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Mbc3)
	testing.expect(t, info.has_rtc)
	testing.expect(t, info.has_battery)
	testing.expect(t, info.ram_size == 0, "0x0FはRAM無し種別")
}

@(test)
test_cartridge_mbc3_timer_ram_battery :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x10, 0x00, 0x03)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Mbc3)
	testing.expect(t, info.has_rtc)
	testing.expect(t, info.has_battery)
	testing.expect(t, info.ram_size == 32 * 1024)
}

@(test)
test_cartridge_mbc5_rumble_ram_battery :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x1E, 0x00, 0x03)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.mbc_kind == .Mbc5)
	testing.expect(t, info.has_battery)
	testing.expect(t, info.ram_size == 32 * 1024)
}

@(test)
test_cartridge_rom_size_code_to_banks :: proc(t: ^testing.T) {
	// 32KiB << code。code=5 -> 1MiB -> 64バンク。
	rom := make_header(1024 * 1024, 0x00, 0x05, 0x00)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.rom_banks == 64)
}

@(test)
test_cartridge_unsupported_type_reports_error_and_code :: proc(t: ^testing.T) {
	// 0x20 = MBC6(スコープ外)
	rom := make_header(0x8000, 0x20, 0x00, 0x00)
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .Unsupported_Type)
	testing.expect(t, info.type_code == 0x20, "エラー時もtype_codeはapp側のメッセージ表示用に残す")
}

@(test)
test_cartridge_unsupported_huc1_type :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0xFF, 0x00, 0x00) // HuC1+RAM+BATTERY
	defer delete(rom)

	_, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .Unsupported_Type)
}

@(test)
test_cartridge_unsupported_rom_size_code :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x00, 0x09, 0x00) // 0x09は既知の範囲外
	defer delete(rom)

	_, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .Unsupported_Rom_Size)
}

@(test)
test_cartridge_unsupported_ram_size_code :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x02, 0x00, 0x01) // 0x01は未使用として予約
	defer delete(rom)

	_, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .Unsupported_Ram_Size)
}

@(test)
test_cartridge_rom_smaller_than_declared_header_size :: proc(t: ^testing.T) {
	// ヘッダは64KiB(code=0x01)を申告するが実データは32KiBしかない。
	rom := make_header(0x8000, 0x00, 0x01, 0x00)
	defer delete(rom)

	_, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .Rom_Smaller_Than_Header)
}

@(test)
test_cartridge_header_too_small :: proc(t: ^testing.T) {
	rom := make([]u8, 0x100) // 0x0150未満
	defer delete(rom)

	_, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .Header_Too_Small)
}

@(test)
test_cartridge_title_stops_at_first_zero_byte :: proc(t: ^testing.T) {
	rom := make_header(0x8000, 0x00, 0x00, 0x00, 0x00, "POKEMON")
	defer delete(rom)

	info, err := core.cartridge_parse_header(rom)
	testing.expect(t, err == .None)
	testing.expect(t, info.title == "POKEMON")
}

@(test)
test_cartridge_cgb_flag_classification :: proc(t: ^testing.T) {
	rom_dmg := make_header(0x8000, 0x00, 0x00, 0x00, 0x00)
	defer delete(rom_dmg)
	info_dmg, _ := core.cartridge_parse_header(rom_dmg)
	testing.expect(t, info_dmg.cgb_flag == .Dmg_Only)

	rom_enhanced := make_header(0x8000, 0x00, 0x00, 0x00, 0x80)
	defer delete(rom_enhanced)
	info_enhanced, _ := core.cartridge_parse_header(rom_enhanced)
	testing.expect(t, info_enhanced.cgb_flag == .Cgb_Enhanced)

	rom_only := make_header(0x8000, 0x00, 0x00, 0x00, 0xC0)
	defer delete(rom_only)
	info_only, _ := core.cartridge_parse_header(rom_only)
	testing.expect(t, info_only.cgb_flag == .Cgb_Only)
}
