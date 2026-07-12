package tests

import "core:testing"
import app "bbl:app"
import sdl "vendor:sdl2"

// src/app/input.odin のセーブステートショートカット判定(T7-4)の単体テスト。
// input_handle_shortcut_key は純粋関数(SDLウィンドウ/オーディオ非依存)なので、
// KeyboardEvent を直接組み立てて検証できる。

@(private = "file")
make_key_event :: proc(sym: sdl.Keycode, repeat: u8 = 0) -> sdl.KeyboardEvent {
	return sdl.KeyboardEvent{keysym = sdl.Keysym{sym = sym}, repeat = repeat}
}

@(test)
test_input_state_default_slot_is_1 :: proc(t: ^testing.T) {
	state := app.input_state_default()
	testing.expect(t, state.state_slot == 1)
}

@(test)
test_shortcut_f1_to_f4_select_slot :: proc(t: ^testing.T) {
	state := app.input_state_default()

	action := app.input_handle_shortcut_key(&state, make_key_event(.F3))
	testing.expect(t, action == .Select_Slot)
	testing.expect(t, state.state_slot == 3)

	action2 := app.input_handle_shortcut_key(&state, make_key_event(.F1))
	testing.expect(t, action2 == .Select_Slot)
	testing.expect(t, state.state_slot == 1)
}

@(test)
test_shortcut_f5_requests_save_without_changing_slot :: proc(t: ^testing.T) {
	state := app.input_state_default()
	state.state_slot = 2

	action := app.input_handle_shortcut_key(&state, make_key_event(.F5))
	testing.expect(t, action == .Save_State)
	testing.expect(t, state.state_slot == 2, "F5はスロットを変更しないはず")
}

@(test)
test_shortcut_f7_requests_load_without_changing_slot :: proc(t: ^testing.T) {
	state := app.input_state_default()
	state.state_slot = 4

	action := app.input_handle_shortcut_key(&state, make_key_event(.F7))
	testing.expect(t, action == .Load_State)
	testing.expect(t, state.state_slot == 4)
}

@(test)
test_shortcut_unrelated_key_returns_none :: proc(t: ^testing.T) {
	state := app.input_state_default()
	action := app.input_handle_shortcut_key(&state, make_key_event(.z))
	testing.expect(t, action == .None)
}

@(test)
test_shortcut_key_repeat_is_ignored :: proc(t: ^testing.T) {
	state := app.input_state_default()
	action := app.input_handle_shortcut_key(&state, make_key_event(.F5, 1))
	testing.expect(t, action == .None, "キーリピートは無視するはず")
}
