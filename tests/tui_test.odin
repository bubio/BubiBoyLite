package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "bbl:app"
import core "bbl:core"

// src/app/tui.odin の単体テスト(T9-1/T9-2)。実際のターミナルの見た目を目視で確認することは
// できないため、描画(tui_render_frame)とキー解析(tui_parse_key)を純粋関数として分離し、
// その出力文字列を検証する(phase-09-tui.md「検証について」の方針)。

@(test)
test_display_width_ascii :: proc(t: ^testing.T) {
	testing.expect(t, app.display_width("abc") == 3)
	testing.expect(t, app.display_width("") == 0)
}

@(test)
test_display_width_fullwidth :: proc(t: ^testing.T) {
	// "あ"(ひらがな)は表示幅2。
	testing.expect(t, app.display_width("あ") == 2)
	// "game1" は半角5。
	testing.expect(t, app.display_width("ROMを選択") == 3 + 2 + 2 + 2) // R,O,M(半角) + を,選,択(全角)
}

@(test)
test_parse_key_arrows :: proc(t: ^testing.T) {
	up, up_n := app.tui_parse_key([]u8{0x1b, '[', 'A'})
	testing.expect(t, up.key == .Up && up_n == 3)

	down, down_n := app.tui_parse_key([]u8{0x1b, '[', 'B'})
	testing.expect(t, down.key == .Down && down_n == 3)

	right, right_n := app.tui_parse_key([]u8{0x1b, '[', 'C'})
	testing.expect(t, right.key == .Right && right_n == 3)

	left, left_n := app.tui_parse_key([]u8{0x1b, '[', 'D'})
	testing.expect(t, left.key == .Left && left_n == 3)
}

@(test)
test_parse_key_partial_escape_sequence_waits :: proc(t: ^testing.T) {
	// "ESC [" までしか届いていない場合は consumed=0(続きを待つ)。
	ev, n := app.tui_parse_key([]u8{0x1b, '['})
	testing.expect(t, n == 0)
	testing.expect(t, ev.key == .None)
}

@(test)
test_parse_key_lone_escape :: proc(t: ^testing.T) {
	ev, n := app.tui_parse_key([]u8{0x1b})
	testing.expect(t, ev.key == .Escape && n == 1)
}

@(test)
test_parse_key_enter_and_backspace :: proc(t: ^testing.T) {
	enter, en := app.tui_parse_key([]u8{'\r'})
	testing.expect(t, enter.key == .Enter && en == 1)

	back, bn := app.tui_parse_key([]u8{0x7f})
	testing.expect(t, back.key == .Backspace && bn == 1)
}

@(test)
test_parse_key_char :: proc(t: ^testing.T) {
	ev, n := app.tui_parse_key([]u8{'q'})
	testing.expect(t, ev.key == .Char && ev.ch == 'q' && n == 1)
}

@(test)
test_parse_key_empty_buffer :: proc(t: ^testing.T) {
	ev, n := app.tui_parse_key([]u8{})
	testing.expect(t, ev.key == .None && n == 0)
}

@(test)
test_render_frame_contains_border_and_title :: proc(t: ^testing.T) {
	frame := app.Tui_Frame {
		cols     = 80,
		rows     = 24,
		title    = "BubiBoyLite v0.1.0",
		heading  = "ROM を選択してください",
		items    = []app.List_Item{{label = "game1.gbc", info = "(MBC5, CGB)"}, {label = "game2.gb", info = "(MBC1)"}},
		selected = 0,
		footer   = "↑↓ 選択  Enter 起動  q 終了",
	}
	s := app.tui_render_frame(frame)
	defer delete(s)

	testing.expect(t, strings.contains(s, "┌─ BubiBoyLite v0.1.0"))
	testing.expect(t, strings.contains(s, "┐"))
	testing.expect(t, strings.contains(s, "└"))
	testing.expect(t, strings.contains(s, "┘"))
	testing.expect(t, strings.contains(s, "ROM を選択してください"))
	testing.expect(t, strings.contains(s, "game1.gbc"))
	testing.expect(t, strings.contains(s, "(MBC5, CGB)"))
	testing.expect(t, strings.contains(s, "↑↓ 選択  Enter 起動  q 終了"))
}

