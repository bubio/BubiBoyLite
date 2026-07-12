package tests

import "core:fmt"
import "core:os"
import "core:testing"
import app "bbl:app"

// src/app/recent.odin の単体テスト(T9-3)。
// 落とし穴(phase-09-tui.md T9-3): 履歴のパスは絶対パスで保存するが、実際のユーザー名を
// 含むパスをテストフィクスチャに残さないよう、ここでは os.temp_dir 配下の合成パス文字列
// (実在しないダミーファイル名で十分な純粋関数テスト)や実際に os.temp_dir に作った
// テスト用ファイルのみを使う(既存の statefile_test.odin 等と同じ流儀)。

@(test)
test_recent_parse_skips_empty_lines :: proc(t: ^testing.T) {
	list := app.recent_parse("/a/one.gbc\n\n/a/two.gb\n   \n/a/three.gbc\n")
	defer app.recent_list_delete(list)
	testing.expect(t, len(list) == 3)
	testing.expect(t, list[0] == "/a/one.gbc")
	testing.expect(t, list[1] == "/a/two.gb")
	testing.expect(t, list[2] == "/a/three.gbc")
}

@(test)
test_recent_render_round_trips_with_parse :: proc(t: ^testing.T) {
	original := []string{"/a/one.gbc", "/a/two.gb"}
	text := app.recent_render(original)
	defer delete(text)

	parsed := app.recent_parse(text)
	defer app.recent_list_delete(parsed)
	testing.expect(t, len(parsed) == 2)
	testing.expect(t, parsed[0] == "/a/one.gbc")
	testing.expect(t, parsed[1] == "/a/two.gb")
}

@(test)
test_recent_add_prepends_new_entry :: proc(t: ^testing.T) {
	list := []string{"/a/old1.gbc", "/a/old2.gbc"}
	updated := app.recent_add(list, "/a/new.gbc")
	defer app.recent_list_delete(updated)

	testing.expect(t, len(updated) == 3)
	testing.expect(t, updated[0] == "/a/new.gbc")
	testing.expect(t, updated[1] == "/a/old1.gbc")
	testing.expect(t, updated[2] == "/a/old2.gbc")
}

@(test)
test_recent_add_moves_duplicate_to_front_without_growing :: proc(t: ^testing.T) {
	list := []string{"/a/one.gbc", "/a/two.gbc", "/a/three.gbc"}
	updated := app.recent_add(list, "/a/two.gbc")
	defer app.recent_list_delete(updated)

	testing.expect(t, len(updated) == 3, "重複は新規追加ではなく移動のはず")
	testing.expect(t, updated[0] == "/a/two.gbc")
	testing.expect(t, updated[1] == "/a/one.gbc")
	testing.expect(t, updated[2] == "/a/three.gbc")
}

@(test)
test_recent_add_caps_at_max_entries :: proc(t: ^testing.T) {
	list := make([dynamic]string)
	defer delete(list)
	for i in 0 ..< app.RECENT_MAX_ENTRIES {
		append(&list, fmt.tprintf("/a/rom%d.gbc", i))
	}
	testing.expect(t, len(list) == app.RECENT_MAX_ENTRIES)

	updated := app.recent_add(list[:], "/a/newest.gbc")
	defer app.recent_list_delete(updated)

	testing.expect(t, len(updated) == app.RECENT_MAX_ENTRIES, "上限を超えないはず")
	testing.expect(t, updated[0] == "/a/newest.gbc")
	// 最後(最古)の1件が追い出されているはず。
	testing.expect(t, updated[app.RECENT_MAX_ENTRIES - 1] != fmt.tprintf("/a/rom%d.gbc", app.RECENT_MAX_ENTRIES - 1))
}

@(test)
test_recent_filter_existing_skips_missing_paths :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	existing_path := fmt.tprintf("%s/bbl_recent_test_exists.gbc", tmp_dir)
	testing.expect(t, os.write_entire_file(existing_path, []u8{0x00}) == nil)
	defer os.remove(existing_path)

	missing_path := fmt.tprintf("%s/bbl_recent_test_does_not_exist.gbc", tmp_dir)

	list := []string{existing_path, missing_path}
	filtered := app.recent_filter_existing(list)
	defer app.recent_list_delete(filtered)

	testing.expect(t, len(filtered) == 1)
	testing.expect(t, filtered[0] == existing_path)
}

@(test)
test_recent_load_missing_file_returns_empty :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	nonexistent := fmt.tprintf("%s/bbl_recent_test_no_such_file.txt", tmp_dir)
	list := app.recent_load(nonexistent)
	defer app.recent_list_delete(list)
	testing.expect(t, len(list) == 0)
}

@(test)
test_recent_save_and_load_round_trip :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	path := fmt.tprintf("%s/bbl_recent_test_roundtrip.txt", tmp_dir)
	defer os.remove(path)

	original := []string{"/a/one.gbc", "/a/two.gbc"}
	testing.expect(t, app.recent_save(path, original))

	loaded := app.recent_load(path)
	defer app.recent_list_delete(loaded)
	testing.expect(t, len(loaded) == 2)
	testing.expect(t, loaded[0] == "/a/one.gbc")
	testing.expect(t, loaded[1] == "/a/two.gbc")
}

@(test)
test_recent_record_launch_creates_and_updates_file :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_dir)

	config_dir := fmt.tprintf("%s/bbl_recent_test_config_dir", tmp_dir)
	os.remove_all(config_dir)
	testing.expect(t, os.make_directory(config_dir) == nil)
	defer os.remove_all(config_dir)

	rom_path := fmt.tprintf("%s/game.gbc", tmp_dir)
	testing.expect(t, os.write_entire_file(rom_path, []u8{0x00}) == nil)
	defer os.remove(rom_path)

	testing.expect(t, app.recent_record_launch(config_dir, rom_path))

	recent_path := app.recent_file_path(config_dir)
	defer delete(recent_path)
	list := app.recent_load(recent_path)
	defer app.recent_list_delete(list)
	testing.expect(t, len(list) == 1)
	// recent_record_launch は絶対パス化して保存するはず(T9-3落とし穴)。
	testing.expect(t, len(list[0]) > 0 && list[0][0] == '/', "絶対パスで保存されているはず")
}
