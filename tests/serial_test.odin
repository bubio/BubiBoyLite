package tests

import "core:testing"
import core "bbl:core"

@(test)
test_serial_captures_byte_on_sc_0x81 :: proc(t: ^testing.T) {
	bus: core.Bus
	defer delete(bus.serial_log)
	core.bus_write(&bus, 0xFF01, u8('H'))
	core.bus_write(&bus, 0xFF02, 0x81)
	testing.expect(t, core.serial_get_log(&bus) == "H")
}

@(test)
test_serial_sc_bit7_cleared_after_transfer :: proc(t: ^testing.T) {
	bus: core.Bus
	defer delete(bus.serial_log)
	core.bus_write(&bus, 0xFF01, u8('X'))
	core.bus_write(&bus, 0xFF02, 0x81)
	testing.expect(t, core.bus_read(&bus, 0xFF02) & 0x80 == 0, "転送完了で bit7 はクリアされる")
}

@(test)
test_serial_captures_multiple_bytes_in_order :: proc(t: ^testing.T) {
	bus: core.Bus
	defer delete(bus.serial_log)
	msg := "Hi!"
	for ch in msg {
		core.bus_write(&bus, 0xFF01, u8(ch))
		core.bus_write(&bus, 0xFF02, 0x81)
	}
	testing.expect(t, core.serial_get_log(&bus) == "Hi!")
}

@(test)
test_serial_write_without_transfer_bit_is_not_captured :: proc(t: ^testing.T) {
	bus: core.Bus
	defer delete(bus.serial_log)
	core.bus_write(&bus, 0xFF01, u8('Z'))
	core.bus_write(&bus, 0xFF02, 0x01) // bit7無し(内部クロックのみ)は転送開始でない
	testing.expect(t, len(bus.serial_log) == 0, "bit7無しの書き込みではキャプチャされない")
}
