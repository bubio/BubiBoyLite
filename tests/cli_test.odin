package tests

import "core:testing"
import app "bbl:app"

@(test)
test_default_scale :: proc(t: ^testing.T) {
	opts, _, ok := app.parse_args([]string{})
	testing.expect(t, ok)
	testing.expect(t, opts.scale == 4)
	testing.expect(t, opts.shader == .Nearest)
}

@(test)
test_scale_round_down_to_8 :: proc(t: ^testing.T) {
	opts, _, ok := app.parse_args([]string{"--scale", "12"})
	testing.expect(t, ok)
	testing.expect(t, opts.scale == 8)
}

@(test)
test_scale_zero_is_error :: proc(t: ^testing.T) {
	_, _, ok := app.parse_args([]string{"--scale", "0"})
	testing.expect(t, !ok)
}

@(test)
test_scale_non_numeric_is_error :: proc(t: ^testing.T) {
	_, _, ok := app.parse_args([]string{"--scale", "abc"})
	testing.expect(t, !ok)
}

@(test)
test_shader_bogus_is_error :: proc(t: ^testing.T) {
	_, _, ok := app.parse_args([]string{"--shader", "bogus"})
	testing.expect(t, !ok)
}

@(test)
test_two_positional_args_is_error :: proc(t: ^testing.T) {
	_, _, ok := app.parse_args([]string{"a.gb", "b.gb"})
	testing.expect(t, !ok)
}

@(test)
test_fullscreen_and_headless_flags :: proc(t: ^testing.T) {
	opts, _, ok := app.parse_args([]string{"--fullscreen", "--headless", "game.gbc"})
	testing.expect(t, ok)
	testing.expect(t, opts.fullscreen)
	testing.expect(t, opts.headless)
	testing.expect(t, opts.rom_path == "game.gbc")
}
