package tests

import "core:testing"
import core "bbl:core"

// src/core/emulator.odin の emulator_reset(TUIの /reset コマンド用)の単体テスト。
// savestate_test.odin の make_savestate_test_rom と同じ流儀で MBC1+RAM+BATTERY の
// 合成ROMを作り、数フレーム実行してWRAM/cart RAMへ書き込んだ後にresetし、
// CPUがブート後状態に戻ること・WRAMがクリアされること・cart RAM(SRAM)は保持されることを
// 検証する。

@(private = "file")
make_reset_test_rom :: proc(rom_size_code: u8, bank_count: int) -> []u8 {
	size := 16 * 1024 * bank_count
	rom := make([]u8, size)
	rom[core.HEADER_TYPE_ADDR] = 0x03 // MBC1+RAM+BATTERY
	rom[core.HEADER_ROM_SIZE_ADDR] = rom_size_code
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x02 // 8KiB
	for bank in 0 ..< bank_count {
		rom[bank * 0x4000] = u8(bank)
	}
	return rom
}

@(test)
test_emulator_reset_clears_wram_but_keeps_cart_ram :: proc(t: ^testing.T) {
	rom := make_reset_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(emu, rom)
	testing.expect(t, ok)

	for _ in 0 ..< 3 {
		core.emulator_run_frame(emu)
	}

	// WRAMへ書き込む(reset後にクリアされることを確認する対象)。
	core.bus_write(&emu.bus, 0xC010, 0x42)
	testing.expect(t, core.bus_read(&emu.bus, 0xC010) == 0x42)

	// cart RAM(SRAM)へ書き込む(reset後も保持されることを確認する対象)。
	core.bus_write(&emu.bus, 0x0000, 0x0A) // RAM有効化
	core.bus_write(&emu.bus, 0xA000, 0x77)
	testing.expect(t, core.bus_read(&emu.bus, 0xA000) == 0x77)

	core.emulator_reset(emu)

	// CPUはブート後レジスタ初期値(references.md)に戻る。
	testing.expect_value(t, emu.cpu.pc, 0x0100)
	testing.expect_value(t, emu.cpu.sp, 0xFFFE)
	testing.expect(t, !emu.cpu.stopped)
	testing.expect(t, !emu.cpu.halted)

	// WRAMはゼロクリアされる。
	testing.expect_value(t, core.bus_read(&emu.bus, 0xC010), 0x00)

	// cart RAM(SRAM)は保持される。cart(MBC状態含む)を丸ごと保持する実装のため、
	// RAM有効化(RAMGビット)も reset を跨いで維持され、再有効化なしで読める。
	testing.expect_value(t, core.bus_read(&emu.bus, 0xA000), 0x77)
}

@(test)
test_emulator_reset_preserves_rom_reference :: proc(t: ^testing.T) {
	// cart.rom は借用スライスなので reset 後も元の rom_data を指し続け、ROMバンク読み出しが
	// 引き続き機能することを確認する(回帰防止: emu.bus = {} で cart 自体を巻き込んで
	// ゼロ化していないこと)。
	rom := make_reset_test_rom(0x00, 2)
	defer delete(rom)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	ok := core.emulator_load_rom(emu, rom)
	testing.expect(t, ok)

	core.emulator_reset(emu)

	testing.expect_value(t, core.bus_read(&emu.bus, 0x0000), 0x00) // bank0の先頭バイト(0で初期化)
	testing.expect_value(t, core.bus_read(&emu.bus, 0x4000), 0x01) // bank1先頭バイト = bank番号
}