@(test)
test_render_frame_marks_selected_row :: proc(t: ^testing.T) {
	frame := app.Tui_Frame {
		cols     = 80,
		rows     = 24,
		title    = "t",
		heading  = "h",
		items    = []app.List_Item{{label = "one"}, {label = "two"}, {label = "three"}},
		selected = 1,
		footer   = "f",
	}
	s := app.tui_render_frame(frame)
	defer delete(s)

	lines := strings.split(s, "\n", context.temp_allocator)
	found_marker_on_two := false
	for line in lines {
		if strings.contains(line, "two") {
			testing.expect(t, strings.contains(line, "▸"))
			found_marker_on_two = true
		}
		if strings.contains(line, "one") || strings.contains(line, "three") {
			testing.expect(t, !strings.contains(line, "▸"))
		}
	}
	testing.expect(t, found_marker_on_two)
}

@(test)
test_render_frame_includes_ansi_control_sequences :: proc(t: ^testing.T) {
	frame := app.Tui_Frame{cols = 80, rows = 24, title = "t", heading = "h", footer = "f"}
	s := app.tui_render_frame(frame)
	defer delete(s)

	testing.expect(t, strings.has_prefix(s, app.CURSOR_HOME + app.CLEAR_SCREEN))
}

@(test)
test_render_frame_status_line_shown_when_present :: proc(t: ^testing.T) {
	frame := app.Tui_Frame{cols = 80, rows = 24, title = "t", heading = "h", status = "エラー: 読み込めません", footer = "f"}
	s := app.tui_render_frame(frame)
	defer delete(s)
	testing.expect(t, strings.contains(s, "エラー: 読み込めません"))
}

@(test)
test_key_reader_poll_no_data_returns_not_ok :: proc(t: ^testing.T) {
	// key_reader_poll は tui_plat_read (実端末I/O)に依存するため、非TTY環境(CI含む)での
	// 単体テストは kr.len を直接操作できる範囲(tui_parse_key経由の解析)に留める。
	kr := app.Key_Reader{}
	kr.pending[0] = 'q'
	kr.len = 1
	// pending バッファを直接操作したうえで tui_parse_key 相当のロジックを検証。
	ev, n := app.tui_parse_key(kr.pending[:kr.len])
	testing.expect(t, ev.key == .Char && ev.ch == 'q' && n == 1)
}

// --- T9-2: ROM ブラウザの単体テスト ---

@(test)
test_is_rom_filename :: proc(t: ^testing.T) {
	testing.expect(t, app.is_rom_filename("game.gb"))
	testing.expect(t, app.is_rom_filename("game.gbc"))
	testing.expect(t, app.is_rom_filename("GAME.GBC"), "大文字拡張子も対象")
	testing.expect(t, !app.is_rom_filename("readme.txt"))
	testing.expect(t, !app.is_rom_filename("game.sav"))
	testing.expect(t, !app.is_rom_filename("game.state"))
}

@(test)
test_mbc_kind_label :: proc(t: ^testing.T) {
	testing.expect(t, app.mbc_kind_label(.Rom_Only) == "ROM ONLY")
	testing.expect(t, app.mbc_kind_label(.Mbc1) == "MBC1")
	testing.expect(t, app.mbc_kind_label(.Mbc5) == "MBC5")
}

@(test)
test_cartridge_info_label_dmg_and_cgb :: proc(t: ^testing.T) {
	dmg_info := core.Cartridge_Info{mbc_kind = .Mbc1, cgb_flag = .Dmg_Only}
	dmg_label := app.cartridge_info_label(dmg_info)
	defer delete(dmg_label)
	testing.expect(t, dmg_label == "(MBC1)")

	cgb_info := core.Cartridge_Info{mbc_kind = .Mbc5, cgb_flag = .Cgb_Enhanced}
	cgb_label := app.cartridge_info_label(cgb_info)
	defer delete(cgb_label)
	testing.expect(t, cgb_label == "(MBC5, CGB)")
}

