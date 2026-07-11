package tests

import "core:testing"
import core "bbl:core"

@(test)
test_bus_wram_read_write :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xC010, 0x42)
	testing.expect(t, core.bus_read(&bus, 0xC010) == 0x42)
}

@(test)
test_bus_hram_read_write :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF90, 0x7F)
	testing.expect(t, core.bus_read(&bus, 0xFF90) == 0x7F)
}

@(test)
test_bus_echo_mirrors_wram :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xC005, 0x99)
	testing.expect(t, core.bus_read(&bus, 0xE005) == 0x99, "エコーRAMはWRAMを反映する")

	core.bus_write(&bus, 0xE100, 0x11)
	testing.expect(t, core.bus_read(&bus, 0xC100) == 0x11, "エコーRAM書き込みはWRAMに反映される")
}

@(test)
test_bus_unimplemented_io_reads_ff :: proc(t: ^testing.T) {
	bus: core.Bus
	testing.expect(t, core.bus_read(&bus, 0xFF10) == 0xFF)
	core.bus_write(&bus, 0xFF10, 0x00)
	testing.expect(t, core.bus_read(&bus, 0xFF10) == 0xFF, "未実装IOレジスタの読み出しは常に0xFF")
}

@(test)
test_bus_ie_register :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFFFF, 0x1F)
	testing.expect(t, core.bus_read(&bus, 0xFFFF) == 0x1F)
}

@(test)
test_bus_tick_accumulates_cycles :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_tick(&bus, 4)
	core.bus_tick(&bus, 4)
	testing.expect(t, bus.cycles == 8)
}

@(test)
test_cpu_read_write_ticks_bus :: proc(t: ^testing.T) {
	cpu: core.Cpu
	bus: core.Bus
	before := bus.cycles
	core.cpu_write8(&cpu, &bus, 0xC000, 0x55)
	testing.expect(t, bus.cycles == before + 4, "cpu_write8は bus_tick(4) を伴う")
	v := core.cpu_read8(&cpu, &bus, 0xC000)
	testing.expect(t, v == 0x55)
	testing.expect(t, bus.cycles == before + 8, "cpu_read8は bus_tick(4) を伴う")
}

@(test)
test_bus_load_rom :: proc(t: ^testing.T) {
	bus: core.Bus
	data := make([]u8, 32768)
	defer delete(data)
	data[0] = 0xAB
	ok := core.bus_load_rom(&bus, data)
	testing.expect(t, ok)
	testing.expect(t, core.bus_read(&bus, 0x0000) == 0xAB)
}
