package tests

import "core:testing"
import core "bbl:core"

// DAA は直前の ADD/ADC/SUB/SBC の結果を BCD (2桁10進数) に補正する。
// 各テストは「実際に ADD/SUB を実行した直後のフラグ状態」を手動で再現し、
// DAA 単体 (opcode 0x27) を cpu_step で実行して検証する
// (cpu_execute/cpu_daa はパッケージ非公開のため、公開 API の cpu_step 経由で駆動する)。

@(private = "file")
make_daa_system :: proc() -> (core.Cpu, core.Bus) {
	cpu: core.Cpu
	bus: core.Bus
	rom := make([]u8, 32768)
	rom[0x0100] = 0x27 // DAA
	_ = core.bus_load_rom(&bus, rom)
	core.cpu_reset(&cpu, .DMG)
	return cpu, bus
}

@(test)
test_daa_add_0x15_plus_0x27 :: proc(t: ^testing.T) {
	// 0x15 + 0x27 (BCD) = 0x3C (バイナリ加算結果、H=0,C=0) => DAA で 0x42 に補正
	cpu, bus := make_daa_system()
	defer delete(bus.cart.rom)
	cpu.a = 0x3C
	core.cpu_set_flags(&cpu, false, false, false, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x42, "0x15+0x27 は BCD で 0x42 になるはず")
	testing.expect(t, !core.cpu_flag_c(&cpu))
	testing.expect(t, !core.cpu_flag_z(&cpu))
}

@(test)
test_daa_add_with_half_carry :: proc(t: ^testing.T) {
	// 0x09 + 0x08 (BCD: 9+8=17) => バイナリ加算結果 0x11, H=1 => DAA で 0x17 に補正
	cpu, bus := make_daa_system()
	defer delete(bus.cart.rom)
	cpu.a = 0x11
	core.cpu_set_flags(&cpu, false, false, true, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x17)
	testing.expect(t, !core.cpu_flag_c(&cpu))
}

@(test)
test_daa_add_carries_into_hundreds :: proc(t: ^testing.T) {
	// 0x99 + 0x01 (BCD: 99+1=100) => バイナリ加算結果 0x9A, H=0,C=0
	// => DAA で 0x00 に折り返り、C=1 (桁あふれ) がセットされる
	cpu, bus := make_daa_system()
	defer delete(bus.cart.rom)
	cpu.a = 0x9A
	core.cpu_set_flags(&cpu, false, false, false, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x00)
	testing.expect(t, core.cpu_flag_z(&cpu))
	testing.expect(t, core.cpu_flag_c(&cpu))
}

@(test)
test_daa_add_carry_flag_forces_upper_correction :: proc(t: ^testing.T) {
	// C フラグが既にセットされていれば、A の値によらず上位補正(+0x60)が入る
	cpu, bus := make_daa_system()
	defer delete(bus.cart.rom)
	cpu.a = 0x05
	core.cpu_set_flags(&cpu, false, false, false, true)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x65)
	testing.expect(t, core.cpu_flag_c(&cpu), "セット済みの C は DAA 後も保持される")
}

@(test)
test_daa_add_no_correction_needed :: proc(t: ^testing.T) {
	// 0x11 + 0x14 (BCD: 11+14=25) => バイナリ結果 0x25 は既に正しい BCD => 補正なし
	cpu, bus := make_daa_system()
	defer delete(bus.cart.rom)
	cpu.a = 0x25
	core.cpu_set_flags(&cpu, false, false, false, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x25)
	testing.expect(t, !core.cpu_flag_c(&cpu))
}

@(test)
test_daa_sub_66_minus_39 :: proc(t: ^testing.T) {
	// 0x66 - 0x39 (BCD: 66-39=27) => バイナリ減算結果 0x2D, N=1,H=1(下位借り),C=0
	// => DAA (減算側) で 0x27 に補正
	cpu, bus := make_daa_system()
	defer delete(bus.cart.rom)
	cpu.a = 0x2D
	core.cpu_set_flags(&cpu, false, true, true, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x27, "0x66-0x39 は BCD で 0x27 になるはず")
	testing.expect(t, !core.cpu_flag_c(&cpu))
	testing.expect(t, core.cpu_flag_n(&cpu), "DAA は N フラグを変更しない")
}
