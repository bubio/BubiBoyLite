package core

// シリアル出力キャプチャ(T1-7)。
// Blargg テストの結果判定経路: 0xFF01(SB)に書かれたバイトを、
// 0xFF02(SC)に 0x81(bit7=転送開始, bit0=内部クロック)が書かれたタイミングで
// serial_log に追記し、SC の bit7(転送中フラグ)をクリアする。
// 転送完了割り込み(IF bit3)は未実装(Blargg は使わない。フェーズ2で接続)。

SERIAL_SB :: 0xFF01
SERIAL_SC :: 0xFF02

// serial_write は bus_io_write から FF01/FF02 宛の書き込みを受け取る。
@(private)
serial_write :: proc(bus: ^Bus, addr: u16, value: u8) {
	switch addr {
	case SERIAL_SB:
		bus.io[SERIAL_SB - 0xFF00] = value
	case SERIAL_SC:
		if value & 0x81 == 0x81 {
			sb := bus.io[SERIAL_SB - 0xFF00]
			append(&bus.serial_log, sb)
			bus.io[SERIAL_SC - 0xFF00] = value & ~u8(0x80) // 転送完了: bit7クリア
		} else {
			bus.io[SERIAL_SC - 0xFF00] = value
		}
	}
}

// serial_get_log は現在までにキャプチャされたシリアル出力を文字列として返す。
// 返す string は bus.serial_log のバッキング配列を指すため、呼び出し側で
// bus.serial_log を delete するまでの間のみ有効。
serial_get_log :: proc(bus: ^Bus) -> string {
	return string(bus.serial_log[:])
}