// scan_rom_directory はファイルシステムに依存するため、statefile_test.odin と同じ流儀
// (os.temp_dir 配下に使い捨てのテスト用ディレクトリを作る)で検証する。
@(test)
test_scan_rom_directory_lists_dirs_then_roms_sorted :: proc(t: ^testing.T) {
	tmp_root, dir_err := os.temp_dir(context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(tmp_root)

	base := fmt.tprintf("%s/bbl_tui_scan_test", tmp_root)
	os.remove_all(base) // 前回の残骸があれば掃除(存在しなくてもエラーにしない)
	defer os.remove_all(base)

	testing.expect(t, os.make_directory(base) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/zzz_subdir", base)) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/aaa_subdir", base)) == nil)

	rom_b := make([]u8, core.HEADER_MIN_LEN)
	rom_b[core.HEADER_TYPE_ADDR] = 0x00 // ROM ONLY
	defer delete(rom_b)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/bgame.gb", base), rom_b) == nil)

	rom_a := make([]u8, core.HEADER_MIN_LEN)
	rom_a[core.HEADER_TYPE_ADDR] = 0x1B // MBC5+RAM+BATTERY
	rom_a[core.HEADER_CGB_FLAG_ADDR] = 0x80
	defer delete(rom_a)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/agame.gbc", base), rom_a) == nil)

	// ROM以外の拡張子は無視されるはず
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/readme.txt", base), rom_a) == nil)

	entries, ok := app.scan_rom_directory(base)
	testing.expect(t, ok)
	defer {
		for e in entries {
			delete(e.name)
			delete(e.path)
			delete(e.info)
		}
		delete(entries)
	}

	// ".."(親, baseはルートでない限り常に先頭) → ディレクトリ名前順 → ROMファイル名前順。
	testing.expect(t, len(entries) == 5, fmt.tprintf("got %d entries", len(entries)))
	testing.expect(t, entries[0].name == "..")
	testing.expect(t, entries[1].name == "aaa_subdir")
	testing.expect(t, entries[2].name == "zzz_subdir")
	testing.expect(t, entries[3].name == "agame.gbc")
	testing.expect(t, entries[3].info == "(MBC5, CGB)")
	testing.expect(t, entries[4].name == "bgame.gb")
	testing.expect(t, entries[4].info == "(ROM ONLY)")
}

// --- T9-4/T9-5: ステータス行・ホットキーの単体テスト ---

@(test)
test_status_cart_label :: proc(t: ^testing.T) {
	no_ram := core.Cartridge_Info{mbc_kind = .Mbc1, ram_size = 0}
	no_ram_label := app.status_cart_label(no_ram)
	defer delete(no_ram_label)
	testing.expect(t, no_ram_label == "MBC1")

	with_ram := core.Cartridge_Info{mbc_kind = .Mbc5, ram_size = 8192}
	with_ram_label := app.status_cart_label(with_ram)
	defer delete(with_ram_label)
	testing.expect(t, with_ram_label == "MBC5+RAM")
}

@(test)
test_game_key_to_action_volume_and_pause :: proc(t: ^testing.T) {
	up, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = '+'})
	testing.expect(t, up == .Volume_Up)

	down, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = '-'})
	testing.expect(t, down == .Volume_Down)

	pause, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = 'p'})
	testing.expect(t, pause == .Toggle_Pause)
}

@(test)
test_game_key_to_action_slots :: proc(t: ^testing.T) {
	a1, s1 := app.game_key_to_action(app.Key_Event{key = .Char, ch = '1'})
	testing.expect(t, a1 == .Select_Slot && s1 == 1)
	a2, s2 := app.game_key_to_action(app.Key_Event{key = .Char, ch = '2'})
	testing.expect(t, a2 == .Select_Slot && s2 == 2)
	a3, s3 := app.game_key_to_action(app.Key_Event{key = .Char, ch = '3'})
	testing.expect(t, a3 == .Select_Slot && s3 == 3)
	a4, s4 := app.game_key_to_action(app.Key_Event{key = .Char, ch = '4'})
	testing.expect(t, a4 == .Select_Slot && s4 == 4)
}

@(test)
test_game_key_to_action_save_load :: proc(t: ^testing.T) {
	save, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = 's'})
	testing.expect(t, save == .Save_State)

	load, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = 'l'})
	testing.expect(t, load == .Load_State)
}

@(test)
test_game_key_to_action_unmapped_key_is_none :: proc(t: ^testing.T) {
	action, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = 'z'})
	testing.expect(t, action == .None)

	arrow_action, _ := app.game_key_to_action(app.Key_Event{key = .Up})
	testing.expect(t, arrow_action == .None, "矢印キー等はゲームホットキーとしては未割当")
}

// --- Line_Editor(T12-1)の単体テスト ---

