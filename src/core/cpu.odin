package core

// SM83 CPU (Game Boy / Game Boy Color). M-cycle 粒度で駆動する。
// architecture.md の「タイミングモデル」を参照。

import "core:fmt"

// F レジスタのビット定義。
FLAG_Z :: 0x80 // Zero
FLAG_N :: 0x40 // Subtract
FLAG_H :: 0x20 // Half carry
FLAG_C :: 0x10 // Carry

// 起動後レジスタ初期値を切り替えるための実行モード。
Console_Mode :: enum {
	DMG,
	CGB,
}

Cpu :: struct {
	a, f, b, c, d, e, h, l: u8,
	sp, pc:                 u16,
	ime:                    bool, // Interrupt Master Enable
	halted:                 bool,
	stopped:                bool, // STOP 実行済み(簡易フラグ、正式対応はフェーズ6)
	illegal_opcode_hit:     bool, // 未定義オペコードを実行した(T1-6)
}

// --- 16bit レジスタペアアクセス ---
// F の下位 4bit は常に 0 にマスクする(architecture.md の型決定事項)。

cpu_af :: proc(cpu: ^Cpu) -> u16 {
	return u16(cpu.a) << 8 | u16(cpu.f)
}

cpu_set_af :: proc(cpu: ^Cpu, v: u16) {
	cpu.a = u8(v >> 8)
	cpu.f = u8(v) & 0xF0
}

cpu_bc :: proc(cpu: ^Cpu) -> u16 {
	return u16(cpu.b) << 8 | u16(cpu.c)
}

cpu_set_bc :: proc(cpu: ^Cpu, v: u16) {
	cpu.b = u8(v >> 8)
	cpu.c = u8(v)
}

cpu_de :: proc(cpu: ^Cpu) -> u16 {
	return u16(cpu.d) << 8 | u16(cpu.e)
}

cpu_set_de :: proc(cpu: ^Cpu, v: u16) {
	cpu.d = u8(v >> 8)
	cpu.e = u8(v)
}

cpu_hl :: proc(cpu: ^Cpu) -> u16 {
	return u16(cpu.h) << 8 | u16(cpu.l)
}

cpu_set_hl :: proc(cpu: ^Cpu, v: u16) {
	cpu.h = u8(v >> 8)
	cpu.l = u8(v)
}

// --- フラグ操作 ---

cpu_set_flags :: proc(cpu: ^Cpu, z, n, h, c: bool) {
	f: u8 = 0
	if z {
		f |= FLAG_Z
	}
	if n {
		f |= FLAG_N
	}
	if h {
		f |= FLAG_H
	}
	if c {
		f |= FLAG_C
	}
	cpu.f = f
}

cpu_flag_z :: proc(cpu: ^Cpu) -> bool {
	return cpu.f & FLAG_Z != 0
}

cpu_flag_n :: proc(cpu: ^Cpu) -> bool {
	return cpu.f & FLAG_N != 0
}

cpu_flag_h :: proc(cpu: ^Cpu) -> bool {
	return cpu.f & FLAG_H != 0
}

cpu_flag_c :: proc(cpu: ^Cpu) -> bool {
	return cpu.f & FLAG_C != 0
}

// cpu_reset はブート ROM 完了直後のレジスタ状態を直接セットする
// (実 BIOS は読み込まない。references.md の表を参照)。
cpu_reset :: proc(cpu: ^Cpu, mode: Console_Mode) {
	switch mode {
	case .DMG:
		cpu_set_af(cpu, 0x01B0)
		cpu_set_bc(cpu, 0x0013)
		cpu_set_de(cpu, 0x00D8)
		cpu_set_hl(cpu, 0x014D)
	case .CGB:
		cpu_set_af(cpu, 0x1180)
		cpu_set_bc(cpu, 0x0000)
		cpu_set_de(cpu, 0xFF56)
		cpu_set_hl(cpu, 0x000D)
	}
	cpu.sp = 0xFFFE
	cpu.pc = 0x0100
	cpu.ime = false
	cpu.halted = false
	cpu.stopped = false
	cpu.illegal_opcode_hit = false
}

