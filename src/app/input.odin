package main

import "core:fmt"
import core "bbl:core"
import sdl "vendor:sdl2"

// キーボード入力を joypad へ接続する(T3-7)。デフォルト割当は config.odin の
// default_key_map(矢印キー=十字キー、Z=B、X=A、Enter=Start、右Shift=Select)。
// bbl.ini の key_* で変更可能(T8-6)。参照: BluePrint.md「キーボードショートカットで操作」。

// input_key_to_button は key_map(config.odinのdefault_key_map/bbl.iniのkey_*)の
// 逆引き(SDLキー -> GBボタン)を行う純粋関数。割当の無いキーは ok=false を返す。
// controller_button_to_gb_buttonと同じくcore.Buttonは8種類しかないので線形探索で十分。
input_key_to_button :: proc(key_map: [core.Button]sdl.Keycode, sym: sdl.Keycode) -> (button: core.Button, ok: bool) {
	for b in core.Button {
		if key_map[b] == sym {
			return b, true
		}
	}
	return .A, false
}

// input_handle_key_event は SDL_KEYDOWN/SDL_KEYUP イベント1件を joypad の状態へ反映する。
// 落とし穴: キーリピートイベント(event.repeat != 0)は無視する(押しっぱなしで何度も
// イベントが来ても、押下状態は既にtrueなので二重処理は不要かつ有害)。
input_handle_key_event :: proc(
	emu: ^core.Emulator,
	key_map: [core.Button]sdl.Keycode,
	event: sdl.KeyboardEvent,
	pressed: bool,
) {
	if event.repeat != 0 {
		return
	}
	button, ok := input_key_to_button(key_map, event.keysym.sym)
	if !ok {
		return
	}
	core.joypad_set_button(&emu.bus, button, pressed)
}

// --- セーブステートのショートカット(T7-4) ---
// BluePrint「キーボードショートカットで操作」に沿う割当: F5=保存、F7=復元、
// F1-F4=スロット選択(<ROM名>.state1〜.state4、デフォルトスロット1、state_path_for_romの
// 「slot==1のときは.state1ではなく.state」規則と対応する)。
// input_handle_shortcut_key は「どのアクションが要求されたか」を判定するだけの純粋関数に
// とどめ、実際のファイルI/O(state_save/state_load)はmain.odin側でフレーム境界において行う
// (落とし穴: run_frameの外でフラグ処理する。ここでイベントを受け取った時点でまだ次の
// run_frameは呼ばれていないので、この判定自体はどのタイミングで呼んでも安全)。

Shortcut_Action :: enum {
	None,
	Select_Slot,
	Save_State,
	Load_State,
}

Input_State :: struct {
	state_slot: int, // 1-4。デフォルト1(input_state_default)
}

input_state_default :: proc() -> Input_State {
	return Input_State{state_slot = 1}
}

// input_is_fullscreen_toggle は Alt+Enter(macOSは Cmd+Enter も)かどうかを判定する(T8-2)。
// GUIキー(Windowsキー/Cmdキー)はどのOSでもEnterとの組み合わせが他機能と衝突しないため、
// プラットフォーム分岐せず両方受け付ける。純粋関数(SDL初期化非依存)。
input_is_fullscreen_toggle :: proc(event: sdl.KeyboardEvent) -> bool {
	if event.repeat != 0 {
		return false
	}
	if event.keysym.sym != .RETURN && event.keysym.sym != .KP_ENTER {
		return false
	}
	alt_or_gui := (event.keysym.mod & sdl.KMOD_ALT) != {} || (event.keysym.mod & sdl.KMOD_GUI) != {}
	return alt_or_gui
}

// input_handle_shortcut_key は KEYDOWN イベント1件を解釈する。スロット選択(F1-F4)は
// ここで即座に state.state_slot へ反映する。input_handle_key_event と同じくキーリピートは
// 無視する。
input_handle_shortcut_key :: proc(state: ^Input_State, event: sdl.KeyboardEvent) -> Shortcut_Action {
	if event.repeat != 0 {
		return .None
	}
	#partial switch event.keysym.sym {
	case .F1:
		state.state_slot = 1
		return .Select_Slot
	case .F2:
		state.state_slot = 2
		return .Select_Slot
	case .F3:
		state.state_slot = 3
		return .Select_Slot
	case .F4:
		state.state_slot = 4
		return .Select_Slot
	case .F5:
		return .Save_State
	case .F7:
		return .Load_State
	}
	return .None
}

// --- ゲームコントローラー対応(T8-5) ---
// BluePrint「ゲームコントローラーでも操作できる」。SDL_GameController API(Joystick APIでは
// なく、マッピングDBが使える方)を使う。GBは1プレイヤーなので同時に1台だけ扱う
// (2台目以降が挿されても無視する。1台目を抜けば次に挿さっているコントローラーを拾える)。

// CONTROLLER_DEADZONE はスティックのデッドゾーン(T8-5「落とし穴」、±8000/32767目安)。
CONTROLLER_DEADZONE :: 8000

Controller_Manager :: struct {
	handle:      ^sdl.GameController,
	instance_id: sdl.JoystickID,
}

