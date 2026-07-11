package tests

import "core:testing"
import core "bbl:core"

// HALT の起床条件・EI の1命令遅延・HALT バグの単体テスト(T2-2)。

@(private = "file")
make_halt_ei_system :: proc(program: []u8) -> (core.Cpu, core.Bus) {
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

// EI の直後の1命令が実行されている間は割り込みが入らず、その次から入る。
@(test)
test_ei_delay_skips_interrupt_for_one_instruction :: proc(t: ^testing.T) {
	cpu, bus := make_halt_ei_system([]u8{0xFB, 0x00, 0x00}) // EI; NOP; NOP
	defer delete(bus.rom)
	core.bus_write(&bus, 0xFFFF, 0x01) // IE: VBlank
	core.bus_write(&bus, 0xFF0F, 0x01) // IF: VBlank(既に成立)

	core.cpu_step(&cpu, &bus) // EI 実行、まだ ime=false
	testing.expect(t, !cpu.ime, "EI直後はまだIMEが有効にならない")
	testing.expect(t, cpu.pc == 0x0101)

	core.cpu_step(&cpu, &bus) // EI直後の1命令(NOP)、まだ割り込みは入らない
	testing.expect(t, cpu.pc == 0x0102, "EI直後の命令の実行中は割り込みが入らない")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x01 != 0, "IF bitはまだクリアされない")

	core.cpu_step(&cpu, &bus) // ここでようやくディスパッチされる
	testing.expect(t, cpu.pc == 0x0040, "2命令目の実行後に割り込みがディスパッチされる")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x01 == 0, "ディスパッチでIF bitがクリアされる")
}

// EI; DI が連続すると、EI で予約された IME 有効化はキャンセルされ割り込みは一切発生しない
// (mooneye acceptance/rapid_di_ei.s の "Rapid EI/DI" ラウンド相当)。
@(test)
test_ei_immediately_followed_by_di_cancels_pending_enable :: proc(t: ^testing.T) {
	cpu, bus := make_halt_ei_system([]u8{0xFB, 0xF3, 0x00, 0x00}) // EI; DI; NOP; NOP
	defer delete(bus.rom)
	core.bus_write(&bus, 0xFFFF, 0x01)
	core.bus_write(&bus, 0xFF0F, 0x01)

	for _ in 0 ..< 4 {
		core.cpu_step(&cpu, &bus)
	}

	testing.expect(t, !cpu.ime, "DIがEIの予約をキャンセルするのでIMEは有効にならない")
	testing.expect(t, cpu.pc == 0x0104, "割り込みが起きず全命令が順に実行される")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x01 != 0, "ディスパッチされないのでIFは変化しない")
}

// HALT は IME=false かつ割り込み保留中の状態で実行されると、実際には停止せず
// 次の命令の先頭バイトを2回読む(HALT バグ)。
@(test)
test_halt_bug_rereads_next_byte_when_ime_false_and_pending :: proc(t: ^testing.T) {
	cpu, bus := make_halt_ei_system([]u8{0x76, 0x3C}) // HALT; INC A
	defer delete(bus.rom)
	cpu.ime = false
	cpu.a = 0x00 // cpu_reset(.DMG) はA=0x01から始まるので明示的に0へ揃える
	core.bus_write(&bus, 0xFFFF, 0x01)
	core.bus_write(&bus, 0xFF0F, 0x01) // 割り込み保留中

	core.cpu_step(&cpu, &bus) // HALT: バグが発動、実際には停止しない
	testing.expect(t, !cpu.halted, "IME=falseかつ保留中ならHALTは成立しない(バグ発動)")
	testing.expect(t, cpu.pc == 0x0101, "HALT自体のフェッチでPCは1進む")
	testing.expect(t, cpu.a == 0x00)

	core.cpu_step(&cpu, &bus) // INC A の1回目(PCが進まない)
	testing.expect(t, cpu.pc == 0x0101, "HALTバグでPCが足踏みする")
	testing.expect(t, cpu.a == 0x01)

	core.cpu_step(&cpu, &bus) // INC A の2回目(同じバイトが再度実行される)
	testing.expect(t, cpu.pc == 0x0102, "2回目でようやくPCが進む")
	testing.expect(t, cpu.a == 0x02, "同じ0x3Cバイトが2回実行されている")
}

// HALT は IME=true なら通常どおり停止し、割り込みが来ると起床してハンドラへ飛ぶ。
@(test)
test_halt_wakes_and_dispatches_when_ime_true :: proc(t: ^testing.T) {
	cpu, bus := make_halt_ei_system([]u8{0x76}) // HALT
	defer delete(bus.rom)
	cpu.ime = true

	core.cpu_step(&cpu, &bus) // HALT: 保留中の割り込みが無いので実際に停止する
	testing.expect(t, cpu.halted)

	core.cpu_step(&cpu, &bus) // まだ割り込みが来ていないので停止したまま
	testing.expect(t, cpu.halted)
	testing.expect(t, cpu.pc == 0x0101, "停止中はPCが進まない")

	core.bus_write(&bus, 0xFFFF, 0x01)
	core.bus_write(&bus, 0xFF0F, 0x01) // 割り込み発生

	core.cpu_step(&cpu, &bus) // 起床してディスパッチされる
	testing.expect(t, !cpu.halted)
	testing.expect(t, cpu.pc == 0x0040)
}

// HALT は IME=false でも起床する(ただしハンドラには飛ばず次の命令へ進む)。
@(test)
test_halt_wakes_without_dispatch_when_ime_false_and_no_pending_at_halt_time :: proc(t: ^testing.T) {
	cpu, bus := make_halt_ei_system([]u8{0x76, 0x00}) // HALT; NOP
	defer delete(bus.rom)
	cpu.ime = false
	core.bus_write(&bus, 0xFFFF, 0x01)
	core.bus_write(&bus, 0xFF0F, 0x00) // HALT実行時点では保留中でない(バグは発動しない)

	core.cpu_step(&cpu, &bus) // HALT成立(保留中でないのでバグは発動しない)
	testing.expect(t, cpu.halted)
	testing.expect(t, cpu.pc == 0x0101)

	core.bus_write(&bus, 0xFF0F, 0x01) // 割り込み発生(IME=falseのまま)

	core.cpu_step(&cpu, &bus) // IME=falseでも起床する。ハンドラには飛ばず次の命令(NOP)を実行
	testing.expect(t, !cpu.halted, "IME=falseでも起床する")
	testing.expect(t, cpu.pc == 0x0102, "ハンドラへは飛ばず通常の命令フェッチが進む")
	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x01 != 0, "IF bitはクリアされない(ディスパッチしていない)")
}
