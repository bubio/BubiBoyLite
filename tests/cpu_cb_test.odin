package tests

import "core:testing"
import core "bbl:core"

@(private = "file")
make_cb_system :: proc(program: []u8) -> (core.Cpu, core.Bus) {
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
test_cb_swap_a :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x37}) // SWAP A
	defer delete(bus.rom)
	cpu.a = 0xAB
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 8)
	testing.expect(t, cpu.a == 0xBA)
	testing.expect(t, !core.cpu_flag_c(&cpu))
}

@(test)
test_cb_swap_zero_sets_z :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x37}) // SWAP A
	defer delete(bus.rom)
	cpu.a = 0x00
	core.cpu_step(&cpu, &bus)
	testing.expect(t, core.cpu_flag_z(&cpu))
}

@(test)
test_cb_bit_non_hl_is_8_cycles :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x7F}) // BIT 7,A
	defer delete(bus.rom)
	cpu.a = 0x00
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 8)
	testing.expect(t, core.cpu_flag_z(&cpu), "bit7=0なのでZ=1")
	testing.expect(t, core.cpu_flag_h(&cpu), "BITは常にH=1")
	testing.expect(t, !core.cpu_flag_n(&cpu))
}

@(test)
test_cb_bit_hl_is_12_cycles :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x46}) // BIT 0,(HL)
	defer delete(bus.rom)
	core.cpu_set_hl(&cpu, 0xC000)
	core.bus_write(&bus, 0xC000, 0x01)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 12)
	testing.expect(t, !core.cpu_flag_z(&cpu), "bit0=1なのでZ=0")
}

@(test)
test_cb_res_hl_is_16_cycles :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x86}) // RES 0,(HL)
	defer delete(bus.rom)
	core.cpu_set_hl(&cpu, 0xC000)
	core.bus_write(&bus, 0xC000, 0xFF)
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 16)
	testing.expect(t, core.bus_read(&bus, 0xC000) == 0xFE)
}

@(test)
test_cb_set_b :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0xC0}) // SET 0,B
	defer delete(bus.rom)
	cpu.b = 0x00
	cycles := core.cpu_step(&cpu, &bus)
	testing.expect(t, cycles == 8)
	testing.expect(t, cpu.b == 0x01)
}

@(test)
test_cb_rlc_a_sets_z_when_zero :: proc(t: ^testing.T) {
	// CB版 RLC A は非CB版 RLCA と異なり Z を通常どおり設定する
	cpu, bus := make_cb_system([]u8{0xCB, 0x07}) // RLC A
	defer delete(bus.rom)
	cpu.a = 0x00
	core.cpu_step(&cpu, &bus)
	testing.expect(t, core.cpu_flag_z(&cpu), "CB RLC A は結果0でZ=1になる")
}

@(test)
test_cb_sra_preserves_sign_bit :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x2F}) // SRA A
	defer delete(bus.rom)
	cpu.a = 0x80
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0xC0)
}

@(test)
test_cb_srl_clears_bit7 :: proc(t: ^testing.T) {
	cpu, bus := make_cb_system([]u8{0xCB, 0x3F}) // SRL A
	defer delete(bus.rom)
	cpu.a = 0x81
	core.cpu_step(&cpu, &bus)
	testing.expect(t, cpu.a == 0x40)
	testing.expect(t, core.cpu_flag_c(&cpu))
}