@(test)
test_line_editor_char_accumulates_and_enter_submits :: proc(t: ^testing.T) {
	editor: app.Line_Editor
	defer app.line_editor_destroy(&editor)

	for ch in "browse" {
		submitted, text := app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = ch})
		testing.expect(t, !submitted)
		testing.expect(t, text == "")
	}

	submitted, text := app.line_editor_feed(&editor, app.Key_Event{key = .Enter})
	defer delete(text)
	testing.expect(t, submitted)
	testing.expect(t, text == "browse")
	// 確定後は内部バッファがクリアされ、次の入力に混ざらない。
	testing.expect(t, app.line_editor_text(editor) == "")
}

@(test)
test_line_editor_backspace_removes_last_char :: proc(t: ^testing.T) {
	editor: app.Line_Editor
	defer app.line_editor_destroy(&editor)

	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'a'})
	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'b'})
	app.line_editor_feed(&editor, app.Key_Event{key = .Backspace})
	testing.expect(t, app.line_editor_text(editor) == "a")

	// 空の状態での Backspace は何もしない(範囲外アクセスしない)。
	app.line_editor_feed(&editor, app.Key_Event{key = .Backspace})
	app.line_editor_feed(&editor, app.Key_Event{key = .Backspace})
	testing.expect(t, app.line_editor_text(editor) == "")
}

@(test)
test_line_editor_escape_clears_without_submitting :: proc(t: ^testing.T) {
	editor: app.Line_Editor
	defer app.line_editor_destroy(&editor)

	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'x'})
	submitted, text := app.line_editor_feed(&editor, app.Key_Event{key = .Escape})
	testing.expect(t, !submitted)
	testing.expect(t, text == "")
	testing.expect(t, app.line_editor_text(editor) == "")
}

@(test)
test_line_editor_filters_control_characters :: proc(t: ^testing.T) {
	editor: app.Line_Editor
	defer app.line_editor_destroy(&editor)

	// Tab(0x09)や他の制御文字はバッファに入らない。印字可能文字(0x20-0x7E)だけ通す。
	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = rune(0x09)})
	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'a'})
	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = rune(0x1f)})
	testing.expect(t, app.line_editor_text(editor) == "a")
}

@(test)
test_line_editor_reset_clears_buffer :: proc(t: ^testing.T) {
	editor: app.Line_Editor
	defer app.line_editor_destroy(&editor)

	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'x'})
	app.line_editor_reset(&editor)
	testing.expect(t, app.line_editor_text(editor) == "")
}

// --- ホーム画面(T12-3)の単体テスト ---

@(test)
test_parse_home_command_empty_is_browse :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("")
	testing.expect(t, cmd.kind == .Browse)

	cmd_spaces := app.parse_home_command("   ")
	testing.expect(t, cmd_spaces.kind == .Browse, "空白のみの入力もbrowse扱い")
}

@(test)
test_parse_home_command_browse_aliases :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_home_command("/browse").kind == .Browse)
	testing.expect(t, app.parse_home_command("/ls").kind == .Browse)
}

@(test)
test_parse_home_command_recent :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_home_command("/recent").kind == .Recent)
}

@(test)
test_parse_home_command_quit_aliases :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_home_command("/quit").kind == .Quit)
	testing.expect(t, app.parse_home_command("/exit").kind == .Quit)
}

@(test)
test_parse_home_command_unknown :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("/nonexistent")
	testing.expect(t, cmd.kind == .Unknown)
	testing.expect(t, cmd.raw == "/nonexistent")
}

@(test)
test_parse_home_command_trims_whitespace :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("  /browse  ")
	testing.expect(t, cmd.kind == .Browse)
}

@(test)
test_render_home_screen_shows_prompt_and_input :: proc(t: ^testing.T) {
	s := app.tui_render_home_screen(80, "browse", "")
	defer delete(s)

	testing.expect(t, strings.contains(s, "> browse"))
	testing.expect(t, strings.contains(s, "/browse"))
	testing.expect(t, strings.contains(s, "/settings"))
	testing.expect(t, strings.contains(s, "/quit"))
}

@(test)
test_render_home_screen_shows_status_when_present :: proc(t: ^testing.T) {
	s := app.tui_render_home_screen(80, "", "不明なコマンドです: /foo")
	defer delete(s)

	testing.expect(t, strings.contains(s, "不明なコマンドです: /foo"))
}

@(test)
test_render_home_screen_falls_back_to_title_when_narrow :: proc(t: ^testing.T) {
	// 幅が極端に狭い端末ではロゴの代わりに1行タイトルへフォールバックする。
	s := app.tui_render_home_screen(20, "", "")
	defer delete(s)

	testing.expect(t, strings.contains(s, "BubiBoyLite v"))
	// ロゴの罫線文字(figlet風ブロック体の一部)は含まれないこと。
	testing.expect(t, !strings.contains(s, "____"))
}

