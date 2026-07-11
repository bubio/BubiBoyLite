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
