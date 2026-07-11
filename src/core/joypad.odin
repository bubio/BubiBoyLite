package core

// JOYP(0xFF00)とボタン入力状態(T2-4)。
// 参照: ~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Joypad.fs、Pan Docs "Joypad Input"。
//
// JOYP は負論理: 0=選択/押下、1=非選択/非押下。bit5=0でアクション(A/B/Select/Start)を
// bit3-0に反映、bit4=0で方向キー(Right/Left/Up/Down)をbit3-0に反映。両方選択時は
// 両グループのANDが出力される。上位2bitは常に1で読める。

JOYP_ADDR :: 0xFF00

Button :: enum {
	Right,
	Left,
	Up,
	Down,
	A,
	B,
	Select,
	Start,
}

@(private)
button_bit :: proc(b: Button) -> u8 {
	return u8(1) << u8(b)
}

// joypad_set_button はボタンの押下状態を更新する。選択中のグループのボタンが
// 0(非押下)→1(押下)に変化したとき joypad 割り込み(IF bit4)を要求する。
joypad_set_button :: proc(bus: ^Bus, button: Button, pressed: bool) {
	bit := button_bit(button)
	was_pressed := bus.joyp_pressed & bit != 0

	if pressed {
		bus.joyp_pressed |= bit
	} else {
		bus.joyp_pressed &= ~bit
	}

	if pressed && !was_pressed && joypad_button_group_selected(bus, button) {
		interrupt_request(bus, .Joypad)
	}
}

@(private)
joypad_button_group_selected :: proc(bus: ^Bus, button: Button) -> bool {
	switch button {
	case .A, .B, .Select, .Start:
		return bus.joyp_select_action
	case .Right, .Left, .Up, .Down:
		return bus.joyp_select_direction
	}
	return false
}

// joypad_write_p1 は JOYP への書き込みを処理する: bit5/bit4 だけが意味を持つ
// (0=選択)。bit3-0 への書き込みは無視される(読み取り専用)。
joypad_write_p1 :: proc(bus: ^Bus, value: u8) {
	bus.joyp_select_action = value & 0x20 == 0
	bus.joyp_select_direction = value & 0x10 == 0
}

// joypad_read_p1 は JOYP の現在値を負論理エンコーディングで返す。
joypad_read_p1 :: proc(bus: ^Bus) -> u8 {
	select_bits: u8 = 0xC0 // 上位2bitは常に1
	if !bus.joyp_select_action {
		select_bits |= 0x20
	}
	if !bus.joyp_select_direction {
		select_bits |= 0x10
	}

	action_bits: u8 = 0x0F
	if bus.joyp_select_action {
		if bus.joyp_pressed & button_bit(.A) != 0 {
			action_bits &= ~u8(0x01)
		}
		if bus.joyp_pressed & button_bit(.B) != 0 {
			action_bits &= ~u8(0x02)
		}
		if bus.joyp_pressed & button_bit(.Select) != 0 {
			action_bits &= ~u8(0x04)
		}
		if bus.joyp_pressed & button_bit(.Start) != 0 {
			action_bits &= ~u8(0x08)
		}
	}

	direction_bits: u8 = 0x0F
	if bus.joyp_select_direction {
		if bus.joyp_pressed & button_bit(.Right) != 0 {
			direction_bits &= ~u8(0x01)
		}
		if bus.joyp_pressed & button_bit(.Left) != 0 {
			direction_bits &= ~u8(0x02)
		}
		if bus.joyp_pressed & button_bit(.Up) != 0 {
			direction_bits &= ~u8(0x04)
		}
		if bus.joyp_pressed & button_bit(.Down) != 0 {
			direction_bits &= ~u8(0x08)
		}
	}

	return select_bits | (action_bits & direction_bits)
}
