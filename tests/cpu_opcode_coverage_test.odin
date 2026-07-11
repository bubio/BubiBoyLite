package tests

import "core:fmt"
import "core:testing"
import core "bbl:core"

// 全 245 + CB 256 オペコードが switch で網羅されていること(default 到達でも panic せず
// エラーフラグが立つだけ)を確認する。実行はすべて公開 API の cpu_step 経由。

@(private = "file")
known_illegal_opcodes :: [11]u8{0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD}

@(private = "file")
is_known_illegal :: proc(opcode: u8) -> bool {
	list := known_illegal_opcodes
	for op in list {
		if op == opcode {
			return true
		}
	}
	return false
}

@(test)
test_all_opcodes_are_handled :: proc(t: ^testing.T) {
	for opcode in 0 ..= 255 {
		op := u8(opcode)
		cpu: core.Cpu
		bus: core.Bus
		rom := make([]u8, 32768)
		rom[0x0100] = op
		_ = core.bus_load_rom(&bus, rom)
		core.cpu_reset(&cpu, .Dmg)
		core.cpu_step(&cpu, &bus)

		if is_known_illegal(op) {
			testing.expect(
				t,
				cpu.illegal_opcode_hit,
				fmt.tprintf("opcode 0x%02X は未定義オペコードとして検出されるべき", op),
			)
		} else {
			testing.expect(
				t,
				!cpu.stopped,
				fmt.tprintf("opcode 0x%02X は実装済みのはず(未実装として stopped になった)", op),
			)
		}
		delete(rom)
	}
}

@(test)
test_all_cb_opcodes_are_handled :: proc(t: ^testing.T) {
	for opcode in 0 ..= 255 {
		op := u8(opcode)
		cpu: core.Cpu
		bus: core.Bus
		rom := make([]u8, 32768)
		rom[0x0100] = 0xCB
		rom[0x0101] = op
		_ = core.bus_load_rom(&bus, rom)
		core.cpu_reset(&cpu, .Dmg)
		core.cpu_step(&cpu, &bus)

		testing.expect(
			t,
			!cpu.stopped,
			fmt.tprintf("CB opcode 0x%02X は実装済みのはず(未実装として stopped になった)", op),
		)
		delete(rom)
	}
}
