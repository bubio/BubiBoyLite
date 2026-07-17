package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "bbl:app"
import core "bbl:core"
import sdl "vendor:sdl2"

// src/app/config.odin の単体テスト(T8-1)。
// config_parse_ini / config_apply_raw / config_apply_cli_overrides / config_render_default_ini /
// config_key_map_conflicts はいずれも純粋関数(ファイルI/O非依存)なので直接検証できる。
// ファイルI/Oを伴う config_load 自体の結合検証は phase-08-frontend.md の検証方法にある
// シェルコマンド(`rm -f ./bbl.ini && ./bbl --headless && cat ./bbl.ini`)で行う。

// raw1 は「1個だけkey=valueが入ったmap」を組み立てるテスト用ヘルパー。
// Odin のマップ複合リテラルは `#+feature dynamic-literals` が必要になるため、代わりに
// make+代入で組み立てる(このファイル限定の機能フラグを増やさないため)。
@(private = "file")
raw1 :: proc(k, v: string) -> map[string]string {
	m := make(map[string]string)
	m[k] = v
	return m
}

@(test)
test_config_default_values :: proc(t: ^testing.T) {
	cfg := app.default_config()
	testing.expect(t, cfg.scale == 4)
	testing.expect(t, !cfg.fullscreen)
	testing.expect(t, cfg.shader == .Nearest)
	testing.expect(t, cfg.save_dir == "")
	testing.expect(t, cfg.state_dir == "")
	testing.expect(t, cfg.volume == 100)
	testing.expect(t, cfg.key_map[.A] == .x)
	testing.expect(t, cfg.key_map[.B] == .z)
	// Nintendo配置に合わせSDLのB=GBのA、SDLのA=GBのB(phase-08「落とし穴」)
	testing.expect(t, cfg.pad_map[.A] == .B)
	testing.expect(t, cfg.pad_map[.B] == .A)
}

@(test)
test_config_parse_ini_basic :: proc(t: ^testing.T) {
	text := "# comment\nscale = 6\n\nfullscreen=true\nshader = smooth # trailing comment not stripped, but key=value still fine\n"
	raw := app.config_parse_ini(text)
	defer delete(raw)
	testing.expect(t, raw["scale"] == "6")
	testing.expect(t, raw["fullscreen"] == "true")
}

@(test)
test_config_parse_ini_ignores_comments_and_blank_lines :: proc(t: ^testing.T) {
	text := "\n   \n# full comment line\nvolume = 55\n"
	raw := app.config_parse_ini(text)
	defer delete(raw)
	testing.expect(t, len(raw) == 1)
	testing.expect(t, raw["volume"] == "55")
}

@(test)
test_config_apply_raw_valid_scale :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("scale", "7")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.scale == 7)
}

@(test)
test_config_apply_raw_invalid_scale_falls_back_to_default :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("scale", "999")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.scale == base.scale, "不正なscaleはデフォルトへフォールバックするはず")
}

@(test)
test_config_apply_raw_invalid_shader_falls_back :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("shader", "bogus")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.shader == .Nearest)
}

@(test)
test_config_apply_raw_fullscreen_bool_variants :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("fullscreen", "TRUE")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.fullscreen)
}

@(test)
test_config_apply_raw_invalid_volume_falls_back :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("volume", "150")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.volume == base.volume)
}

@(test)
test_config_apply_raw_key_mapping :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("key_a", "C")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.key_map[.A] == .c)
}

@(test)
test_config_apply_raw_invalid_key_name_falls_back :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("key_a", "NotARealKeyName123")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.key_map[.A] == base.key_map[.A])
}

@(test)
test_config_apply_raw_pad_mapping :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("pad_start", "guide")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.pad_map[.Start] == .GUIDE)
}

@(test)
test_config_apply_raw_invalid_pad_name_falls_back :: proc(t: ^testing.T) {
	base := app.default_config()
	raw := raw1("pad_start", "not_a_real_button")
	defer delete(raw)
	cfg := app.config_apply_raw(base, raw)
	testing.expect(t, cfg.pad_map[.Start] == base.pad_map[.Start])
}

