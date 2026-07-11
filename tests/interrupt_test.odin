package tests

import "core:testing"
import core "bbl:core"

// IF/IE/割り込みディスパッチの単体テスト(T2-1)。
// HALT の起床条件・EI 遅延・HALT バグは T2-2 で cpu_step_test.odin 等に追加する。

@(private = "file")
make_interrupt_system :: proc() -> (core.Cpu, core.Bus) {
	cpu: core.Cpu
	bus: core.Bus
	rom := make([]u8, 32768)
	_ = core.bus_load_rom(&bus, rom)
	core.cpu_reset(&cpu, .DMG)
	return cpu, bus
}

@(test)
test_interrupt_dispatch_jumps_to_vblank_handler :: proc(t: ^testing.T) {
	cpu, bus := make_interrupt_system()
	defer delete(bus.cart.rom)
	cpu.ime = true
	cpu.pc = 0x0200
	cpu.sp = 0xFFFE
	core.bus_write(&bus, 0xFFFF, 0x01) // IE: VBlank
	core.bus_write(&bus, 0xFF0F, 0x01) // IF: VBlank

	cycles := core.cpu_step(&cpu, &bus)

	testing.expect(t, cycles == 20, "ディスパッチは20 T-cycle")
	testing.expect(t, cpu.pc == 0x0040, "VBlankベクタへジャンプ")
	testing.expect(t, !cpu.ime, "ディスパッチ後IMEはクリア")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x01 == 0, "対応するIF bitがクリアされる")
	testing.expect(t, cpu.sp == 0xFFFC, "PCがPUSHされSPが2減る")
	testing.expect(t, core.bus_read(&bus, 0xFFFC) == 0x00, "PCLがPUSHされる")
	testing.expect(t, core.bus_read(&bus, 0xFFFD) == 0x02, "PCHがPUSHされる")
}

@(test)
test_interrupt_priority_is_lowest_bit_first :: proc(t: ^testing.T) {
	cpu, bus := make_interrupt_system()
	defer delete(bus.cart.rom)
	cpu.ime = true
	cpu.pc = 0x0200
	cpu.sp = 0xFFFE
	core.bus_write(&bus, 0xFFFF, 0x1F) // IE: 全部
	core.bus_write(&bus, 0xFF0F, 0x1A) // IF: Stat|Serial|Joypad (VBlank/Timerなし)

	core.cpu_step(&cpu, &bus)

	testing.expect(t, cpu.pc == 0x0048, "Statが最優先で処理される(bit1)")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x1A == 0x18, "Statのbitだけクリアされる")
}

@(test)
test_no_dispatch_when_ime_false :: proc(t: ^testing.T) {
	cpu, bus := make_interrupt_system()
	defer delete(bus.cart.rom)
	cpu.ime = false
	cpu.pc = 0x0100
	core.bus_write(&bus, 0xFFFF, 0x01)
	core.bus_write(&bus, 0xFF0F, 0x01)

	cycles := core.cpu_step(&cpu, &bus)

	testing.expect(t, cycles == 4, "IME=falseならNOP相当の通常フェッチのみ")
	testing.expect(t, cpu.pc == 0x0101, "通常に命令フェッチが進む")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x01 != 0, "IF bitはクリアされない")
}

@(test)
test_no_dispatch_when_if_and_ie_do_not_overlap :: proc(t: ^testing.T) {
	cpu, bus := make_interrupt_system()
	defer delete(bus.cart.rom)
	cpu.ime = true
	cpu.pc = 0x0100
	core.bus_write(&bus, 0xFFFF, 0x02) // IE: Statのみ
	core.bus_write(&bus, 0xFF0F, 0x01) // IF: VBlankのみ

	cycles := core.cpu_step(&cpu, &bus)

	testing.expect(t, cycles == 4)
	testing.expect(t, cpu.pc == 0x0101)
}

// ie_push 相当: PC上位バイトのPUSHがIE(0xFFFF)を書き換え、その時点でのIE&IFに
// 対象ビットが無くなればディスパッチはキャンセルされ、IFはクリアされずPC=0x0000へ飛ぶ。
// (mooneye acceptance/interrupts/ie_push.s Round 1)
@(test)
test_ie_push_cancels_dispatch_when_high_byte_write_clears_pending_bit :: proc(t: ^testing.T) {
	cpu, bus := make_interrupt_system()
	defer delete(bus.cart.rom)
	cpu.ime = true
	cpu.pc = 0x0200 // PCH=0x02: 上位バイトPUSHでIEが0x02(Stat)になる
	cpu.sp = 0x0000 // 上位バイトはSP-1=0xFFFF(IE)へ書かれる
	core.bus_write(&bus, 0xFFFF, 0x04) // IE: Timerのみ
	core.bus_write(&bus, 0xFF0F, 0x04) // IF: Timerのみ

	core.cpu_step(&cpu, &bus)

	testing.expect(t, cpu.pc == 0x0000, "IEが書き換わり対象が消えるとPC=0x0000へキャンセルされる")
	testing.expect(t, !cpu.ime, "キャンセルされてもIMEはクリアされたまま")
	testing.expect(t, core.bus_read(&bus, 0xFFFF) == 0x02, "IEは上位バイトPUSHの値のまま")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x1F == 0x04, "IFはクリアされない(対象が決まらなかった)")
}

// ie_push Round 3 相当: 下位バイトのPUSHがIEを書き換えても、ベクタは既に決定済みなので
// ディスパッチは通常どおり進む。
@(test)
test_ie_push_low_byte_corruption_is_too_late_to_cancel :: proc(t: ^testing.T) {
	cpu, bus := make_interrupt_system()
	defer delete(bus.cart.rom)
	cpu.ime = true
	cpu.pc = 0x0300
	cpu.sp = 0x0001 // 下位バイトはSP-2=0xFFFF(IE)へ書かれる、上位バイトはSP-1=0x0000(ROM)
	core.bus_write(&bus, 0xFFFF, 0x08) // IE: Serialのみ
	core.bus_write(&bus, 0xFF0F, 0x08) // IF: Serialのみ

	core.cpu_step(&cpu, &bus)

	testing.expect(t, cpu.pc == 0x0058, "下位バイトの書き換えは手遅れで通常どおりSerialへ")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x08 == 0, "IFのSerial bitはクリアされる")
}