// controller_manager_open_first_available は起動時に既に接続されているコントローラーの
// うち最初の1台を開く(未接続でもok、起動に影響しない)。
controller_manager_open_first_available :: proc(mgr: ^Controller_Manager) {
	n := sdl.NumJoysticks()
	for i in i32(0) ..< n {
		if sdl.IsGameController(i) {
			controller_manager_try_open(mgr, i)
			if mgr.handle != nil {
				return
			}
		}
	}
}

@(private = "file")
controller_manager_try_open :: proc(mgr: ^Controller_Manager, device_index: i32) {
	if mgr.handle != nil {
		return // 既に1台接続済み(GBは1プレイヤーのため複数コントローラーは扱わない)
	}
	handle := sdl.GameControllerOpen(device_index)
	if handle == nil {
		fmt.eprintfln("controller: オープンに失敗しました: %s", sdl.GetError())
		return
	}
	joystick := sdl.GameControllerGetJoystick(handle)
	mgr.handle = handle
	mgr.instance_id = sdl.JoystickInstanceID(joystick)
	fmt.eprintfln("controller: 接続しました (%s)", sdl.GameControllerName(handle))
}

// controller_manager_handle_added は SDL_CONTROLLERDEVICEADDED(T8-5ホットプラグ)を処理する。
// event.cdevice.which はこのイベントでは「デバイスindex」であることに注意(REMOVEDとは意味が違う)。
controller_manager_handle_added :: proc(mgr: ^Controller_Manager, device_index: i32) {
	if !sdl.IsGameController(device_index) {
		return
	}
	controller_manager_try_open(mgr, device_index)
}

// controller_manager_handle_removed は SDL_CONTROLLERDEVICEREMOVED を処理する。
// event.cdevice.which はこのイベントでは「instance id」であることに注意(ADDEDとは意味が違う)。
// 抜かれたのが現在保持しているコントローラーでなければ何もしない(2台目以降を無視した結果、
// 既にopenしていないデバイスのREMOVEDが飛んでくることがあるため)。
controller_manager_handle_removed :: proc(mgr: ^Controller_Manager, instance_id: sdl.JoystickID) {
	if mgr.handle == nil || mgr.instance_id != instance_id {
		return
	}
	fmt.eprintln("controller: 切断されました")
	sdl.GameControllerClose(mgr.handle)
	mgr.handle = nil
	mgr.instance_id = 0
}

controller_manager_destroy :: proc(mgr: ^Controller_Manager) {
	if mgr.handle != nil {
		sdl.GameControllerClose(mgr.handle)
		mgr.handle = nil
	}
}

// controller_button_to_gb_button は pad_map(config.odinのdefault_pad_map/bbl.iniのpad_*)の
// 逆引き(SDLボタン -> GBボタン)を行う純粋関数。core.Buttonは8種類しかないので線形探索で十分。
controller_button_to_gb_button :: proc(
	pad_map: [core.Button]sdl.GameControllerButton,
	sdl_button: sdl.GameControllerButton,
) -> (
	button: core.Button,
	ok: bool,
) {
	for b in core.Button {
		if pad_map[b] == sdl_button {
			return b, true
		}
	}
	return .A, false
}

// input_handle_controller_button_event は SDL_CONTROLLERBUTTONDOWN/UP イベント1件を
// joypad の状態へ反映する。
input_handle_controller_button_event :: proc(
	emu: ^core.Emulator,
	pad_map: [core.Button]sdl.GameControllerButton,
	event: sdl.ControllerButtonEvent,
	pressed: bool,
) {
	button, ok := controller_button_to_gb_button(pad_map, sdl.GameControllerButton(event.button))
	if !ok {
		return
	}
	core.joypad_set_button(&emu.bus, button, pressed)
}

// controller_axis_to_buttons は左スティックの軸(LEFTX/LEFTY)に対応する正/負方向のGBボタンを
// 返す(十字キー相当)。右スティック・トリガーは割当てない(ok=false)。
// #partial switchの理由はinput_key_to_buttonと同じ(sdl.GameControllerAxisは対応しない値の
// 方が多い巨大列挙型で、網羅を強制する価値が無い)。
controller_axis_to_buttons :: proc(
	axis: sdl.GameControllerAxis,
) -> (
	positive: core.Button,
	negative: core.Button,
	ok: bool,
) {
	#partial switch axis {
	case .LEFTX:
		return .Right, .Left, true
	case .LEFTY:
		return .Down, .Up, true
	}
	return .A, .A, false
}

// input_handle_controller_axis_event は SDL_CONTROLLERAXISMOTION イベント1件を
// デッドゾーン付きでjoypadの状態へ反映する(T8-5「落とし穴」)。
input_handle_controller_axis_event :: proc(emu: ^core.Emulator, event: sdl.ControllerAxisEvent) {
	positive, negative, ok := controller_axis_to_buttons(sdl.GameControllerAxis(event.axis))
	if !ok {
		return
	}
	if event.value > CONTROLLER_DEADZONE {
		core.joypad_set_button(&emu.bus, positive, true)
		core.joypad_set_button(&emu.bus, negative, false)
	} else if event.value < -CONTROLLER_DEADZONE {
		core.joypad_set_button(&emu.bus, negative, true)
		core.joypad_set_button(&emu.bus, positive, false)
	} else {
		core.joypad_set_button(&emu.bus, positive, false)
		core.joypad_set_button(&emu.bus, negative, false)
	}
}