@(test)
test_config_apply_cli_overrides_only_provided_fields :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.scale = 4
	cfg.shader = .Nearest

	opts, _, ok := app.parse_args([]string{"--scale", "2"})
	testing.expect(t, ok)

	merged := app.config_apply_cli_overrides(cfg, opts)
	testing.expect(t, merged.scale == 2, "CLIで指定したscaleが優先されるはず")
	testing.expect(t, merged.shader == .Nearest, "CLIで指定していないshaderは設定ファイルの値のままのはず")
}

@(test)
test_config_apply_cli_overrides_does_not_touch_unprovided_scale :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.scale = 6 // 設定ファイルでscale=6が指定されていた状況を模す

	opts, _, ok := app.parse_args([]string{"--fullscreen"})
	testing.expect(t, ok)

	merged := app.config_apply_cli_overrides(cfg, opts)
	testing.expect(t, merged.scale == 6, "CLIでscaleを指定していないので設定ファイルの値を維持するはず")
	testing.expect(t, merged.fullscreen, "CLIで指定したfullscreenは優先されるはず")
}

@(test)
test_config_render_default_ini_contains_all_keys :: proc(t: ^testing.T) {
	content := app.config_render_default_ini()
	defer delete(content)

	testing.expect(t, strings.contains(content, "scale = 4"))
	testing.expect(t, strings.contains(content, "fullscreen = false"))
	testing.expect(t, strings.contains(content, "shader = nearest"))
	testing.expect(t, strings.contains(content, "save_dir ="))
	testing.expect(t, strings.contains(content, "state_dir ="))
	testing.expect(t, strings.contains(content, "volume = 100"))
	for b in app.gb_button_order {
		testing.expect(t, strings.contains(content, "key_"))
		testing.expect(t, strings.contains(content, "pad_"))
	}
	// 実ユーザー名を含まないこと(CLAUDE.md / phase-08 T8-7 の受け入れ条件)
	testing.expect(t, !strings.contains(content, "/Users/"))
}

@(test)
test_config_render_default_ini_round_trips_through_parser :: proc(t: ^testing.T) {
	content := app.config_render_default_ini()
	defer delete(content)

	raw := app.config_parse_ini(content)
	defer delete(raw)

	cfg := app.config_apply_raw(app.default_config(), raw)
	default_cfg := app.default_config()
	testing.expect(t, cfg.scale == default_cfg.scale)
	testing.expect(t, cfg.fullscreen == default_cfg.fullscreen)
	testing.expect(t, cfg.shader == default_cfg.shader)
	testing.expect(t, cfg.key_map == default_cfg.key_map, "SDLキー名の書き出し/読み込みが往復するはず")
	testing.expect(t, cfg.pad_map == default_cfg.pad_map, "SDLボタン名の書き出し/読み込みが往復するはず")
}

@(test)
test_is_reserved_shortcut_key :: proc(t: ^testing.T) {
	testing.expect(t, app.is_reserved_shortcut_key(.F5))
	testing.expect(t, app.is_reserved_shortcut_key(.ESCAPE))
	testing.expect(t, !app.is_reserved_shortcut_key(.z))
}

@(test)
test_config_key_map_conflicts_default_has_none :: proc(t: ^testing.T) {
	cfg := app.default_config()
	conflicts := app.config_key_map_conflicts(cfg.key_map)
	testing.expect(t, conflicts == {}, "デフォルト割当はショートカットキーと衝突しないはず")
}

@(test)
test_config_key_map_conflicts_detects_overlap :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.key_map[.A] = .F5
	conflicts := app.config_key_map_conflicts(cfg.key_map)
	testing.expect(t, core.Button.A in conflicts)
}

// --- config_patch_ini(T12-2)の単体テスト ---

@(test)
test_config_patch_ini_replaces_only_target_key :: proc(t: ^testing.T) {
	original := "# comment\nscale = 4\nvolume = 100\n# another comment\nfullscreen = false\n"
	changes := make(map[string]string)
	defer delete(changes)
	changes["volume"] = "50"

	patched := app.config_patch_ini(original, changes)
	defer delete(patched)

	testing.expect(t, strings.contains(patched, "volume = 50"))
	testing.expect(t, !strings.contains(patched, "volume = 100"))
	// 他の行・コメント・行順は保持される。
	testing.expect(t, strings.contains(patched, "# comment"))
	testing.expect(t, strings.contains(patched, "scale = 4"))
	testing.expect(t, strings.contains(patched, "# another comment"))
	testing.expect(t, strings.contains(patched, "fullscreen = false"))

	scale_idx := strings.index(patched, "scale = 4")
	volume_idx := strings.index(patched, "volume = 50")
	fullscreen_idx := strings.index(patched, "fullscreen = false")
	testing.expect(t, scale_idx < volume_idx && volume_idx < fullscreen_idx, "行順が保持されること")
}

