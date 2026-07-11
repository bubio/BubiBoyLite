package tests

import "core:testing"
import core "bbl:core"

// JOYP(0xFF00)とボタン入力の単体テスト(T2-4)。

@(test)
test_joypad_unselected_reads_all_high :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x30) // bit5=1,bit4=1: どちらも非選択
	core.joypad_set_button(&bus, .A, true)
	core.joypad_set_button(&bus, .Right, true)
	testing.expect(t, core.bus_read(&bus, 0xFF00) == 0xFF, "非選択時は下位4bitが全て1")
}

@(test)
test_joypad_action_group_reflects_pressed_buttons :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x10) // bit5=0(アクション選択), bit4=1(方向非選択)
	core.joypad_set_button(&bus, .A, true)
	core.joypad_set_button(&bus, .Start, true)

	v := core.bus_read(&bus, 0xFF00)
	testing.expect(t, v & 0x01 == 0, "Aが押されているのでbit0は0")
	testing.expect(t, v & 0x08 == 0, "Startが押されているのでbit3は0")
	testing.expect(t, v & 0x02 != 0, "Bは押されていないのでbit1は1")
	testing.expect(t, v & 0x04 != 0, "Selectは押されていないのでbit2は1")
}

@(test)
test_joypad_direction_group_reflects_pressed_buttons :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x20) // bit5=1(アクション非選択), bit4=0(方向選択)
	core.joypad_set_button(&bus, .Down, true)

	v := core.bus_read(&bus, 0xFF00)
	testing.expect(t, v & 0x08 == 0, "Downが押されているのでbit3は0")
	testing.expect(t, v & 0x01 != 0 && v & 0x02 != 0 && v & 0x04 != 0)
}

@(test)
test_joypad_both_groups_selected_is_and_combined :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x00) // 両方選択
	core.joypad_set_button(&bus, .A, true) // bit0側(アクション)
	core.joypad_set_button(&bus, .Left, true) // bit1側(方向)

	v := core.bus_read(&bus, 0xFF00)
	testing.expect(t, v & 0x01 == 0, "アクション側のAでbit0が0")
	testing.expect(t, v & 0x02 == 0, "方向側のLeftでbit1も0(AND合成)")
	testing.expect(t, v & 0x04 != 0 && v & 0x08 != 0, "押されていないビットは1のまま")
}

@(test)
test_joypad_select_bits_readback :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x10) // アクション選択
	testing.expect(t, core.bus_read(&bus, 0xFF00) & 0x30 == 0x10, "bit5=0固定で読める(選択状態が反映)")
	testing.expect(t, core.bus_read(&bus, 0xFF00) & 0xC0 == 0xC0, "上位2bitは常に1")
}

@(test)
test_joypad_press_while_selected_requests_interrupt :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x10) // アクション選択
	core.bus_write(&bus, 0xFF0F, 0x00) // IF クリア

	core.joypad_set_button(&bus, .A, true)

	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x10 != 0, "選択中のボタン押下でIF bit4が立つ")
}

@(test)
test_joypad_press_while_not_selected_does_not_request_interrupt :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x20) // 方向のみ選択(アクション非選択)
	core.bus_write(&bus, 0xFF0F, 0x00)

	core.joypad_set_button(&bus, .A, true) // アクション側は非選択中

	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x10 == 0, "非選択グループのボタンは割り込みを起こさない")
}

@(test)
test_joypad_release_does_not_request_interrupt :: proc(t: ^testing.T) {
	bus: core.Bus
	core.bus_write(&bus, 0xFF00, 0x10)
	core.joypad_set_button(&bus, .A, true)
	core.bus_write(&bus, 0xFF0F, 0x00) // 押下による分をクリアしてから離す

	core.joypad_set_button(&bus, .A, false)

	testing.expect(t, core.bus_read(&bus, 0xFF0F) & 0x10 == 0, "離す操作では割り込みが起きない")
}
