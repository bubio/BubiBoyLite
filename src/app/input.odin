package main

import core "bbl:core"
import sdl "vendor:sdl2"

// キーボード入力を joypad へ接続する(T3-7)。デフォルト割当(キーコンフィグはフェーズ8):
// 矢印キー=十字キー、Z=B、X=A、Enter=Start、右Shift=Select。
// 参照: BluePrint.md「キーボードショートカットで操作」。

// input_key_to_button は SDL のキーコードを対応する Game Boy ボタンへ変換する。
// 割当の無いキーは ok=false を返す。
// architecture.mdは網羅的switchを推奨するが、sdl.Keycodeは数百件あるUI用の巨大列挙型で
// あり、命令デコードのような「漏れの検出」に価値が無い(未割当キーはすべて無視したい)ため
// #partial switchを意図的に使う。
input_key_to_button :: proc(sym: sdl.Keycode) -> (button: core.Button, ok: bool) {
	#partial switch sym {
	case .RIGHT:
		return .Right, true
	case .LEFT:
		return .Left, true
	case .UP:
		return .Up, true
	case .DOWN:
		return .Down, true
	case .z:
		return .B, true
	case .x:
		return .A, true
	case .RETURN, .KP_ENTER:
		return .Start, true
	case .RSHIFT:
		return .Select, true
	}
	return .A, false
}

// input_handle_key_event は SDL_KEYDOWN/SDL_KEYUP イベント1件を joypad の状態へ反映する。
// 落とし穴: キーリピートイベント(event.repeat != 0)は無視する(押しっぱなしで何度も
// イベントが来ても、押下状態は既にtrueなので二重処理は不要かつ有害)。
input_handle_key_event :: proc(emu: ^core.Emulator, event: sdl.KeyboardEvent, pressed: bool) {
	if event.repeat != 0 {
		return
	}
	button, ok := input_key_to_button(event.keysym.sym)
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
