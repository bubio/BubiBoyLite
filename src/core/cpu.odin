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
