package tests

import "core:testing"
import app "bbl:app"
import core "bbl:core"
import sdl "vendor:sdl2"

// src/app/input.odin のゲームコントローラー対応(T8-5)の単体テスト。
// SDL_Init/GameControllerOpen等の実デバイス依存部分は除き、イベント→GBボタンの変換ロジック
// (純粋関数、および core.Emulator を使った統合)のみを検証する。実コントローラーでの
// 動作確認はハードウェアが無いため未確認(phase-08-frontend.md 検証ログに明記する)。

@(test)
test_controller_button_to_gb_button_default_mapping :: proc(t: ^testing.T) {
	pad_map := app.default_pad_map()

	// Nintendo配置に合わせSDLのB=GBのA、SDLのA=GBのB(phase-08「落とし穴」)。
	b, ok := app.controller_button_to_gb_button(pad_map, .B)
	testing.expect(t, ok)
	testing.expect(t, b == .A)

	b2, ok2 := app.controller_button_to_gb_button(pad_map, .A)
	testing.expect(t, ok2)
	testing.expect(t, b2 == .B)

	b3, ok3 := app.controller_button_to_gb_button(pad_map, .DPAD_UP)
	testing.expect(t, ok3)
	testing.expect(t, b3 == .Up)
}

@(test)
test_controller_button_to_gb_button_unmapped_returns_false :: proc(t: ^testing.T) {
	pad_map := app.default_pad_map()
	_, ok := app.controller_button_to_gb_button(pad_map, .GUIDE)
	testing.expect(t, !ok)
}

@(test)
test_controller_axis_to_buttons_left_stick_only :: proc(t: ^testing.T) {
	pos, neg, ok := app.controller_axis_to_buttons(.LEFTX)
	testing.expect(t, ok)
	testing.expect(t, pos == .Right)
	testing.expect(t, neg == .Left)

	pos2, neg2, ok2 := app.controller_axis_to_buttons(.LEFTY)
	testing.expect(t, ok2)
	testing.expect(t, pos2 == .Down)
	testing.expect(t, neg2 == .Up)

	_, _, ok3 := app.controller_axis_to_buttons(.RIGHTX)
	testing.expect(t, !ok3, "右スティックは未割当のはず")
}

@(private = "file")
make_button_event :: proc(button: sdl.GameControllerButton) -> sdl.ControllerButtonEvent {
	return sdl.ControllerButtonEvent{button = u8(button)}
}

@(private = "file")
make_axis_event :: proc(axis: sdl.GameControllerAxis, value: i16) -> sdl.ControllerAxisEvent {
	return sdl.ControllerAxisEvent{axis = u8(axis), value = value}
}

@(test)
test_controller_button_event_sets_joypad_state :: proc(t: ^testing.T) {
	emu := new(core.Emulator)
	defer free(emu)

	pad_map := app.default_pad_map()
	core.bus_write(&emu.bus, 0xFF00, 0x10) // アクション選択(bit5=0)、方向非選択

	app.input_handle_controller_button_event(emu, pad_map, make_button_event(.B), true) // SDL.B -> GB.A
	v := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v & 0x01 == 0, "SDLのBボタン押下でGBのAが押されているはず")

	app.input_handle_controller_button_event(emu, pad_map, make_button_event(.B), false)
	v2 := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v2 & 0x01 != 0, "離したらAは解放されているはず")
}

@(test)
test_controller_axis_event_deadzone :: proc(t: ^testing.T) {
	emu := new(core.Emulator)
	defer free(emu)

	core.bus_write(&emu.bus, 0xFF00, 0x20) // 方向選択(bit4=0)、アクション非選択

	// デッドゾーン内(±8000)は無反応
	app.input_handle_controller_axis_event(emu, make_axis_event(.LEFTX, 4000))
	v := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v & 0x01 != 0, "デッドゾーン内はRightが押されていないはず")

	// デッドゾーンを超えたら該当方向が押される
	app.input_handle_controller_axis_event(emu, make_axis_event(.LEFTX, 20000))
	v2 := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v2 & 0x01 == 0, "デッドゾーンを超えたらRightが押されるはず")
	testing.expect(t, v2 & 0x02 != 0, "Right押下中はLeftは解放されているはず")

	// 逆方向に倒したら切り替わる
	app.input_handle_controller_axis_event(emu, make_axis_event(.LEFTX, -20000))
	v3 := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v3 & 0x02 == 0, "逆方向に倒したらLeftが押されるはず")
	testing.expect(t, v3 & 0x01 != 0, "Leftを押したらRightは解放されるはず")

	// 中央に戻したら両方解放
	app.input_handle_controller_axis_event(emu, make_axis_event(.LEFTX, 0))
	v4 := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v4 & 0x01 != 0 && v4 & 0x02 != 0, "中央に戻したらどちらも解放されるはず")
}

@(test)
test_controller_manager_destroy_without_open_does_not_crash :: proc(t: ^testing.T) {
	// SDLが未初期化の状態でも(GameControllerOpenを一度も呼ばない=handleがnilのまま)
	// destroyがクラッシュしないことを確認する(未接続時の安全性、T8-5 DoD)。
	mgr: app.Controller_Manager
	app.controller_manager_destroy(&mgr)
	testing.expect(t, mgr.handle == nil)
}

@(test)
test_controller_manager_handle_removed_ignores_unknown_instance :: proc(t: ^testing.T) {
	mgr: app.Controller_Manager
	// handleがnilのまま(未接続)でREMOVEDイベントが来てもクラッシュしない(抜き差し安全性)。
	app.controller_manager_handle_removed(&mgr, 999)
	testing.expect(t, mgr.handle == nil)
}
