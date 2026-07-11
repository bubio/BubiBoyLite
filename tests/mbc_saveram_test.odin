package tests

import "core:testing"
import core "bbl:core"

// mbc_export_ram/mbc_import_ram(mbc.odin)の単体テスト(T4-6)。
// バッテリーバックアップRAMのラウンドトリップ、バッテリー無しでのok=false、
// サイズ不一致時のインポート拒否、MBC2(内蔵RAM)・MBC3(RTCは対象外)を検証する。

@(private = "file")
make_mbc1_battery_rom :: proc() -> []u8 {
	rom := make([]u8, 0x8000)
	rom[core.HEADER_TYPE_ADDR] = 0x03 // MBC1+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = 0x00
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02 // 8KiB
	return rom
}

@(test)
test_mbc_export_import_ram_roundtrip_mbc1 :: proc(t: ^testing.T) {
	rom := make_mbc1_battery_rom()
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0xA000, 0x11)
	core.bus_write(&bus, 0xA001, 0x22)

	data, ok := core.mbc_export_ram(&bus.cart)
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, len(data) == 8 * 1024)
	testing.expect(t, data[0] == 0x11 && data[1] == 0x22)

	// 別のBusへインポートしてラウンドトリップを確認する。
	bus2: core.Bus
	defer core.bus_destroy(&bus2)
	_ = core.bus_load_rom(&bus2, rom)
	imported := core.mbc_import_ram(&bus2.cart, data)
	testing.expect(t, imported)

	core.bus_write(&bus2, 0x0000, 0x0A)
	testing.expect(t, core.bus_read(&bus2, 0xA000) == 0x11)
	testing.expect(t, core.bus_read(&bus2, 0xA001) == 0x22)
}

@(test)
test_mbc_export_ram_without_battery_fails :: proc(t: ^testing.T) {
	rom := make([]u8, 0x8000)
	rom[core.HEADER_TYPE_ADDR] = 0x02 // MBC1+RAM(バッテリー無し)
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	_, ok := core.mbc_export_ram(&bus.cart)
	testing.expect(t, !ok, "バッテリー無しカートリッジはエクスポートできない")
}

@(test)
test_mbc_import_ram_size_mismatch_rejected :: proc(t: ^testing.T) {
	rom := make_mbc1_battery_rom()
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)
	core.bus_write(&bus, 0x0000, 0x0A)
	core.bus_write(&bus, 0xA000, 0x99)

	wrong_size_data := make([]u8, 100)
	defer delete(wrong_size_data)
	ok := core.mbc_import_ram(&bus.cart, wrong_size_data)
	testing.expect(t, !ok, "サイズ不一致はインポートを拒否する")
	testing.expect(t, core.bus_read(&bus, 0xA000) == 0x99, "拒否時は既存RAMが変化しない")
}

@(test)
test_mbc2_export_import_ram_roundtrip :: proc(t: ^testing.T) {
	rom := make([]u8, 0x8000)
	rom[core.HEADER_TYPE_ADDR] = 0x06 // MBC2+BATTERY
	defer delete(rom)

	bus: core.Bus
	defer core.bus_destroy(&bus)
	_ = core.bus_load_rom(&bus, rom)

	core.bus_write(&bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&bus, 0xA000, 0x07)

	data, ok := core.mbc_export_ram(&bus.cart)
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, len(data) == 512, "MBC2は内蔵512バイト")
	testing.expect(t, data[0] == 0x07)

	bus2: core.Bus
	defer core.bus_destroy(&bus2)
	_ = core.bus_load_rom(&bus2, rom)
	testing.expect(t, core.mbc_import_ram(&bus2.cart, data))
	core.bus_write(&bus2, 0x0000, 0x0A)
	testing.expect(t, core.bus_read(&bus2, 0xA000) & 0x0F == 0x07)
}

@(test)
test_mbc3_export_ram_excludes_rtc :: proc(t: ^testing.T) {
	rom := make([]u8, 0x8000)
	rom[core.HEADER_TYPE_ADDR] = 0x10 // MBC3+TIMER+RAM+BATTERY
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02 // 8KiB
	defer delete(rom)

	emu: core.Emulator
	defer core.bus_destroy(&emu.bus)
	_ = core.emulator_load_rom(&emu, rom)

	core.emulator_set_wall_clock(&emu, 5_000) // RTCのライブレジスタに何か状態を与える
	core.emulator_set_wall_clock(&emu, 5_100)

	core.bus_write(&emu.bus, 0x0000, 0x0A)
	core.bus_write(&emu.bus, 0x4000, 0x00) // RAMバンク選択
	core.bus_write(&emu.bus, 0xA000, 0x55)

	data, ok := core.mbc_export_ram(&emu.bus.cart)
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, len(data) == 8 * 1024, "RTCレジスタ(5バイト)は含まれずRAM分のみ")
	testing.expect(t, data[0] == 0x55)
}