@(private)
cpu_log_illegal :: proc(cpu: ^Cpu, opcode: u8) {
	fmt.eprintfln("cpu: illegal opcode 0x%02X at pc=0x%04X", opcode, cpu.pc)
	cpu.illegal_opcode_hit = true
	cpu.stopped = true
}

@(private)
cpu_log_unimplemented :: proc(cpu: ^Cpu, opcode: u8) {
	fmt.eprintfln("cpu: unimplemented opcode 0x%02X at pc=0x%04X", opcode, cpu.pc)
	cpu.stopped = true
}

// --- フェッチヘルパー ---

@(private)
read_imm8 :: proc(cpu: ^Cpu, bus: ^Bus) -> u8 {
	v := cpu_read8(cpu, bus, cpu.pc)
	cpu.pc += 1
	return v
}

@(private)
read_imm16 :: proc(cpu: ^Cpu, bus: ^Bus) -> u16 {
	lo := read_imm8(cpu, bus)
	hi := read_imm8(cpu, bus)
	return u16(hi) << 8 | u16(lo)
}

// --- r8 インデックス(0=B,1=C,2=D,3=E,4=H,5=L,6=(HL),7=A) ---

@(private)
r8_get :: proc(cpu: ^Cpu, bus: ^Bus, idx: u8) -> u8 {
	switch idx {
	case 0:
		return cpu.b
	case 1:
		return cpu.c
	case 2:
		return cpu.d
	case 3:
		return cpu.e
	case 4:
		return cpu.h
	case 5:
		return cpu.l
	case 6:
		return cpu_read8(cpu, bus, cpu_hl(cpu))
	case:
		return cpu.a
	}
}

@(private)
r8_set :: proc(cpu: ^Cpu, bus: ^Bus, idx: u8, v: u8) {
	switch idx {
	case 0:
		cpu.b = v
	case 1:
		cpu.c = v
	case 2:
		cpu.d = v
	case 3:
		cpu.e = v
	case 4:
		cpu.h = v
	case 5:
		cpu.l = v
	case 6:
		cpu_write8(cpu, bus, cpu_hl(cpu), v)
	case:
		cpu.a = v
	}
}

// --- 8bit ALU ヘルパー ---
// INC/DEC はキャリーフラグを変更しない。ADD/ADC/SUB/SBC/CP はキャリーも更新する。

@(private)
alu_add :: proc(cpu: ^Cpu, v: u8, carry_in: u8) {
	a := cpu.a
	sum := int(a) + int(v) + int(carry_in)
	h := (a & 0xF) + (v & 0xF) + carry_in > 0xF
	cpu.a = u8(sum)
	cpu_set_flags(cpu, cpu.a == 0, false, h, sum > 0xFF)
}

@(private)
alu_sub :: proc(cpu: ^Cpu, v: u8, carry_in: u8, store: bool) {
	a := cpu.a
	diff := int(a) - int(v) - int(carry_in)
	h := (int(a & 0xF) - int(v & 0xF) - int(carry_in)) < 0
	c := diff < 0
	result := u8(diff)
	cpu_set_flags(cpu, result == 0, true, h, c)
	if store {
		cpu.a = result
	}
}

@(private)
alu_and :: proc(cpu: ^Cpu, v: u8) {
	cpu.a &= v
	cpu_set_flags(cpu, cpu.a == 0, false, true, false)
}

@(private)
alu_or :: proc(cpu: ^Cpu, v: u8) {
	cpu.a |= v
	cpu_set_flags(cpu, cpu.a == 0, false, false, false)
}

@(private)
alu_xor :: proc(cpu: ^Cpu, v: u8) {
	cpu.a ~= v
	cpu_set_flags(cpu, cpu.a == 0, false, false, false)
}

