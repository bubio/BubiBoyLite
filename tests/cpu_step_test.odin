package tests

import "core:testing"
import core "bbl:core"

// make_test_system は ROM に program をロードした CPU+Bus のペアを作る。
// PC=0x0100 から実行を開始する(cpu_reset と同じ配置)。
@(private = "file")
make_test_system :: proc(program: []u8) -> (core.Cpu, core.Bus) {
	cpu: core.Cpu
	bus: core.Bus
	rom := make([]u8, 32768)
	for b, i in program {
		rom[0x0100 + i] = b
	}
	_ = core.bus_load_rom(&bus, rom)
	core.cpu_reset(&cpu, .DMG)
	return cpu, bus
}

@(test)
test_step_nop_takes_4_cycles :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x00})
	defer delete(bus.rom)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 4)
	testing.expect(t, cpu.pc == 0x0101)
}

@(test)
test_step_ld_b_d8 :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x06, 0x42}) // LD B,0x42
	defer delete(bus.rom)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 8)
	testing.expect(t, cpu.b == 0x42)
}

@(test)
test_step_ld_r_r :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x41}) // LD B,C
	defer delete(bus.rom)
	cpu.c = 0x77
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 4)
	testing.expect(t, cpu.b == 0x77)
}

@(test)
test_step_ld_r_hl_takes_8_cycles :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x46}) // LD B,(HL)
	defer delete(bus.rom)
	core.cpu_set_hl(&cpu, 0xC000)
	core.bus_write(&bus, 0xC000, 0x99)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 8)
	testing.expect(t, cpu.b == 0x99)
}

@(test)
test_step_inc_dec_hl_indirect_takes_12_cycles :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x34}) // INC (HL)
	defer delete(bus.rom)
	core.cpu_set_hl(&cpu, 0xC000)
	core.bus_write(&bus, 0xC000, 0x0F)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 12)
	testing.expect(t, core.bus_read(&bus, 0xC000) == 0x10)
	testing.expect(t, core.cpu_flag_h(&cpu))
}

@(test)
test_adc_half_and_full_carry :: proc(t: ^testing.T) {
	// ADC A,B: A=0x0F, B=0x01, carry_in=1 => 0x11, H set, C clear
	cpu, bus := make_test_system([]u8{0x88}) // ADC A,B
	defer delete(bus.rom)
	cpu.a = 0x0F
	cpu.b = 0x01
	core.cpu_set_flags(&cpu, false, false, false, true)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x11)
	testing.expect(t, core.cpu_flag_h(&cpu))
	testing.expect(t, !core.cpu_flag_c(&cpu))
}

@(test)
test_adc_carries_out :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x88}) // ADC A,B
	defer delete(bus.rom)
	cpu.a = 0xFF
	cpu.b = 0x01
	core.cpu_set_flags(&cpu, false, false, false, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x00)
	testing.expect(t, core.cpu_flag_z(&cpu))
	testing.expect(t, core.cpu_flag_h(&cpu))
	testing.expect(t, core.cpu_flag_c(&cpu))
}

@(test)
test_sbc_borrow_across_nibble :: proc(t: ^testing.T) {
	// SBC A,B: A=0x10, B=0x01, carry_in=1 => 0x10 - 0x01 - 1 = 0x0E, H set (borrow from bit4), C clear
	cpu, bus := make_test_system([]u8{0x98}) // SBC A,B
	defer delete(bus.rom)
	cpu.a = 0x10
	cpu.b = 0x01
	core.cpu_set_flags(&cpu, false, false, false, true)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x0E)
	testing.expect(t, core.cpu_flag_h(&cpu))
	testing.expect(t, !core.cpu_flag_c(&cpu))
	testing.expect(t, core.cpu_flag_n(&cpu))
}

@(test)
test_sbc_borrows_out :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0x98}) // SBC A,B
	defer delete(bus.rom)
	cpu.a = 0x00
	cpu.b = 0x01
	core.cpu_set_flags(&cpu, false, false, false, false)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0xFF)
	testing.expect(t, core.cpu_flag_c(&cpu))
	testing.expect(t, core.cpu_flag_h(&cpu))
}

@(test)
test_cp_does_not_modify_a :: proc(t: ^testing.T) {
	cpu, bus := make_test_system([]u8{0xB8}) // CP B
	defer delete(bus.rom)
	cpu.a = 0x10
	cpu.b = 0x10
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x10)
	testing.expect(t, core.cpu_flag_z(&cpu))
}