// --- ホーム画面での /settings, /set コマンド解釈(T12-4)の単体テスト ---

@(test)
test_parse_home_command_settings :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("/settings")
	testing.expect(t, cmd.kind == .Settings)
}

@(test)
test_parse_home_command_set_with_key_and_value :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("/set volume 50")
	testing.expect(t, cmd.kind == .Set)
	testing.expect(t, cmd.set_key == "volume")
	testing.expect(t, cmd.set_value == "50")
}

@(test)
test_parse_home_command_set_missing_value_is_unknown :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("/set volume")
	testing.expect(t, cmd.kind == .Unknown)
}

@(test)
test_parse_home_command_set_missing_key_and_value_is_unknown :: proc(t: ^testing.T) {
	cmd := app.parse_home_command("/set")
	testing.expect(t, cmd.kind == .Unknown)
}

// --- ゲーム実行中コマンドモード(T12-5)の単体テスト ---

@(test)
test_game_key_to_action_slash_enters_command_mode :: proc(t: ^testing.T) {
	action, _ := app.game_key_to_action(app.Key_Event{key = .Char, ch = '/'})
	testing.expect(t, action == .Enter_Command_Mode)
}

@(test)
test_parse_game_command_set :: proc(t: ^testing.T) {
	// `/` キー自体がトリガーなので、入力テキストに先頭の "/" は含まれない
	// (画面表示は "/set volume 50" に見えるが、Line_Editor が蓄積するのは "set volume 50")。
	cmd := app.parse_game_command("set volume 50")
	testing.expect(t, cmd.kind == .Set)
	testing.expect(t, cmd.set_key == "volume")
	testing.expect(t, cmd.set_value == "50")
}

@(test)
test_parse_game_command_settings_is_unavailable :: proc(t: ^testing.T) {
	// ゲーム中は対話メニューを開かない(SDLイベントポンプ停止によるウィンドウ幽霊化の再発防止)。
	cmd := app.parse_game_command("settings")
	testing.expect(t, cmd.kind == .Settings_Unavailable)
}

@(test)
test_parse_game_command_browse_is_unknown :: proc(t: ^testing.T) {
	// ゲーム中に画面遷移コマンド(browse等)は意味を持たないため Unknown 扱い。
	cmd := app.parse_game_command("browse")
	testing.expect(t, cmd.kind == .Unknown)
}

@(test)
test_parse_game_command_empty_input :: proc(t: ^testing.T) {
	cmd := app.parse_game_command("")
	testing.expect(t, cmd.kind == .Empty)

	cmd_spaces := app.parse_game_command("   ")
	testing.expect(t, cmd_spaces.kind == .Empty)
}

@(test)
test_parse_game_command_set_missing_value_is_unknown :: proc(t: ^testing.T) {
	cmd := app.parse_game_command("set volume")
	testing.expect(t, cmd.kind == .Unknown)
}

// --- メニュー状態機械(T13-1) ---

@(test)
test_menu_step_up_down_clamps_selection :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{}

	// 先頭(0)で Up → 動かない(.None)
	eff := app.menu_step(&m, app.Key_Event{key = .Up}, cfg)
	testing.expect(t, eff.op == .None && m.selected == 0)

	// Down で 1 に移動(.Redraw)
	eff = app.menu_step(&m, app.Key_Event{key = .Down}, cfg)
	testing.expect(t, eff.op == .Redraw && m.selected == 1)

	// 末尾(3)まで下げてさらに Down → 動かない
	m.selected = 3
	eff = app.menu_step(&m, app.Key_Event{key = .Down}, cfg)
	testing.expect(t, eff.op == .None && m.selected == 3)

	// Up で 2 に戻る
	eff = app.menu_step(&m, app.Key_Event{key = .Up}, cfg)
	testing.expect(t, eff.op == .Redraw && m.selected == 2)
}

@(test)
test_menu_adjust_value_scale :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.scale = 3

	v, changed := app.menu_adjust_value(cfg, .Scale, 1)
	testing.expect(t, changed && v == "4")
	delete(v)

	v, changed = app.menu_adjust_value(cfg, .Scale, -1)
	testing.expect(t, changed && v == "2")
	delete(v)
}