@(test)
test_config_patch_ini_no_changes_is_noop :: proc(t: ^testing.T) {
	original := "# comment\nscale = 4\nvolume = 100\n"
	changes := make(map[string]string)
	defer delete(changes)

	patched := app.config_patch_ini(original, changes)
	defer delete(patched)

	testing.expect(t, patched == original, "変更が無ければ元のテキストと完全一致すること")
}

@(test)
test_config_patch_ini_appends_missing_key :: proc(t: ^testing.T) {
	original := "scale = 4\n"
	changes := make(map[string]string)
	defer delete(changes)
	changes["volume"] = "75"

	patched := app.config_patch_ini(original, changes)
	defer delete(patched)

	testing.expect(t, strings.contains(patched, "scale = 4"))
	testing.expect(t, strings.contains(patched, "volume = 75"))
}

@(test)
test_config_patch_ini_ignores_commented_key :: proc(t: ^testing.T) {
	// コメントアウトされた行(`# volume = 999`)はキーとして扱わず、変更対象にしない。
	original := "# volume = 999\n"
	changes := make(map[string]string)
	defer delete(changes)
	changes["volume"] = "50"

	patched := app.config_patch_ini(original, changes)
	defer delete(patched)

	testing.expect(t, strings.contains(patched, "# volume = 999"), "コメント行は変更されない")
	testing.expect(t, strings.contains(patched, "volume = 50"), "コメントとは別に新しい行が追記される")
}

// --- config_apply_set(T12-4)の単体テスト ---

@(test)
test_config_apply_set_valid_volume_updates_cfg_and_file :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	config_dir := fmt.tprintf("%s/bbl_config_apply_set_test", tmp_dir)
	os.remove_all(config_dir)
	testing.expect(t, os.make_directory(config_dir) == nil)
	defer os.remove_all(config_dir)

	// config_path は fmt.tprintf(temp_allocator)の戻り値なので明示的な delete はしない。
	path := app.config_path(config_dir)
	default_content := app.config_render_default_ini()
	defer delete(default_content)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)default_content) == nil)

	cfg := app.default_config()
	ok, msg := app.config_apply_set(&cfg, config_dir, "volume", "42")
	testing.expect(t, ok)
	testing.expect(t, cfg.volume == 42)
	testing.expect(t, strings.contains(msg, "volume"))

	data, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(data)
	testing.expect(t, strings.contains(string(data), "volume = 42"))
	// 他のデフォルト項目(scale等)は変化しないこと。
	testing.expect(t, strings.contains(string(data), "scale = 4"))
}

@(test)
test_config_apply_set_invalid_value_does_not_change_cfg :: proc(t: ^testing.T) {
	cfg := app.default_config()
	original_volume := cfg.volume
	// config_dir を空にしてファイルI/Oを避ける(検証ロジックだけを見るテスト)。
	ok, msg := app.config_apply_set(&cfg, "", "volume", "not_a_number")
	testing.expect(t, !ok)
	testing.expect(t, cfg.volume == original_volume)
	testing.expect(t, strings.contains(msg, "volume"))
}

@(test)
test_config_apply_set_unknown_key_rejected :: proc(t: ^testing.T) {
	cfg := app.default_config()
	ok, msg := app.config_apply_set(&cfg, "", "key_a", "x")
	testing.expect(t, !ok, "key_*/pad_* はT12-4の対象外")
	testing.expect(t, strings.contains(msg, "不明"))
}

@(test)
test_config_apply_set_empty_config_dir_still_updates_cfg :: proc(t: ^testing.T) {
	cfg := app.default_config()
	ok, msg := app.config_apply_set(&cfg, "", "scale", "6")
	testing.expect(t, ok)
	testing.expect(t, cfg.scale == 6)
	testing.expect(t, strings.contains(msg, "メモリ上のみ"), "保存先不明時はその旨をメッセージに含める")
}
