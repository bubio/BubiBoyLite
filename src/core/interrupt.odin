package core

// IF(0xFF0F)/IE(0xFFFF) と割り込みディスパッチ(T2-1)。
// 参照: ~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Interrupt.fs、Pan Docs "Interrupts"。

// Interrupt は割り込み種別。優先度はこの並び順(ビット番号の小さい順)。
Interrupt :: enum {
	VBlank,
	Stat,
	Timer,
	Serial,
	Joypad,
}

// IF/IE のビット位置。
INT_VBLANK_BIT :: 0x01
INT_STAT_BIT :: 0x02
INT_TIMER_BIT :: 0x04
INT_SERIAL_BIT :: 0x08
INT_JOYPAD_BIT :: 0x10

// interrupt_bit は Interrupt enum を対応する IF/IE ビットへ変換する。
interrupt_bit :: proc(i: Interrupt) -> u8 {
	switch i {
	case .VBlank:
		return INT_VBLANK_BIT
	case .Stat:
		return INT_STAT_BIT
	case .Timer:
		return INT_TIMER_BIT
	case .Serial:
		return INT_SERIAL_BIT
	case .Joypad:
		return INT_JOYPAD_BIT
	}
	return 0
}

@(private)
interrupt_vector_for_bit :: proc(bit: u8) -> u16 {
	switch bit {
	case INT_VBLANK_BIT:
		return 0x0040
	case INT_STAT_BIT:
		return 0x0048
	case INT_TIMER_BIT:
		return 0x0050
	case INT_SERIAL_BIT:
		return 0x0058
	case:
		return 0x0060 // Joypad
	}
}

// interrupt_request は IF レジスタに該当ビットを立てる
// (timer/joypad/serial/ppu から呼ばれる想定)。
interrupt_request :: proc(bus: ^Bus, i: Interrupt) {
	bus.io[IF_ADDR - 0xFF00] |= interrupt_bit(i)
}

// interrupt_pending は IME を無視して IE & IF & 0x1F を返す
// (HALT の起床判定・ディスパッチ判定の両方で使う)。
interrupt_pending :: proc(bus: ^Bus) -> u8 {
	return bus.ie & bus.io[IF_ADDR - 0xFF00] & 0x1F
}

// cpu_dispatch_interrupt は割り込みハンドラへのディスパッチを 20 T-cycle かけて行う:
// 内部 2 M(認識) → PC 上位バイト PUSH(IE を潰しうる) → この時点の IE&IF でベクタ決定・
// 対応する IF bit クリア → PC 下位バイト PUSH → 内部 1 M(ジャンプ相当)。
//
// Mooneye ie_push (acceptance/interrupts/ie_push.s) が検査する実機の挙動:
// SP が 0xFFFF 付近を指していると PUSH 自体が IE(0xFFFF) を書き換える。
// - 上位バイト書き込みが IE を潰す場合: ベクタ決定はこの書き込み**直後**に行われるため、
//   決定時点でもう割り込みが成立しなくなっていればディスパッチはキャンセルされ、
//   IF bit はクリアされず PC は 0x0000 へ飛ぶ(それでも IME はクリアされたまま)。
// - 下位バイト書き込みが IE を潰す場合: ベクタは既に決定済みのため手遅れで、
//   ディスパッチは通常どおり進む。
@(private)
cpu_dispatch_interrupt :: proc(cpu: ^Cpu, bus: ^Bus) {
	bus_tick(bus, 4) // 内部 1
	bus_tick(bus, 4) // 内部 2
	cpu.ime = false

	pc := cpu.pc
	cpu.sp -= 1
	cpu_write8(cpu, bus, cpu.sp, u8(pc >> 8)) // 上位バイト(IE を潰しうる)

	vector: u16 = 0x0000 // 対象なし: キャンセルされ 0x0000 へ(実機のIE書き換えバグ)
	pending := interrupt_pending(bus)
	bits := [5]u8{INT_VBLANK_BIT, INT_STAT_BIT, INT_TIMER_BIT, INT_SERIAL_BIT, INT_JOYPAD_BIT}
	for bit in bits {
		if pending & bit != 0 {
			vector = interrupt_vector_for_bit(bit)
			bus.io[IF_ADDR - 0xFF00] &= ~bit
			break
		}
	}

	cpu.sp -= 1
	cpu_write8(cpu, bus, cpu.sp, u8(pc)) // 下位バイト(この時点での書き換えはもう手遅れ)

	bus_tick(bus, 4) // ジャンプ相当の内部サイクル
	cpu.pc = vector
}