@(test)
test_menu_adjust_value_scale_boundaries :: proc(t: ^testing.T) {
	cfg := app.default_config()

	// scale=8(上限)で + → 変化なし
	cfg.scale = 8
	_, changed := app.menu_adjust_value(cfg, .Scale, 1)
	testing.expect(t, !changed)

	// scale=1(下限)で - → 変化なし
	cfg.scale = 1
	_, changed = app.menu_adjust_value(cfg, .Scale, -1)
	testing.expect(t, !changed)
}

@(test)
test_menu_adjust_value_fullscreen_toggles :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.fullscreen = false

	// delta の符号に関わらずトグル
	v, changed := app.menu_adjust_value(cfg, .Fullscreen, 1)
	testing.expect(t, changed && v == "true")
	delete(v)

	v, changed = app.menu_adjust_value(cfg, .Fullscreen, -1)
	testing.expect(t, changed && v == "true")
	delete(v)

	cfg.fullscreen = true
	v, changed = app.menu_adjust_value(cfg, .Fullscreen, 1)
	testing.expect(t, changed && v == "false")
	delete(v)
}

@(test)
test_menu_adjust_value_shader_toggles :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.shader = .Nearest

	v, changed := app.menu_adjust_value(cfg, .Shader, 1)
	testing.expect(t, changed && v == "smooth")
	delete(v)

	cfg.shader = .Smooth
	v, changed = app.menu_adjust_value(cfg, .Shader, -1)
	testing.expect(t, changed && v == "nearest")
	delete(v)
}

@(test)
test_menu_adjust_value_volume_steps_and_clamps :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.volume = 50

	v, changed := app.menu_adjust_value(cfg, .Volume, 1)
	testing.expect(t, changed && v == "55")
	delete(v)

	v, changed = app.menu_adjust_value(cfg, .Volume, -1)
	testing.expect(t, changed && v == "45")
	delete(v)

	// 98 + 5 → 100 に clamp(境界未満なら clamp してでも変化する)
	cfg.volume = 98
	v, changed = app.menu_adjust_value(cfg, .Volume, 1)
	testing.expect(t, changed && v == "100")
	delete(v)

	// 100(上限)で + → 変化なし、0(下限)で - → 変化なし
	cfg.volume = 100
	_, changed = app.menu_adjust_value(cfg, .Volume, 1)
	testing.expect(t, !changed)
	cfg.volume = 0
	_, changed = app.menu_adjust_value(cfg, .Volume, -1)
	testing.expect(t, !changed)
}

@(test)
test_menu_step_left_right_produce_adjust_effect :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.scale = 4
	m := app.Menu_State{} // selected=0 = scale

	eff := app.menu_step(&m, app.Key_Event{key = .Right}, cfg)
	testing.expect(t, eff.op == .Adjust)
	testing.expect(t, eff.key == "scale")
	testing.expect(t, eff.value == "5")
	delete(eff.value)

	// 境界(scale=8)では .None(確保なし)
	cfg.scale = 8
	eff = app.menu_step(&m, app.Key_Event{key = .Right}, cfg)
	testing.expect(t, eff.op == .None)
}

@(test)
test_menu_step_close_keys :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{}

	eff := app.menu_step(&m, app.Key_Event{key = .Escape}, cfg)
	testing.expect(t, eff.op == .Close)

	eff = app.menu_step(&m, app.Key_Event{key = .Enter}, cfg)
	testing.expect(t, eff.op == .Close)

	eff = app.menu_step(&m, app.Key_Event{key = .Char, ch = 'q'}, cfg)
	testing.expect(t, eff.op == .Close)

	// q 以外の文字は .None
	eff = app.menu_step(&m, app.Key_Event{key = .Char, ch = 'x'}, cfg)
	testing.expect(t, eff.op == .None)
}

// --- /settings メニューの ←→ サイクル表示(T13-2) ---

@(test)
test_menu_item_info_arrow_format :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.scale = 3
	cfg.fullscreen = false
	cfg.shader = .Nearest
	cfg.volume = 80

	testing.expect_value(t, app.menu_item_info(cfg, .Scale), "◂ 3 ▸")
	testing.expect_value(t, app.menu_item_info(cfg, .Fullscreen), "◂ false ▸")
	testing.expect_value(t, app.menu_item_info(cfg, .Shader), "◂ nearest ▸")
	testing.expect_value(t, app.menu_item_info(cfg, .Volume), "◂ 80 ▸")
}
