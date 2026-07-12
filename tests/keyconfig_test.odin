package tests

import "core:testing"
import app "bbl:app"
import core "bbl:core"
import sdl "vendor:sdl2"

// src/app/input.odin のキーコンフィグ対応(T8-6)の単体テスト。
// input_key_to_button が key_map(config.odin の default_key_map / bbl.ini の key_*)に
// 応じて可変であることと、config_apply_raw で書き換えた割当が実際に反映されることを確認する。

@(private = "file")
raw1 :: proc(k, v: string) -> map[string]string {
	m := make(map[string]string)
	m[k] = v
	return m
}

@(test)
test_input_key_to_button_uses_default_map :: proc(t: ^testing.T) {
	key_map := app.default_key_map()

	b, ok := app.input_key_to_button(key_map, .x)
	testing.expect(t, ok)
	testing.expect(t, b == .A)

	b2, ok2 := app.input_key_to_button(key_map, .RIGHT)
	testing.expect(t, ok2)
	testing.expect(t, b2 == .Right)
}

@(test)
test_input_key_to_button_unmapped_key_returns_false :: proc(t: ^testing.T) {
	key_map := app.default_key_map()
	_, ok := app.input_key_to_button(key_map, .F9)
	testing.expect(t, !ok)
}

@(test)
test_input_key_to_button_respects_remapped_config :: proc(t: ^testing.T) {
	// bbl.ini で key_a = C と再割当した状況を再現(config.odin側の単体テストと対をなす、
	// ここでは実際にinput_key_to_buttonへ渡して反映されることまで確認する)。
	raw := raw1("key_a", "C")
	defer delete(raw)
	cfg := app.config_apply_raw(app.default_config(), raw)

	b, ok := app.input_key_to_button(cfg.key_map, .c)
	testing.expect(t, ok)
	testing.expect(t, b == .A)

	// 元の割当(X)はもう効かない
	_, old_ok := app.input_key_to_button(cfg.key_map, .x)
	testing.expect(t, !old_ok, "再割当後は元のキー割当が外れているはず")
}

@(private = "file")
make_key_event :: proc(sym: sdl.Keycode, repeat: u8 = 0) -> sdl.KeyboardEvent {
	return sdl.KeyboardEvent{keysym = sdl.Keysym{sym = sym}, repeat = repeat}
}

@(test)
test_input_handle_key_event_with_remapped_key_sets_joypad :: proc(t: ^testing.T) {
	emu := new(core.Emulator)
	defer free(emu)

	raw := raw1("key_a", "C")
	defer delete(raw)
	cfg := app.config_apply_raw(app.default_config(), raw)

	core.bus_write(&emu.bus, 0xFF00, 0x10) // アクション選択

	app.input_handle_key_event(emu, cfg.key_map, make_key_event(.c), true)
	v := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v & 0x01 == 0, "再割当したCキーでAが押されるはず")
}

@(test)
test_input_handle_key_event_ignores_repeat :: proc(t: ^testing.T) {
	emu := new(core.Emulator)
	defer free(emu)

	key_map := app.default_key_map()
	core.bus_write(&emu.bus, 0xFF00, 0x10)

	// リピートイベント(repeat!=0)だけを送っても状態が変わらないことを確認
	// (押していない状態からリピートが来ても無視されるはず)。
	app.input_handle_key_event(emu, key_map, make_key_event(.x, 1), true)
	v := core.bus_read(&emu.bus, 0xFF00)
	testing.expect(t, v & 0x01 != 0, "repeat!=0のイベントは無視されAは押されないはず")
}
