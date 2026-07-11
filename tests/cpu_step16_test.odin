package tests

import "core:testing"
import core "bbl:core"

@(private = "file")
make_system16 :: proc(program: []u8) -> (core.Cpu, core.Bus) {
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
test_push_pop_round_trip :: proc(t: ^testing.T) {
	// PUSH BC ; POP DE
	cpu, bus := make_system16([]u8{0xC5, 0xD1})
	defer delete(bus.rom)
	core.cpu_set_bc(&cpu, 0xBEEF)
	cycles1 := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles1 == 16, "PUSH rr は 16 サイクル")
	cycles2 := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles2 == 12, "POP rr は 12 サイクル")
	testing.expect(t, core.cpu_de(&cpu) == 0xBEEF)
}

@(test)
test_pop_af_masks_low_nibble :: proc(t: ^testing.T) {
	// PUSH BC(=0x12FF) ; POP AF
	cpu, bus := make_system16([]u8{0xC5, 0xF1})
	defer delete(bus.rom)
	core.cpu_set_bc(&cpu, 0x12FF)
	core.cpu_step(&cpu, &bus)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x12)
	testing.expect(t, cpu.f == 0xF0, "POP AF でも F の下位4bitはマスクされる")
}

@(test)
test_jr_conditional_taken_and_not_taken_cycles :: proc(t: ^testing.T) {
	// JR Z,+2 (not taken, Z=0) then JR Z,+2 (taken, Z=1)
	cpu, bus := make_system16([]u8{0x28, 0x02, 0x00, 0x00, 0x28, 0x02})
	defer delete(bus.rom)
	core.cpu_set_flags(&cpu, false, false, false, false) // Z=0
	cycles_not_taken := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles_not_taken == 8, "JR cc 不成立は8サイクル")
	testing.expect(t, cpu.pc == 0x0102)

	core.cpu_set_flags(&cpu, true, false, false, false) // Z=1
	// PC is now 0x0102; jump to opcode at +2 offset manually for taken test.
	cpu.pc = 0x0104
	cycles_taken := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles_taken == 12, "JR cc 成立は12サイクル")
	testing.expect(t, cpu.pc == 0x0104 + 2 + 2)
}

@(test)
test_jp_hl_is_4_cycles_no_memory_access :: proc(t: ^testing.T) {
	cpu, bus := make_system16([]u8{0xE9})
	defer delete(bus.rom)
	core.cpu_set_hl(&cpu, 0x1234)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 4)
	testing.expect(t, cpu.pc == 0x1234)
}

@(test)
test_call_and_ret_round_trip :: proc(t: ^testing.T) {
	// CALL 0x0200 ; at 0x0200: RET
	cpu, bus := make_system16([]u8{0xCD, 0x00, 0x02})
	defer delete(bus.rom)
	bus.rom[0x0200] = 0xC9 // RET
	cycles_call := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles_call == 24, "CALL は24サイクル")
	testing.expect(t, cpu.pc == 0x0200)
	testing.expect(t, cpu.sp == 0xFFFC)

	cycles_ret := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles_ret == 16, "RET は16サイクル")
	testing.expect(t, cpu.pc == 0x0103, "呼び出し元の次の命令に戻る")
	testing.expect(t, cpu.sp == 0xFFFE)
}

@(test)
test_call_not_taken_cycles :: proc(t: ^testing.T) {
	// CALL NZ,0x0200 with Z=1 (not taken)
	cpu, bus := make_system16([]u8{0xC4, 0x00, 0x02})
	defer delete(bus.rom)
	core.cpu_set_flags(&cpu, true, false, false, false)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 12)
	testing.expect(t, cpu.pc == 0x0103)
}

@(test)
test_rst_pushes_return_address :: proc(t: ^testing.T) {
	cpu, bus := make_system16([]u8{0xEF}) // RST 28H
	defer delete(bus.rom)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 16)
	testing.expect(t, cpu.pc == 0x0028)
	testing.expect(t, cpu.sp == 0xFFFC)
}

@(test)
test_add_sp_e8_flags_use_low_byte :: proc(t: ^testing.T) {
	// SP=0x0FFF, e8=0x01 => low byte add: 0xFF+0x01 => H,C both set; result=0x1000
	cpu, bus := make_system16([]u8{0xE8, 0x01})
	defer delete(bus.rom)
	cpu.sp = 0x0FFF
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 16)
	testing.expect(t, cpu.sp == 0x1000)
	testing.expect(t, !core.cpu_flag_z(&cpu))
	testing.expect(t, !core.cpu_flag_n(&cpu))
	testing.expect(t, core.cpu_flag_h(&cpu))
	testing.expect(t, core.cpu_flag_c(&cpu))
}

@(test)
test_add_sp_negative_e8 :: proc(t: ^testing.T) {
	// SP=0x0005, e8=-1(0xFF) => SP=0x0004
	cpu, bus := make_system16([]u8{0xE8, 0xFF})
	defer delete(bus.rom)
	cpu.sp = 0x0005
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.sp == 0x0004)
}

@(test)
test_ld_hl_sp_plus_e8 :: proc(t: ^testing.T) {
	cpu, bus := make_system16([]u8{0xF8, 0x02})
	defer delete(bus.rom)
	cpu.sp = 0x1000
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 12)
	testing.expect(t, core.cpu_hl(&cpu) == 0x1002)
	testing.expect(t, cpu.sp == 0x1000, "LD HL,SP+e8 はSPを変更しない")
}

@(test)
test_ld_a16_sp_and_ld_rr_d16 :: proc(t: ^testing.T) {
	// LD SP,0xC0DE ; LD (0xC500),SP
	cpu, bus := make_system16([]u8{0x31, 0xDE, 0xC0, 0x08, 0x00, 0xC5})
	defer delete(bus.rom)
	c1 := core.cpu_step(&cpu, &bus)
	testing.expect(t, c1 == 12)
	testing.expect(t, cpu.sp == 0xC0DE)
	c2 := core.cpu_step(&cpu, &bus)
	testing.expect(t, c2 == 20)
	testing.expect(t, core.bus_read(&bus, 0xC500) == 0xDE)
	testing.expect(t, core.bus_read(&bus, 0xC501) == 0xC0)
}

@(test)
test_ld_hl_inc_dec_indirect_a :: proc(t: ^testing.T) {
	// LD (HL+),A ; LD (HL-),A
	cpu, bus := make_system16([]u8{0x22, 0x32})
	defer delete(bus.rom)
	core.cpu_set_hl(&cpu, 0xC000)
	cpu.a = 0x77
	core.cpu_step(&cpu, &bus)
	testing.expect(t, core.bus_read(&bus, 0xC000) == 0x77)
	testing.expect(t, core.cpu_hl(&cpu) == 0xC001)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, core.bus_read(&bus, 0xC001) == 0x77)
	testing.expect(t, core.cpu_hl(&cpu) == 0xC000)
}
