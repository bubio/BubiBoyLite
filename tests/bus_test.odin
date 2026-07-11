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
test_div_increments_and_resets_on_write :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_tick(&bus, 252)
	testing.expect(t, core.bus_read(&bus, 0xFF04) == 0, "DIVは256T-cycle未満ではまだ0")
	core.bus_tick(&bus, 4)
	testing.expect(t, core.bus_read(&bus, 0xFF04) == 1, "256T-cycleでDIVが1増える")
	core.bus_write(&bus, 0xFF04, 0x99) // 値によらずDIVは0にリセットされる
	testing.expect(t, core.bus_read(&bus, 0xFF04) == 0)
}

@(test)
test_tima_counts_up_when_tac_enabled_and_reloads_on_overflow :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF06, 0x10) // TMA
	core.bus_write(&bus, 0xFF07, 0x05) // TAC: enable, 262144Hz(周期16T)
	core.bus_write(&bus, 0xFF05, 0xFF) // TIMA: 次の1目盛りでオーバーフロー
	core.bus_tick(&bus, 16) // 落下エッジでオーバーフロー: この時点ではまだTIMA=0x00(リロード遅延中)
	testing.expect(t, core.bus_read(&bus, 0xFF05) == 0x00, "オーバーフロー直後は4 T-cycleの間TIMA=0x00")
	core.bus_tick(&bus, 4) // リロード遅延の4 T-cycle経過
	testing.expect(t, core.bus_read(&bus, 0xFF05) == 0x10, "4 T-cycle後にTMAがリロードされる")
}

@(test)
test_tima_does_not_count_when_tac_disabled :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF07, 0x01) // TAC: 有効bit(bit2)なし
	core.bus_tick(&bus, 1000)
	testing.expect(t, core.bus_read(&bus, 0xFF05) == 0, "TAC無効時はTIMAが増えない")
}

@(test)
test_tima_overflow_sets_if_timer_bit :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF0F, 0x00) // IF クリア
	core.bus_write(&bus, 0xFF07, 0x05) // TAC 有効、周期16T
	core.bus_write(&bus, 0xFF05, 0xFF)
	core.bus_tick(&bus, 16) // 落下エッジでオーバーフロー
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x04 == 0, "リロード完了までIF bit2はまだセットされない")
	core.bus_tick(&bus, 4) // リロード遅延の4 T-cycle経過
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x04 != 0, "リロード完了時にIF bit2がセットされる")
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
