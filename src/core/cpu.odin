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

// --- rp16 インデックス(0=BC,1=DE,2=HL,3=SP) ---

@(private)
rp_get :: proc(cpu: ^Cpu, idx: u8) -> u16 {
	switch idx {
	case 0:
		return cpu_bc(cpu)
	case 1:
		return cpu_de(cpu)
	case 2:
		return cpu_hl(cpu)
	case:
		return cpu.sp
	}
}

@(private)
rp_set :: proc(cpu: ^Cpu, idx: u8, v: u16) {
	switch idx {
	case 0:
		cpu_set_bc(cpu, v)
	case 1:
		cpu_set_de(cpu, v)
	case 2:
		cpu_set_hl(cpu, v)
	case:
		cpu.sp = v
	}
}

// --- rp2 インデックス(PUSH/POP 用。0=BC,1=DE,2=HL,3=AF) ---

@(private)
rp2_get :: proc(cpu: ^Cpu, idx: u8) -> u16 {
	if idx == 3 {
		return cpu_af(cpu)
	}
	return rp_get(cpu, idx)
}

@(private)
rp2_set :: proc(cpu: ^Cpu, idx: u8, v: u16) {
	if idx == 3 {
		cpu_set_af(cpu, v) // F の下位4bitマスクは cpu_set_af が担当
		return
	}
	rp_set(cpu, idx, v)
}

// --- 条件コード(0=NZ,1=Z,2=NC,3=C) ---

@(private)
cc_test :: proc(cpu: ^Cpu, idx: u8) -> bool {
	switch idx {
	case 0:
		return !cpu_flag_z(cpu)
	case 1:
		return cpu_flag_z(cpu)
	case 2:
		return !cpu_flag_c(cpu)
	case:
		return cpu_flag_c(cpu)
	}
}

// --- スタック操作 ---

@(private)
push16 :: proc(cpu: ^Cpu, bus: ^Bus, v: u16) {
	cpu.sp -= 1
	cpu_write8(cpu, bus, cpu.sp, u8(v >> 8))
	cpu.sp -= 1
	cpu_write8(cpu, bus, cpu.sp, u8(v))
}

@(private)
pop16 :: proc(cpu: ^Cpu, bus: ^Bus) -> u16 {
	lo := cpu_read8(cpu, bus, cpu.sp)
	cpu.sp += 1
	hi := cpu_read8(cpu, bus, cpu.sp)
	cpu.sp += 1
	return u16(hi) << 8 | u16(lo)
}

