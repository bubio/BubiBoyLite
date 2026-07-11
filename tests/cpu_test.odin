package tests

import "core:testing"
import core "bbl:core"

@(test)
test_cpu_register_pairs :: proc(t: ^testing.T) {
	cpu: core.Cpu
	core.cpu_set_bc(&cpu, 0x1234)
	testing.expect(t, core.cpu_bc(&cpu) == 0x1234)
	testing.expect(t, cpu.b == 0x12)
	testing.expect(t, cpu.c == 0x34)

	core.cpu_set_de(&cpu, 0xABCD)
	testing.expect(t, core.cpu_de(&cpu) == 0xABCD)

	core.cpu_set_hl(&cpu, 0x9E9E)
	testing.expect(t, core.cpu_hl(&cpu) == 0x9E9E)
}

@(test)
test_cpu_af_masks_low_nibble_of_f :: proc(t: ^testing.T) {
	cpu: core.Cpu
	core.cpu_set_af(&cpu, 0x12FF)
	testing.expect(t, cpu.a == 0x12)
	testing.expect(t, cpu.f == 0xF0, "F の下位4bitは常に0にマスクされること")
	testing.expect(t, core.cpu_af(&cpu) == 0x12F0)
}

@(test)
test_cpu_set_flags :: proc(t: ^testing.T) {
	cpu: core.Cpu
	core.cpu_set_flags(&cpu, true, false, true, false)
	testing.expect(t, cpu.f == core.FLAG_Z | core.FLAG_H)
	testing.expect(t, core.cpu_flag_z(&cpu))
	testing.expect(t, !core.cpu_flag_n(&cpu))
	testing.expect(t, core.cpu_flag_h(&cpu))
	testing.expect(t, !core.cpu_flag_c(&cpu))

	core.cpu_set_flags(&cpu, false, true, false, true)
	testing.expect(t, cpu.f == core.FLAG_N | core.FLAG_C)
}

@(test)
test_cpu_reset_dmg :: proc(t: ^testing.T) {
	cpu: core.Cpu
	core.cpu_reset(&cpu, .Dmg)
	testing.expect(t, core.cpu_af(&cpu) == 0x01B0)
	testing.expect(t, core.cpu_bc(&cpu) == 0x0013)
	testing.expect(t, core.cpu_de(&cpu) == 0x00D8)
	testing.expect(t, core.cpu_hl(&cpu) == 0x014D)
	testing.expect(t, cpu.sp == 0xFFFE)
	testing.expect(t, cpu.pc == 0x0100)
	testing.expect(t, !cpu.ime)
	testing.expect(t, !cpu.halted)
}

@(test)
test_cpu_reset_cgb :: proc(t: ^testing.T) {
	cpu: core.Cpu
	core.cpu_reset(&cpu, .Cgb)
	testing.expect(t, core.cpu_af(&cpu) == 0x1180)
	testing.expect(t, core.cpu_bc(&cpu) == 0x0000)
	testing.expect(t, core.cpu_de(&cpu) == 0xFF56)
	testing.expect(t, core.cpu_hl(&cpu) == 0x000D)
	testing.expect(t, cpu.sp == 0xFFFE)
	testing.expect(t, cpu.pc == 0x0100)
}