@(private)
alu_inc8 :: proc(cpu: ^Cpu, v: u8) -> u8 {
	result := v + 1
	h := (v & 0xF) + 1 > 0xF
	cpu_set_flags(cpu, result == 0, false, h, cpu_flag_c(cpu))
	return result
}

@(private)
alu_dec8 :: proc(cpu: ^Cpu, v: u8) -> u8 {
	result := v - 1
	h := (v & 0xF) == 0
	cpu_set_flags(cpu, result == 0, true, h, cpu_flag_c(cpu))
	return result
}

// cpu_step は 1 命令(または割り込み処理、フェーズ2)を実行し、
// 消費した T-cycle 数を返す。実測は bus.cycles の差分で行うため、
// 各オペコードの実装が正しく cpu_read8/cpu_write8/bus_tick を呼べば
// 自動的に命令表どおりのサイクル数になる。
cpu_step :: proc(cpu: ^Cpu, bus: ^Bus) -> int {
	start := bus.cycles

	if cpu.halted {
		bus_tick(bus, 4)
		return int(bus.cycles - start)
	}

	opcode := cpu_read8(cpu, bus, cpu.pc)
	cpu.pc += 1
	cpu_execute(cpu, bus, opcode)

	return int(bus.cycles - start)
}

@(private)
cpu_execute :: proc(cpu: ^Cpu, bus: ^Bus, opcode: u8) {
	switch opcode {
	case 0x00:
	// NOP

	// --- LD r,d8 ---
	case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x3E:
		dst := (opcode >> 3) & 7
		v := read_imm8(cpu, bus)
		r8_set(cpu, bus, dst, v)
	case 0x36:
		v := read_imm8(cpu, bus)
		cpu_write8(cpu, bus, cpu_hl(cpu), v)

	// --- INC r / DEC r (8bit) ---
	case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
		idx := (opcode >> 3) & 7
		v := r8_get(cpu, bus, idx)
		r8_set(cpu, bus, idx, alu_inc8(cpu, v))
	case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
		idx := (opcode >> 3) & 7
		v := r8_get(cpu, bus, idx)
		r8_set(cpu, bus, idx, alu_dec8(cpu, v))

	case:
		if opcode >= 0x40 && opcode <= 0x7F {
			// --- LD r,r' (0x76 は HALT、T1-6 で実装) ---
			dst := (opcode >> 3) & 7
			src := opcode & 7
			v := r8_get(cpu, bus, src)
			r8_set(cpu, bus, dst, v)
		} else if opcode >= 0x80 && opcode <= 0xBF {
			// --- ALU A,r ---
			op := (opcode >> 3) & 7
			src := opcode & 7
			v := r8_get(cpu, bus, src)
			cpu_alu_op(cpu, op, v)
		} else if opcode == 0xC6 || opcode == 0xCE || opcode == 0xD6 || opcode == 0xDE ||
			opcode == 0xE6 || opcode == 0xEE || opcode == 0xF6 || opcode == 0xFE {
			// --- ALU A,d8 ---
			op := (opcode >> 3) & 7
			v := read_imm8(cpu, bus)
			cpu_alu_op(cpu, op, v)
		} else {
			cpu_log_unimplemented(cpu, opcode)
		}
	}
}

// cpu_alu_op は ADD/ADC/SUB/SBC/AND/XOR/OR/CP(op=0..7) を A に対して実行する。
@(private)
cpu_alu_op :: proc(cpu: ^Cpu, op: u8, v: u8) {
	switch op {
	case 0:
		alu_add(cpu, v, 0)
	case 1:
		alu_add(cpu, v, cpu_flag_c(cpu) ? 1 : 0)
	case 2:
		alu_sub(cpu, v, 0, true)
	case 3:
		alu_sub(cpu, v, cpu_flag_c(cpu) ? 1 : 0, true)
	case 4:
		alu_and(cpu, v)
	case 5:
		alu_xor(cpu, v)
	case 6:
		alu_or(cpu, v)
	case:
		alu_sub(cpu, v, 0, false) // CP
	}
}