// sp_add_offset は ADD SP,e8 / LD HL,SP+e8 共通のフラグ計算。
// Z=0, N=0 固定。H/C は SP の下位バイトに符号なしの e8 を加算した結果の桁上がりで決まる
// (符号付き 16bit 加算の結果とは別に、下位バイト基準で判定するのが仕様)。
@(private)
sp_add_offset :: proc(cpu: ^Cpu, bus: ^Bus) -> u16 {
	e8 := read_imm8(cpu, bus)
	offset := i16(i8(e8))
	sp := cpu.sp
	e8u := u16(e8)
	h := (sp & 0xF) + (e8u & 0xF) > 0xF
	c := (sp & 0xFF) + (e8u & 0xFF) > 0xFF
	cpu_set_flags(cpu, false, false, h, c)
	return u16(i32(sp) + i32(offset))
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

	// --- 16bit ロード ---
	case 0x01, 0x11, 0x21, 0x31:
		idx := (opcode >> 4) & 3
		rp_set(cpu, idx, read_imm16(cpu, bus))
	case 0x02:
		cpu_write8(cpu, bus, cpu_bc(cpu), cpu.a)
	case 0x12:
		cpu_write8(cpu, bus, cpu_de(cpu), cpu.a)
	case 0x22:
		hl := cpu_hl(cpu)
		cpu_write8(cpu, bus, hl, cpu.a)
		cpu_set_hl(cpu, hl + 1)
	case 0x32:
		hl := cpu_hl(cpu)
		cpu_write8(cpu, bus, hl, cpu.a)
		cpu_set_hl(cpu, hl - 1)
	case 0x0A:
		cpu.a = cpu_read8(cpu, bus, cpu_bc(cpu))
	case 0x1A:
		cpu.a = cpu_read8(cpu, bus, cpu_de(cpu))
	case 0x2A:
		hl := cpu_hl(cpu)
		cpu.a = cpu_read8(cpu, bus, hl)
		cpu_set_hl(cpu, hl + 1)
	case 0x3A:
		hl := cpu_hl(cpu)
		cpu.a = cpu_read8(cpu, bus, hl)
		cpu_set_hl(cpu, hl - 1)
	case 0x08:
		addr := read_imm16(cpu, bus)
		cpu_write8(cpu, bus, addr, u8(cpu.sp))
		cpu_write8(cpu, bus, addr + 1, u8(cpu.sp >> 8))
	case 0xF9:
		bus_tick(bus, 4) // internal
		cpu.sp = cpu_hl(cpu)

	// --- 16bit INC/DEC(フラグ無影響、内部+4サイクル) ---
	case 0x03, 0x13, 0x23, 0x33:
		idx := (opcode >> 4) & 3
		rp_set(cpu, idx, rp_get(cpu, idx) + 1)
		bus_tick(bus, 4)
	case 0x0B, 0x1B, 0x2B, 0x3B:
		idx := (opcode >> 4) & 3
		rp_set(cpu, idx, rp_get(cpu, idx) - 1)
		bus_tick(bus, 4)

	// --- ADD HL,rr ---
	case 0x09, 0x19, 0x29, 0x39:
		idx := (opcode >> 4) & 3
		hl := cpu_hl(cpu)
		v := rp_get(cpu, idx)
		sum := int(hl) + int(v)
		h := (hl & 0xFFF) + (v & 0xFFF) > 0xFFF
		cpu_set_flags(cpu, cpu_flag_z(cpu), false, h, sum > 0xFFFF)
		cpu_set_hl(cpu, u16(sum))
		bus_tick(bus, 4)

	// --- ADD SP,e8 / LD HL,SP+e8 ---
	case 0xE8:
		result := sp_add_offset(cpu, bus)
		bus_tick(bus, 4)
		bus_tick(bus, 4)
		cpu.sp = result
	case 0xF8:
		result := sp_add_offset(cpu, bus)
		bus_tick(bus, 4)
		cpu_set_hl(cpu, result)

	// --- PUSH/POP ---
	case 0xC1, 0xD1, 0xE1, 0xF1:
		idx := (opcode >> 4) & 3
		rp2_set(cpu, idx, pop16(cpu, bus))
	case 0xC5, 0xD5, 0xE5, 0xF5:
		idx := (opcode >> 4) & 3
		bus_tick(bus, 4) // internal
		push16(cpu, bus, rp2_get(cpu, idx))

	// --- RET / RETI ---
	case 0xC0, 0xD0, 0xC8, 0xD8:
		idx := (opcode >> 3) & 3
		bus_tick(bus, 4) // 条件チェック用の内部サイクル
		if cc_test(cpu, idx) {
			cpu.pc = pop16(cpu, bus)
			bus_tick(bus, 4)
		}
	case 0xC9:
		cpu.pc = pop16(cpu, bus)
		bus_tick(bus, 4)
	case 0xD9:
		cpu.pc = pop16(cpu, bus)
		bus_tick(bus, 4)
		cpu.ime = true

	// --- JP ---
	case 0xC2, 0xD2, 0xCA, 0xDA:
		idx := (opcode >> 3) & 3
		addr := read_imm16(cpu, bus)
		if cc_test(cpu, idx) {
			cpu.pc = addr
			bus_tick(bus, 4)
		}
	case 0xC3:
		addr := read_imm16(cpu, bus)
		cpu.pc = addr
		bus_tick(bus, 4)
	case 0xE9:
		cpu.pc = cpu_hl(cpu) // メモリアクセスなし、内部サイクルもなし(4=フェッチのみ)

	// --- JR ---
	case 0x20, 0x30, 0x28, 0x38:
		idx := (opcode >> 3) & 3
		e8 := read_imm8(cpu, bus)
		if cc_test(cpu, idx) {
			offset := i16(i8(e8))
			cpu.pc = u16(i32(cpu.pc) + i32(offset))
			bus_tick(bus, 4)
		}
	case 0x18:
		e8 := read_imm8(cpu, bus)
		offset := i16(i8(e8))
		cpu.pc = u16(i32(cpu.pc) + i32(offset))
		bus_tick(bus, 4)

	// --- CALL ---
	case 0xC4, 0xD4, 0xCC, 0xDC:
		idx := (opcode >> 3) & 3
		addr := read_imm16(cpu, bus)
		if cc_test(cpu, idx) {
			bus_tick(bus, 4) // internal
			push16(cpu, bus, cpu.pc)
			cpu.pc = addr
		}
	case 0xCD:
		addr := read_imm16(cpu, bus)
		bus_tick(bus, 4) // internal
		push16(cpu, bus, cpu.pc)
		cpu.pc = addr

	// --- RST ---
	case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF:
		vector := u16(opcode & 0x38)
		bus_tick(bus, 4) // internal
		push16(cpu, bus, cpu.pc)
		cpu.pc = vector

	// --- LDH / (C) / (a16) 経由の A ロード ---
	case 0xE0:
		addr := u16(0xFF00) + u16(read_imm8(cpu, bus))
		cpu_write8(cpu, bus, addr, cpu.a)
	case 0xF0:
		addr := u16(0xFF00) + u16(read_imm8(cpu, bus))
		cpu.a = cpu_read8(cpu, bus, addr)
	case 0xE2:
		cpu_write8(cpu, bus, u16(0xFF00) + u16(cpu.c), cpu.a)
	case 0xF2:
		cpu.a = cpu_read8(cpu, bus, u16(0xFF00) + u16(cpu.c))
	case 0xEA:
		addr := read_imm16(cpu, bus)
		cpu_write8(cpu, bus, addr, cpu.a)
	case 0xFA:
		addr := read_imm16(cpu, bus)
		cpu.a = cpu_read8(cpu, bus, addr)

	// --- CB プレフィックス ---
	case 0xCB:
		cb_opcode := cpu_read8(cpu, bus, cpu.pc)
		cpu.pc += 1
		cpu_execute_cb(cpu, bus, cb_opcode)

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

// --- CB プレフィックス命令(T1-5) ---
// レイアウト: bit7-6=グループ(0=回転/シフト,1=BIT,2=RES,3=SET)
//            bit5-3=サブオペレーション or ビット番号
//            bit2-0=r8 インデックス(6=(HL))
// サイクル数は r8_get/r8_set が (HL) の場合に自動で cpu_read8/cpu_write8 を
// 呼ぶことで、命令表どおりの値が自然に出る(非(HL): 8、(HL) BIT: 12、(HL) 他: 16)。

@(private)
cpu_execute_cb :: proc(cpu: ^Cpu, bus: ^Bus, opcode: u8) {
	group := opcode >> 6
	op := (opcode >> 3) & 7
	idx := opcode & 7

	switch group {
	case 0:
		v := r8_get(cpu, bus, idx)
		r8_set(cpu, bus, idx, cb_rotate_shift(cpu, op, v))
	case 1:
		v := r8_get(cpu, bus, idx)
		bit := v & (1 << op) != 0
		cpu.f = (cpu.f & FLAG_C) | FLAG_H | (bit ? 0 : FLAG_Z)
	case 2:
		v := r8_get(cpu, bus, idx)
		r8_set(cpu, bus, idx, v & ~(u8(1) << op))
	case:
		v := r8_get(cpu, bus, idx)
		r8_set(cpu, bus, idx, v | (u8(1) << op))
	}
}

// cb_rotate_shift は RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL(op=0..7) を実行し、結果を返す。
// 通常のフラグ規則で Z を設定する(非CB版の RLCA 等とは異なり Z=0 固定にしない)。
@(private)
cb_rotate_shift :: proc(cpu: ^Cpu, op: u8, v: u8) -> u8 {
	result: u8
	carry_out: bool

	switch op {
	case 0: // RLC
		carry_out = v & 0x80 != 0
		result = (v << 1) | (carry_out ? 1 : 0)
	case 1: // RRC
		carry_out = v & 0x01 != 0
		result = (v >> 1) | (carry_out ? 0x80 : 0)
	case 2: // RL
		carry_out = v & 0x80 != 0
		result = (v << 1) | (cpu_flag_c(cpu) ? 1 : 0)
	case 3: // RR
		carry_out = v & 0x01 != 0
		result = (v >> 1) | (cpu_flag_c(cpu) ? 0x80 : 0)
	case 4: // SLA
		carry_out = v & 0x80 != 0
		result = v << 1
	case 5: // SRA (符号ビット保持)
		carry_out = v & 0x01 != 0
		result = (v >> 1) | (v & 0x80)
	case 6: // SWAP
		result = (v << 4) | (v >> 4)
		carry_out = false
	case:
		// SRL
		carry_out = v & 0x01 != 0
		result = v >> 1
	}

	cpu_set_flags(cpu, result == 0, false, false, carry_out)
	return result
}
