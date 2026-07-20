package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "bbl:app"
import core "bbl:core"
import sdl2 "vendor:sdl2"

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
test_parse_key_tab :: proc(t: ^testing.T) {
	ev, n := app.tui_parse_key([]u8{0x09})
	testing.expect(t, ev.key == .Tab && n == 1)
}

@(test)
test_parse_key_empty_buffer :: proc(t: ^testing.T) {
	ev, n := app.tui_parse_key([]u8{})
	testing.expect(t, ev.key == .None && n == 0)
}

// --- リスト画面コンテンツ(T14-2、旧 tui_render_frame テストを shell_content_list へ移行) ---

@(test)
test_shell_content_list_heading_items_and_info :: proc(t: ^testing.T) {
	items := []app.List_Item{{label = "game1.gbc", info = "(MBC5, CGB)"}, {label = "game2.gb", info = "(MBC1)"}}
	content := app.shell_content_list("BubiBoyLite v0.1.0 — ROM を選択してください", items, 0, 21, 80)
	defer app.shell_lines_destroy(content)

	testing.expect_value(t, len(content), 4) // heading + 空行 + 項目2
	testing.expect(t, strings.contains(content[0], "ROM を選択してください"))
	testing.expect_value(t, content[1], "")
	testing.expect(t, strings.contains(content[2], "▸ game1.gbc"))
	testing.expect(t, strings.contains(content[2], "(MBC5, CGB)"))
	testing.expect(t, strings.contains(content[3], "  game2.gb"))
	testing.expect(t, !strings.contains(content[3], "▸"))
}

@(test)
test_shell_content_list_marks_selected_row :: proc(t: ^testing.T) {
	items := []app.List_Item{{label = "one"}, {label = "two"}, {label = "three"}}
	content := app.shell_content_list("h", items, 1, 21, 80)
	defer app.shell_lines_destroy(content)

	for line in content {
		if strings.contains(line, "two") {
			testing.expect(t, strings.contains(line, "▸"))
		}
		if strings.contains(line, "one") || strings.contains(line, "three") {
			testing.expect(t, !strings.contains(line, "▸"))
		}
	}
}

@(test)
test_shell_content_list_scroll_window_keeps_selection_visible :: proc(t: ^testing.T) {
	items := make([]app.List_Item, 10)
	defer delete(items)
	labels := [10]string{"i0", "i1", "i2", "i3", "i4", "i5", "i6", "i7", "i8", "i9"}
	for i in 0 ..< 10 {
		items[i] = app.List_Item{label = labels[i]}
	}
	// avail_rows=5 → 項目枠は 3 行。selected=7 なら i5..i7 の窓が見え、i0 は見えない。
	content := app.shell_content_list("h", items, 7, 5, 80)
	defer app.shell_lines_destroy(content)

	joined := strings.join(content, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "▸ i7"))
	testing.expect(t, strings.contains(joined, "i5"))
	testing.expect(t, !strings.contains(joined, "i0"))
	testing.expect(t, !strings.contains(joined, "i8"))
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

// T15-1: 生ホットキー(game_key_to_action/Game_Action、+,-,1-4,s,l,p)は完全に廃止された。
// 「ゲーム中も同じモードで動くこと」の要望により、これらの文字キーは常に入力行へ行く
// (test_game_input_route_now_playing_chars_always_go_to_editor 参照、下記
// 「ゲーム中入力ルーティング」節)。旧テスト4本はここに置き換える形で削除した。

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

@(test)
test_line_editor_set_replaces_buffer :: proc(t: ^testing.T) {
	editor: app.Line_Editor
	defer app.line_editor_destroy(&editor)

	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'x'})
	app.line_editor_feed(&editor, app.Key_Event{key = .Char, ch = 'y'})
	app.line_editor_set(&editor, "/browse")
	testing.expect(t, app.line_editor_text(editor) == "/browse")

	// 再度呼ぶと前回分は完全に置き換わる(残らない)。
	app.line_editor_set(&editor, "/help")
	testing.expect(t, app.line_editor_text(editor) == "/help")
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
test_shell_content_home_shows_logo_and_commands :: proc(t: ^testing.T) {
	// T14-2: ホーム画面のコンテンツ(旧 tui_render_home_screen のテストを移行)。
	// 入力行・ステータス行はシェル側(Shell_Frame)の担当になったためここには含まれない。
	// T22-*: 空入力ならロゴ+コマンド一覧(コマンドレジストリ由来)を表示する。
	content := app.shell_content_home(80, "")
	defer app.shell_lines_destroy(content)

	joined := strings.join(content, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "____")) // ロゴ(figlet風ブロック体)
	testing.expect(t, strings.contains(joined, "/browse"))
	testing.expect(t, strings.contains(joined, "/settings"))
	testing.expect(t, strings.contains(joined, "/quit"))
	testing.expect(t, strings.contains(joined, "/help"))
	// ゲーム専用コマンドはホームには出ない。
	testing.expect(t, !strings.contains(joined, "/pause"))
}

@(test)
test_shell_content_home_falls_back_to_title_when_narrow :: proc(t: ^testing.T) {
	// 幅が極端に狭い端末ではロゴの代わりに1行タイトルへフォールバックする。
	content := app.shell_content_home(20, "")
	defer app.shell_lines_destroy(content)

	joined := strings.join(content, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "BubiBoyLite v"))
	testing.expect(t, !strings.contains(joined, "____"))
}

@(test)
test_shell_content_home_nonempty_input_narrows_and_omits_logo :: proc(t: ^testing.T) {
	// T22-*: 入力があるとロゴを省いて絞り込みリストのみを表示する(縦幅確保のため)。
	content := app.shell_content_home(80, "/se")
	defer app.shell_lines_destroy(content)

	joined := strings.join(content, "\n", context.temp_allocator)
	testing.expect(t, !strings.contains(joined, "____"))
	testing.expect(t, strings.contains(joined, "/settings"))
	testing.expect(t, !strings.contains(joined, "/browse"))
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

@(test)
test_parse_home_command_help :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_home_command("/help").kind == .Help)
}

// --- ゲーム実行中コマンドモード(T12-5)の単体テスト ---

// T15-1: `/` が専用モードへの唯一のトリガーだった仕組み(game_key_to_action の
// .Enter_Command_Mode)は廃止された。`/` は他の文字と同様、常に入力行へ追加される
// (test_game_input_route_now_playing_chars_always_go_to_editor の書き換えテスト参照)。

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
test_parse_game_command_settings_opens_menu :: proc(t: ^testing.T) {
	// T13-4 で仕様変更: ゲーム中の settings はオーバーレイメニュー(状態機械+毎フレーム1ステップ、
	// SDLポンプを止めない)を開く .Settings を返す(T12-5 の Settings_Unavailable は廃止)。
	cmd := app.parse_game_command("settings")
	testing.expect(t, cmd.kind == .Settings)

	// 引数付きの settings は未対応 → Unknown
	cmd_arg := app.parse_game_command("settings foo")
	testing.expect(t, cmd_arg.kind == .Unknown)
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

	// 末尾(4 = トップ5項目: scale/shader/volume + サブメニュー入口2つ、T-keybindings)まで
	// 下げてさらに Down → 動かない
	m.selected = app.TOP_MENU_ITEM_COUNT - 1
	eff = app.menu_step(&m, app.Key_Event{key = .Down}, cfg)
	testing.expect(t, eff.op == .None && m.selected == app.TOP_MENU_ITEM_COUNT - 1)

	// Up で1つ戻る
	eff = app.menu_step(&m, app.Key_Event{key = .Up}, cfg)
	testing.expect(t, eff.op == .Redraw && m.selected == app.TOP_MENU_ITEM_COUNT - 2)
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

	// T-keybindings: Enter はサブメニュー入口への降下専用になったため、value項目(selected=0
	// =scale)の上では .None(閉じない)。
	eff = app.menu_step(&m, app.Key_Event{key = .Enter}, cfg)
	testing.expect(t, eff.op == .None)

	eff = app.menu_step(&m, app.Key_Event{key = .Char, ch = 'q'}, cfg)
	testing.expect(t, eff.op == .Close)

	// q 以外の文字は .None
	eff = app.menu_step(&m, app.Key_Event{key = .Char, ch = 'x'}, cfg)
	testing.expect(t, eff.op == .None)
}

// --- サブメニュー方式(T-keybindings): Top ⇄ Keyboard/Controller の階層遷移 ---

@(test)
test_menu_step_top_enter_on_submenu_entry_descends :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{selected = app.TOP_MENU_KEYBOARD_INDEX}

	eff := app.menu_step(&m, app.Key_Event{key = .Enter}, cfg)
	testing.expect(t, eff.op == .Redraw)
	testing.expect(t, m.level == .Keyboard)
	testing.expect(t, m.selected == 0)

	// Controller 側も同様。
	m2 := app.Menu_State{selected = app.TOP_MENU_CONTROLLER_INDEX}
	eff2 := app.menu_step(&m2, app.Key_Event{key = .Enter}, cfg)
	testing.expect(t, eff2.op == .Redraw)
	testing.expect(t, m2.level == .Controller)
	testing.expect(t, m2.selected == 0)
}

@(test)
test_menu_step_top_left_right_on_submenu_entry_is_none :: proc(t: ^testing.T) {
	// サブメニュー入口の上では←→は無効(scale/shader/volumeのみ値サイクル対象)。
	cfg := app.default_config()
	m := app.Menu_State{selected = app.TOP_MENU_KEYBOARD_INDEX}
	eff := app.menu_step(&m, app.Key_Event{key = .Right}, cfg)
	testing.expect(t, eff.op == .None)
	testing.expect(t, m.level == .Top, "←→では降下しない")
}

@(test)
test_menu_step_keyboard_up_down_clamps_over_8_buttons :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{level = .Keyboard}

	eff := app.menu_step(&m, app.Key_Event{key = .Up}, cfg)
	testing.expect(t, eff.op == .None && m.selected == 0)

	m.selected = 7 // gb_button_order は8要素(Up/Down/Left/Right/A/B/Start/Select)
	eff = app.menu_step(&m, app.Key_Event{key = .Down}, cfg)
	testing.expect(t, eff.op == .None && m.selected == 7)

	m.selected = 3
	eff = app.menu_step(&m, app.Key_Event{key = .Down}, cfg)
	testing.expect(t, eff.op == .Redraw && m.selected == 4)
}

@(test)
test_menu_step_keyboard_left_right_adjusts_key_binding :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{level = .Keyboard, selected = 0} // gb_button_order[0] == .Up

	eff := app.menu_step(&m, app.Key_Event{key = .Right}, cfg)
	testing.expect(t, eff.op == .Adjust)
	testing.expect_value(t, eff.key, "key_up")
	testing.expect(t, eff.value != "")
	delete(eff.value)
}

@(test)
test_menu_step_controller_left_right_adjusts_pad_binding :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{level = .Controller, selected = 4} // gb_button_order[4] == .A

	eff := app.menu_step(&m, app.Key_Event{key = .Right}, cfg)
	testing.expect(t, eff.op == .Adjust)
	testing.expect_value(t, eff.key, "pad_a")
	testing.expect(t, eff.value != "")
	delete(eff.value)
}

@(test)
test_menu_step_keyboard_escape_returns_to_top_at_keyboard_entry :: proc(t: ^testing.T) {
	cfg := app.default_config()
	m := app.Menu_State{level = .Keyboard, selected = 5}

	eff := app.menu_step(&m, app.Key_Event{key = .Escape}, cfg)
	testing.expect(t, eff.op == .Redraw, "サブから戻るときはCloseではなくRedraw")
	testing.expect(t, m.level == .Top)
	testing.expect(t, m.selected == app.TOP_MENU_KEYBOARD_INDEX, "元のサブメニュー入口indexへ復元")
}

@(test)
test_menu_step_controller_q_and_enter_return_to_top_at_controller_entry :: proc(t: ^testing.T) {
	cfg := app.default_config()

	m := app.Menu_State{level = .Controller, selected = 2}
	eff := app.menu_step(&m, app.Key_Event{key = .Char, ch = 'q'}, cfg)
	testing.expect(t, eff.op == .Redraw)
	testing.expect(t, m.level == .Top)
	testing.expect(t, m.selected == app.TOP_MENU_CONTROLLER_INDEX)

	m2 := app.Menu_State{level = .Controller, selected = 1}
	eff2 := app.menu_step(&m2, app.Key_Event{key = .Enter}, cfg)
	testing.expect(t, eff2.op == .Redraw)
	testing.expect(t, m2.level == .Top)
	testing.expect(t, m2.selected == app.TOP_MENU_CONTROLLER_INDEX)
}

@(test)
test_menu_state_destroy_resets_level_to_top :: proc(t: ^testing.T) {
	m := app.Menu_State{level = .Keyboard, selected = 3}
	app.menu_state_destroy(&m)
	testing.expect(t, m.level == .Top)
}

// --- cycle_next(T-keybindings、純粋関数) ---

@(test)
test_cycle_next_advances_and_wraps_forward :: proc(t: ^testing.T) {
	list := []int{10, 20, 30}
	testing.expect(t, app.cycle_next(list, 10, 1) == 20)
	testing.expect(t, app.cycle_next(list, 20, 1) == 30)
	testing.expect(t, app.cycle_next(list, 30, 1) == 10, "末尾から先頭へラップ")
}

@(test)
test_cycle_next_retreats_and_wraps_backward :: proc(t: ^testing.T) {
	list := []int{10, 20, 30}
	testing.expect(t, app.cycle_next(list, 30, -1) == 20)
	testing.expect(t, app.cycle_next(list, 20, -1) == 10)
	testing.expect(t, app.cycle_next(list, 10, -1) == 30, "先頭から末尾へラップ")
}

@(test)
test_cycle_next_current_not_in_list_picks_edge_by_direction :: proc(t: ^testing.T) {
	list := []int{10, 20, 30}
	testing.expect(t, app.cycle_next(list, 999, 1) == 10, "候補外なら+方向はlist[0]")
	testing.expect(t, app.cycle_next(list, 999, -1) == 30, "候補外なら-方向はlist[len-1]")
}

@(test)
test_cycle_next_empty_list_returns_current :: proc(t: ^testing.T) {
	list := []int{}
	testing.expect(t, app.cycle_next(list, 42, 1) == 42)
}

// --- キーボード/コントローラー サイクル候補リスト(T-keybindings) ---

@(test)
test_keyboard_cycle_keycodes_excludes_reserved_shortcuts :: proc(t: ^testing.T) {
	keys := app.keyboard_cycle_keycodes()
	defer delete(keys)
	testing.expect(t, len(keys) > 0)
	for kc in keys {
		testing.expect(t, !app.is_reserved_shortcut_key(kc), "F1-F5/F7/Escapeは候補に出ないはず")
	}
}

@(test)
test_keyboard_cycle_keycodes_all_have_names :: proc(t: ^testing.T) {
	// 往復可能性(bbl.ini書き戻し→再読込)のため、全候補が GetKeyName != "" であること。
	keys := app.keyboard_cycle_keycodes()
	defer delete(keys)
	for kc in keys {
		name := sdl2.GetKeyName(kc)
		testing.expect(t, name != "", "候補は全てGetKeyNameが空文字でないはず")
	}
}

@(test)
test_controller_cycle_buttons_excludes_invalid_and_max :: proc(t: ^testing.T) {
	buttons := app.controller_cycle_buttons()
	defer delete(buttons)
	testing.expect(t, len(buttons) > 0)
	for b in buttons {
		testing.expect(t, b != .INVALID)
		testing.expect(t, b != .MAX)
	}
}

@(test)
test_controller_cycle_buttons_all_have_names :: proc(t: ^testing.T) {
	buttons := app.controller_cycle_buttons()
	defer delete(buttons)
	for b in buttons {
		name := sdl2.GameControllerGetStringForButton(b)
		testing.expect(t, name != "")
	}
}

// --- 設定メニューの項目リスト生成(T-keybindings): Top/Keyboard/Controller ---

@(test)
test_settings_menu_items_top_has_five_entries_with_submenu_arrows :: proc(t: ^testing.T) {
	cfg := app.default_config()
	items := app.settings_menu_items(cfg, .Top)
	defer delete(items)

	testing.expect_value(t, len(items), app.TOP_MENU_ITEM_COUNT)
	testing.expect_value(t, items[0].label, "scale")
	testing.expect_value(t, items[app.TOP_MENU_KEYBOARD_INDEX].label, "キーボード割当")
	testing.expect_value(t, items[app.TOP_MENU_KEYBOARD_INDEX].info, "▸")
	testing.expect_value(t, items[app.TOP_MENU_CONTROLLER_INDEX].label, "コントローラー割当")
	testing.expect_value(t, items[app.TOP_MENU_CONTROLLER_INDEX].info, "▸")
}

@(test)
test_settings_menu_items_keyboard_lists_all_gb_buttons :: proc(t: ^testing.T) {
	cfg := app.default_config()
	items := app.settings_menu_items(cfg, .Keyboard)
	defer delete(items)

	testing.expect_value(t, len(items), 8)
	testing.expect_value(t, items[0].label, "key_up")
	testing.expect(t, strings.contains(items[0].info, "Up"))
}

@(test)
test_settings_menu_items_controller_lists_all_gb_buttons :: proc(t: ^testing.T) {
	cfg := app.default_config()
	items := app.settings_menu_items(cfg, .Controller)
	defer delete(items)

	testing.expect_value(t, len(items), 8)
	testing.expect_value(t, items[0].label, "pad_up")
	testing.expect(t, strings.contains(items[0].info, "dpup"))
}

@(test)
test_settings_menu_heading_and_hint_differ_by_level :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(app.settings_menu_heading(.Top), "設定"))
	testing.expect(t, strings.contains(app.settings_menu_heading(.Keyboard), "キーボード割当"))
	testing.expect(t, strings.contains(app.settings_menu_heading(.Controller), "コントローラー割当"))

	testing.expect(t, strings.contains(app.settings_menu_hint(.Top), "Enter 開く"))
	testing.expect(t, strings.contains(app.settings_menu_hint(.Keyboard), "Esc 戻る"))
	testing.expect(t, strings.contains(app.settings_menu_hint(.Controller), "Esc 戻る"))
}

// --- /settings メニューの ←→ サイクル表示(T13-2) ---

@(test)
test_menu_item_info_arrow_format :: proc(t: ^testing.T) {
	cfg := app.default_config()
	cfg.scale = 3
	cfg.shader = .Nearest
	cfg.volume = 80

	testing.expect_value(t, app.menu_item_info(cfg, .Scale), "◂ 3 ▸")
	testing.expect_value(t, app.menu_item_info(cfg, .Shader), "◂ nearest ▸")
	testing.expect_value(t, app.menu_item_info(cfg, .Volume), "◂ 80 ▸")
}

// --- ゲーム中コンテンツ(T14-4、T13-3 のオーバーレイ描画テストは撤去して置き換え) ---

// T16-1: shell_content_now_playing から ROM名/状態/fps/音量/スロットの詳細行を削除した
// (ステータス行と完全に重複表示だったため)。T18-2で一旦、見出し行を「BubiBoyLite v...」
// から ROM名+カートリッジ種別に変更したが、これはユーザーの意図(固定フッターの中で
// 別行にしてほしい)の誤解だったため、T19-3で見出し行自体を削除して巻き戻した(ROM名+
// カートリッジ種別は固定フッターのmeta行、T19-1/T19-2、へ移設済み)。
// 以下2本はその仕様(見出し行なし、先頭の空行+メッセージログのみ)に書き換え。

@(test)
test_shell_content_now_playing_panel :: proc(t: ^testing.T) {
	log: app.Message_Log
	defer app.message_log_destroy(&log)
	app.message_log_append(&log, "Volume 80%")
	app.message_log_append(&log, "State saved to slot 2")

	s := app.Status_Line {
		enabled    = true,
		rom_name   = "game.gbc",
		cart_label = "MBC5+RAM",
		last_fps   = 59.7,
		log        = &log,
	}
	info := app.Game_Panel_Info {
		volume       = 80,
		slot         = 2,
		double_speed = false,
		paused       = false,
	}
	content := app.shell_content_now_playing(&s, info, 21)
	defer app.shell_lines_destroy(content)

	joined := strings.join(content, "\n", context.temp_allocator)
	// T19-3: ROM名+カートリッジ種別は固定フッターのmeta行に移設済みなので、コンテンツ
	// 領域には出てこない(回帰防止)。
	testing.expect(t, !strings.contains(joined, "game.gbc"))
	testing.expect(t, !strings.contains(joined, "MBC5+RAM"))
	// 状態/fps/音量/スロットの詳細行は引き続き出ない(ステータス行の担当、回帰防止)。
	testing.expect(t, !strings.contains(joined, "59.7"))
	testing.expect(t, !strings.contains(joined, "▶ 実行中"))
	// メッセージログ直近分(古→新)は引き続き含まれる。
	testing.expect(t, strings.contains(joined, "─ メッセージ ─"))
	testing.expect(t, strings.contains(joined, "Volume 80%"))
	testing.expect(t, strings.contains(joined, "State saved to slot 2"))

	// destroy は呼ばない(rom_name 等に静的リテラルを使っており、heap free すると壊れるため)
}

@(test)
test_shell_content_now_playing_log_capped_to_rows :: proc(t: ^testing.T) {
	log: app.Message_Log
	defer app.message_log_destroy(&log)
	for i in 0 ..< 10 {
		app.message_log_append(&log, fmt.tprintf("log-%d", i))
	}
	s := app.Status_Line {
		enabled  = true,
		rom_name = "r",
		log      = &log,
	}
	info := app.Game_Panel_Info {
		paused = true,
	}
	// avail_rows=12 → 先頭の空行1行、残り(空行+見出し2行分を差し引いた)= 12-1-2=9件、
	// 最新側 log-1..log-9 の9件が表示される(log-0のみ溢れて非表示)。T19-3で見出し行を
	// 削除したことで、削除前(8件、log-0/log-1が非表示)より表示可能行数が1件増えた。
	content := app.shell_content_now_playing(&s, info, 12)
	defer app.shell_lines_destroy(content)

	joined := strings.join(content, "\n", context.temp_allocator)
	// paused/double_speed 等の詳細行はもう出力されない(回帰防止)。
	testing.expect(t, !strings.contains(joined, "一時停止"))
	testing.expect(t, len(content) <= 12)
	testing.expect(t, strings.contains(joined, "log-9"))
	testing.expect(t, strings.contains(joined, "log-1"))
	testing.expect(t, !strings.contains(joined, "log-0"))

	// destroy は呼ばない(rom_name 等に静的リテラルを使っており、heap free すると壊れるため)
}

// T18-1: 実機でユーザーから「ステータス行に詰め込みすぎ」との指摘を受け、ROM名・
// カートリッジ種別(→ 固定フッターのmeta行、T19-1/T19-2で最終的に移動)とコマンド実行
// 結果(last_message、→ コンテンツ領域のメッセージログに既出のため重複表示をやめた)を
// status_line_format から削除し、fps/vol/slot/警告のみの簡潔な形式にした。
// 「双速」→「2倍速」(T18-1)の表記変更を経て、T19-4で「2倍速で実行なんてしていない」
// というユーザー指摘を受け、CPUクロック倍速モードの表示自体をステータス行から削除した
// (double_speed 引数もシグネチャから削除。emu.bus.double_speed 自体は削除していない)。
@(test)
test_status_line_format_contents :: proc(t: ^testing.T) {
	s := app.Status_Line {
		enabled    = true,
		rom_name   = "game.gbc",
		cart_label = "MBC5+RAM",
	}
	line := app.status_line_format(s, 59.7, 80, 2, false)
	testing.expect(t, strings.contains(line, "▶"))
	testing.expect(t, strings.contains(line, "59.7 fps"))
	testing.expect(t, strings.contains(line, "vol 80%"))
	testing.expect(t, strings.contains(line, "slot 2"))
	// CPU倍速モードの表示は削除済み(T19-4、回帰防止)。
	testing.expect(t, !strings.contains(line, "2倍速"))
	testing.expect(t, !strings.contains(line, "双速"))
	// ROM名・カートリッジ種別は固定フッターのmeta行へ移動済みなので、ステータス行には
	// 出てこない(回帰防止: 再度詰め込まれていないことを確認)。
	testing.expect(t, !strings.contains(line, "game.gbc"))
	testing.expect(t, !strings.contains(line, "MBC5+RAM"))

	paused_line := app.status_line_format(s, 0.0, 80, 2, true)
	testing.expect(t, strings.contains(paused_line, "⏸"))
	testing.expect(t, !strings.contains(paused_line, "2倍速"))
	testing.expect(t, !strings.contains(paused_line, "双速"))
}

@(test)
test_status_line_format_omits_last_message :: proc(t: ^testing.T) {
	// コマンド実行結果はコンテンツ領域のメッセージログに既に表示されるため、ステータス
	// 行には重複させない(T18-1)。
	s := app.Status_Line {
		enabled      = true,
		rom_name     = "game.gbc",
		cart_label   = "MBC5+RAM",
		last_message = "State loaded from slot 1",
	}
	line := app.status_line_format(s, 59.0, 80, 1, false)
	testing.expect(t, !strings.contains(line, "State loaded from slot 1"))
}

// --- parse_game_command 拡張(T13-4) ---

@(test)
test_parse_game_command_pause_resume :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_game_command("pause").kind == .Pause)
	testing.expect(t, app.parse_game_command("resume").kind == .Resume)
	testing.expect(t, app.parse_game_command("pause now").kind == .Unknown)
}

@(test)
test_parse_game_command_save_load_with_optional_slot :: proc(t: ^testing.T) {
	save := app.parse_game_command("save")
	testing.expect(t, save.kind == .Save_State && save.slot == 0)

	save2 := app.parse_game_command("save 2")
	testing.expect(t, save2.kind == .Save_State && save2.slot == 2)

	load := app.parse_game_command("load")
	testing.expect(t, load.kind == .Load_State && load.slot == 0)

	load3 := app.parse_game_command("load 3")
	testing.expect(t, load3.kind == .Load_State && load3.slot == 3)

	// 範囲外・非数値スロットは Unknown
	testing.expect(t, app.parse_game_command("save 5").kind == .Unknown)
	testing.expect(t, app.parse_game_command("load abc").kind == .Unknown)
}

@(test)
test_parse_game_command_slot_requires_valid_arg :: proc(t: ^testing.T) {
	slot3 := app.parse_game_command("slot 3")
	testing.expect(t, slot3.kind == .Select_Slot && slot3.slot == 3)

	// slot は引数必須、0/5/非数値は Unknown
	testing.expect(t, app.parse_game_command("slot").kind == .Unknown)
	testing.expect(t, app.parse_game_command("slot 0").kind == .Unknown)
	testing.expect(t, app.parse_game_command("slot 5").kind == .Unknown)
	testing.expect(t, app.parse_game_command("slot x").kind == .Unknown)
}

@(test)
test_parse_game_command_quit_aliases :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_game_command("quit").kind == .Quit)
	testing.expect(t, app.parse_game_command("exit").kind == .Quit)
	testing.expect(t, app.parse_game_command("quit now").kind == .Unknown)
}

@(test)
test_parse_game_command_reset :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_game_command("reset").kind == .Reset)
	testing.expect(t, app.parse_game_command("/reset").kind == .Reset)
	testing.expect(t, app.parse_game_command("reset now").kind == .Unknown)
}

@(test)
test_parse_game_command_help :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_game_command("help").kind == .Help)
	testing.expect(t, app.parse_game_command("/help").kind == .Help)
	testing.expect(t, app.parse_game_command("help me").kind == .Unknown)
}

// --- 固定レイアウトシェル(T14-1) ---

@(test)
test_render_shell_row_count_and_structure :: proc(t: ^testing.T) {
	content := []string{"line A", "line B"}
	f := app.Shell_Frame{cols = 40, rows = 10, content = content, status = "status here", input = "abc", hint = "hint"}
	s := app.tui_render_shell(f)
	defer delete(s)

	// CURSOR_HOME 開始、改行はちょうど rows-1 個(最下行に改行なし)、行クリアは rows 個。
	testing.expect(t, strings.has_prefix(s, "\x1b[H"))
	testing.expect_value(t, strings.count(s, "\n"), 9)
	testing.expect_value(t, strings.count(s, "\x1b[K"), 10)

	// コンテンツ・区切り線・ステータス・入力行が含まれる。
	testing.expect(t, strings.contains(s, "line A"))
	testing.expect(t, strings.contains(s, "line B"))
	testing.expect(t, strings.contains(s, "───"))
	testing.expect(t, strings.contains(s, "status here"))
	testing.expect(t, strings.contains(s, "> abc_"))
	testing.expect(t, strings.contains(s, "hint"))
	testing.expect(t, !strings.has_suffix(s, "\n"))
}

@(test)
test_render_shell_truncates_content_to_available_rows :: proc(t: ^testing.T) {
	// rows=7、SHELL_RESERVED_ROWS=4(区切り線+meta行+ステータス行+入力行、T19-1)なので
	// コンテンツ領域は 3 行。4行目以降は切り捨てられる。
	content := []string{"c0", "c1", "c2", "c3-overflow"}
	f := app.Shell_Frame{cols = 40, rows = 7, content = content}
	s := app.tui_render_shell(f)
	defer delete(s)
	testing.expect(t, strings.contains(s, "c2"))
	testing.expect(t, !strings.contains(s, "c3-overflow"))
	testing.expect_value(t, strings.count(s, "\n"), 6)
}

@(test)
test_render_shell_meta_row_between_separator_and_status :: proc(t: ^testing.T) {
	// T19-1: 区切り線の直後・ステータス行の直前に meta 行(ゲーム中はROM名+カートリッジ
	// 種別)が1行入る。
	f := app.Shell_Frame {
		cols   = 40,
		rows   = 8,
		meta   = "rom.gbc  MBC5+RAM",
		status = "status here",
		input  = "abc",
	}
	s := app.tui_render_shell(f)
	defer delete(s)

	body, _ := strings.replace_all(s, "\x1b[H", "", context.temp_allocator)
	body, _ = strings.replace_all(body, "\x1b[K", "", context.temp_allocator)
	lines := strings.split_lines(body, context.temp_allocator)
	testing.expect_value(t, len(lines), 8)
	// 最後の4行が 区切り線/meta/status/input の順(SHELL_RESERVED_ROWS=4)。
	testing.expect(t, strings.has_prefix(lines[4], "───"))
	testing.expect(t, strings.contains(lines[5], "rom.gbc  MBC5+RAM"))
	testing.expect(t, strings.contains(lines[6], "status here"))
	testing.expect(t, strings.contains(lines[7], "> abc_"))
}

@(test)
test_render_shell_empty_meta_is_blank_row :: proc(t: ^testing.T) {
	// meta を指定しない(ホーム/ブラウザ/設定画面)場合は空行になるだけで、レイアウト自体は
	// 崩れない(T19-1)。
	f := app.Shell_Frame{cols = 40, rows = 8, status = "status here", input = "abc"}
	s := app.tui_render_shell(f)
	defer delete(s)

	body, _ := strings.replace_all(s, "\x1b[H", "", context.temp_allocator)
	body, _ = strings.replace_all(body, "\x1b[K", "", context.temp_allocator)
	lines := strings.split_lines(body, context.temp_allocator)
	testing.expect_value(t, len(lines), 8)
	testing.expect_value(t, strings.trim_space(lines[5]), "")
}

@(test)
test_render_shell_pads_every_line_to_width :: proc(t: ^testing.T) {
	f := app.Shell_Frame{cols = 20, rows = 5, content = []string{"a very long content line that overflows"}, status = "s", input = "", hint = ""}
	s := app.tui_render_shell(f)
	defer delete(s)

	body, _ := strings.replace_all(s, "\x1b[H", "", context.temp_allocator)
	body, _ = strings.replace_all(body, "\x1b[K", "", context.temp_allocator)
	lines := strings.split_lines(body, context.temp_allocator)
	testing.expect_value(t, len(lines), 5)
	for line in lines {
		testing.expect_value(t, app.display_width(line), 19) // cols-1 幅ちょうど(打ち切り+パディング)
	}
}

@(test)
test_render_shell_hint_right_aligned_and_dropped_when_narrow :: proc(t: ^testing.T) {
	f := app.Shell_Frame{cols = 40, rows = 4, input = "x", hint = "Esc 戻る"}
	s := app.tui_render_shell(f)
	defer delete(s)
	// 入力行(最終行)の末尾がヒントで終わる(右寄せ、パディング後)。
	lines := strings.split_lines(s, context.temp_allocator)
	last := lines[len(lines) - 1]
	testing.expect(t, strings.has_suffix(last, "Esc 戻る"))

	// 幅が足りない場合はヒントを省略し、入力だけをパディング表示する。
	narrow := app.Shell_Frame{cols = 8, rows = 4, input = "x", hint = "とても長いヒント文字列"}
	ns := app.tui_render_shell(narrow)
	defer delete(ns)
	testing.expect(t, !strings.contains(ns, "ヒント"))
	testing.expect(t, strings.contains(ns, "> x_"))
}

@(test)
test_render_shell_zero_size_falls_back :: proc(t: ^testing.T) {
	f := app.Shell_Frame{cols = 0, rows = 0}
	s := app.tui_render_shell(f)
	defer delete(s)
	// フォールバック 80x24: 改行23個。
	testing.expect_value(t, strings.count(s, "\n"), 23)
}

// --- メッセージログ(T14-3) ---

@(test)
test_message_log_append_and_order :: proc(t: ^testing.T) {
	l: app.Message_Log
	defer app.message_log_destroy(&l)

	app.message_log_append(&l, "first")
	app.message_log_append(&l, "second")
	app.message_log_append(&l, "third")

	testing.expect_value(t, app.message_log_len(&l), 3)
	testing.expect_value(t, app.message_log_get(&l, 0), "first")
	testing.expect_value(t, app.message_log_get(&l, 2), "third")
	testing.expect_value(t, app.message_log_get(&l, 3), "") // 範囲外
	testing.expect_value(t, app.message_log_get(&l, -1), "")
}

@(test)
test_message_log_ring_evicts_oldest :: proc(t: ^testing.T) {
	l: app.Message_Log
	defer app.message_log_destroy(&l)

	// CAP+1 件入れると最古の1件だけが押し出される。
	for i in 0 ..< app.MESSAGE_LOG_CAP + 1 {
		app.message_log_append(&l, fmt.tprintf("msg-%d", i))
	}
	testing.expect_value(t, app.message_log_len(&l), app.MESSAGE_LOG_CAP)
	testing.expect_value(t, app.message_log_get(&l, 0), "msg-1") // msg-0 が消えた
	testing.expect_value(t, app.message_log_get(&l, app.MESSAGE_LOG_CAP - 1), fmt.tprintf("msg-%d", app.MESSAGE_LOG_CAP))
}

@(test)
test_message_log_clones_entries :: proc(t: ^testing.T) {
	l: app.Message_Log
	defer app.message_log_destroy(&l)

	buf: [8]u8 = {'h', 'e', 'l', 'l', 'o', 0, 0, 0}
	app.message_log_append(&l, string(buf[:5]))
	buf[0] = 'X' // 呼び出し元のバッファを書き換えてもログは影響を受けない(clone 所有)
	testing.expect_value(t, app.message_log_get(&l, 0), "hello")
}

@(test)
test_status_line_set_message_appends_to_log :: proc(t: ^testing.T) {
	l: app.Message_Log
	defer app.message_log_destroy(&l)
	s := app.Status_Line {
		enabled = true,
		log     = &l,
	}
	app.status_line_set_message(&s, "State saved to slot 2")
	testing.expect_value(t, app.message_log_len(&l), 1)
	testing.expect_value(t, app.message_log_get(&l, 0), "State saved to slot 2")
	testing.expect_value(t, s.last_message, "State saved to slot 2")

	app.status_line_set_message(&s, "") // 空メッセージはログに入らない
	testing.expect_value(t, app.message_log_len(&l), 1)

	s.enabled = false // destroy の改行出力(TTY向け)を抑制してから後始末
	app.status_line_destroy(&s)
}

// --- ゲーム中入力ルーティング(T14-5、T15-1 で生ホットキー廃止に伴い書き換え) ---

@(test)
test_game_input_route_now_playing_chars_always_go_to_editor :: proc(t: ^testing.T) {
	// T15-1: 「ゲーム中も同じモードで動くこと」の要望により、旧ホットキー文字
	// (s,l,p,+,-,1-4)を含め、印字可能な文字は常に入力行へ行く(バッファの空/非空を
	// 問わない)。1キーの即時発火は完全に廃止された。
	for ch in ([]rune{'s', 'l', 'p', '+', '-', '1', 'q', '/'}) {
		key := app.Key_Event {
			key = .Char,
			ch  = ch,
		}
		testing.expect(t, app.game_input_route(key, true, .Now_Playing) == .Editor)
		testing.expect(t, app.game_input_route(key, false, .Now_Playing) == .Editor)
	}
}

@(test)
test_game_input_route_enter_escape :: proc(t: ^testing.T) {
	enter := app.Key_Event {
		key = .Enter,
	}
	esc := app.Key_Event {
		key = .Escape,
	}
	// Now Playing: 空Enterは無視、非空Enterは確定。Esc はクリア。
	testing.expect(t, app.game_input_route(enter, true, .Now_Playing) == .None)
	testing.expect(t, app.game_input_route(enter, false, .Now_Playing) == .Submit)
	testing.expect(t, app.game_input_route(esc, false, .Now_Playing) == .Clear)
}

@(test)
test_game_input_route_settings_view :: proc(t: ^testing.T) {
	up := app.Key_Event {
		key = .Up,
	}
	left := app.Key_Event {
		key = .Left,
	}
	enter := app.Key_Event {
		key = .Enter,
	}
	esc := app.Key_Event {
		key = .Escape,
	}
	ch := app.Key_Event {
		key = .Char,
		ch  = 'x',
	}

	// ↑↓←→ は常にメニューへ(バッファの状態に関わらず)
	testing.expect(t, app.game_input_route(up, true, .Settings) == .Menu)
	testing.expect(t, app.game_input_route(left, false, .Settings) == .Menu)
	// Enter/Esc はバッファ空のときだけメニューへ(menu_step が .Close を返す)
	testing.expect(t, app.game_input_route(enter, true, .Settings) == .Menu)
	testing.expect(t, app.game_input_route(esc, true, .Settings) == .Menu)
	// 非空なら入力行の確定/クリア
	testing.expect(t, app.game_input_route(enter, false, .Settings) == .Submit)
	testing.expect(t, app.game_input_route(esc, false, .Settings) == .Clear)
	// 印字文字は入力行へ
	testing.expect(t, app.game_input_route(ch, true, .Settings) == .Editor)
}

@(test)
test_game_input_route_tab :: proc(t: ^testing.T) {
	tab := app.Key_Event {
		key = .Tab,
	}
	// Now Playing: Tab補完(先頭ヒットで入力欄を書き換え)。
	testing.expect(t, app.game_input_route(tab, true, .Now_Playing) == .Complete)
	testing.expect(t, app.game_input_route(tab, false, .Now_Playing) == .Complete)
	// Settings ビューでは補完リスト自体を表示しないため Tab は無視する。
	testing.expect(t, app.game_input_route(tab, true, .Settings) == .None)
	testing.expect(t, app.game_input_route(tab, false, .Settings) == .None)
}

@(test)
test_parse_game_command_accepts_leading_slash :: proc(t: ^testing.T) {
	// T14-5: 入力行常時アクティブ化に伴い `/` 付きも許容(両対応)。
	testing.expect(t, app.parse_game_command("/pause").kind == .Pause)
	testing.expect(t, app.parse_game_command("/quit").kind == .Quit)
	testing.expect(t, app.parse_game_command("/settings").kind == .Settings)

	set_cmd := app.parse_game_command("/set volume 50")
	testing.expect(t, set_cmd.kind == .Set)
	testing.expect(t, set_cmd.set_key == "volume")
	testing.expect(t, set_cmd.set_value == "50")

	save2 := app.parse_game_command("/save 2")
	testing.expect(t, save2.kind == .Save_State && save2.slot == 2)

	// `/` 単体・空白のみは Empty
	testing.expect(t, app.parse_game_command("/").kind == .Empty)
	testing.expect(t, app.parse_game_command("  /  ").kind == .Empty)

	// `/` なしの従来形式も引き続き有効
	testing.expect(t, app.parse_game_command("pause").kind == .Pause)
}

// --- volume up/down コマンド(T15-2、旧 +/- ホットキーの移植) ---

@(test)
test_parse_game_command_volume_up_down :: proc(t: ^testing.T) {
	testing.expect(t, app.parse_game_command("volume up").kind == .Volume_Up)
	testing.expect(t, app.parse_game_command("volume down").kind == .Volume_Down)
	testing.expect(t, app.parse_game_command("/volume up").kind == .Volume_Up)
}

@(test)
test_parse_game_command_volume_requires_up_or_down :: proc(t: ^testing.T) {
	// "volume" 単体や不正な引数は Unknown(/set volume <n> と混同しないこと)。
	testing.expect(t, app.parse_game_command("volume").kind == .Unknown)
	testing.expect(t, app.parse_game_command("volume 50").kind == .Unknown)
	testing.expect(t, app.parse_game_command("volume sideways").kind == .Unknown)
}

// --- 設定の即時反映(T15-4) ---

@(test)
test_live_setting_kind_maps_known_keys :: proc(t: ^testing.T) {
	testing.expect(t, app.live_setting_kind("volume") == .Volume)
	testing.expect(t, app.live_setting_kind("shader") == .Shader)
	testing.expect(t, app.live_setting_kind("scale") == .Scale)
	// fullscreen は設定対象外(Cmd+Enter/--fullscreen 専用、要件2026-07-20)なので .None
	testing.expect(t, app.live_setting_kind("fullscreen") == .None)
}

@(test)
test_live_setting_kind_unknown_key_is_none :: proc(t: ^testing.T) {
	testing.expect(t, app.live_setting_kind("save_dir") == .None)
	testing.expect(t, app.live_setting_kind("") == .None)
	testing.expect(t, app.live_setting_kind("Volume") == .None) // 大文字小文字を区別する
}

// --- alt screen 進入時の DECSTBM リセット(T16-2) ---

@(test)
test_alt_screen_enter_includes_scroll_region_reset :: proc(t: ^testing.T) {
	// 直前のターミナル状態(他プログラムが残したスクロール領域制限)が alt screen 突入後も
	// 引き継がれる可能性への防御(2026-07-19、実機 macOS Terminal.app での報告に対応)。
	// "\x1b[r"(パラメータなしのDECSTBM)は「全画面をスクロール領域にする」の意味であり、
	// 上下端を数値指定するとその値が固定されてしまうため、パラメータなしであることが重要。
	testing.expect(t, strings.has_prefix(app.ALT_SCREEN_ENTER, "\x1b[?1049h"))
	testing.expect(t, strings.contains(app.ALT_SCREEN_ENTER, "\x1b[r"))
	testing.expect(t, !strings.contains(app.ALT_SCREEN_ENTER, "\x1b[r;")) // パラメータ付きではない
	// EXIT側は変更していない(元の代替スクリーン退出シーケンスのみ)。
	testing.expect_value(t, app.ALT_SCREEN_EXIT, "\x1b[?1049l")
}

// --- コマンドレジストリ / 補完(T22-*) ---

@(test)
test_commands_matching_empty_input_returns_context_availability :: proc(t: ^testing.T) {
	home := app.commands_matching("", false)
	defer delete(home)
	home_names := make(map[string]bool, allocator = context.temp_allocator)
	for c in home {
		home_names[c.name] = true
	}
	testing.expect(t, home_names["browse"])
	testing.expect(t, home_names["settings"])
	testing.expect(t, home_names["help"])
	testing.expect(t, home_names["quit"])
	testing.expect(t, !home_names["pause"], "ゲーム専用コマンドはホームに出ない")
	testing.expect(t, !home_names["reset"], "ゲーム専用コマンドはホームに出ない")

	game := app.commands_matching("", true)
	defer delete(game)
	game_names := make(map[string]bool, allocator = context.temp_allocator)
	for c in game {
		game_names[c.name] = true
	}
	testing.expect(t, game_names["pause"])
	testing.expect(t, game_names["reset"])
	testing.expect(t, game_names["help"])
	testing.expect(t, !game_names["browse"], "ホーム専用コマンドはゲーム中に出ない")
	testing.expect(t, !game_names["recent"], "ホーム専用コマンドはゲーム中に出ない")
}

@(test)
test_commands_matching_prefix_filters :: proc(t: ^testing.T) {
	// "se" は settings/set の両方に前方一致する。
	matches := app.commands_matching("se", true)
	defer delete(matches)
	names := make(map[string]bool, allocator = context.temp_allocator)
	for c in matches {
		names[c.name] = true
	}
	testing.expect(t, names["settings"])
	testing.expect(t, names["set"])
	testing.expect(t, !names["save"])
	testing.expect(t, !names["slot"])
}

@(test)
test_commands_matching_strips_leading_slash_and_ignores_rest_of_line :: proc(t: ^testing.T) {
	// 先頭の "/" は剥がして解釈し、スペース以降(引数)は無視して先頭トークンだけ見る。
	// "rese" は reset のみに前方一致する(resume は4文字目が 'u' で外れる)。
	matches := app.commands_matching("/rese", true)
	defer delete(matches)
	testing.expect(t, len(matches) == 1)
	testing.expect(t, matches[0].name == "reset")

	matches_with_args := app.commands_matching("/save 2", true)
	defer delete(matches_with_args)
	testing.expect(t, len(matches_with_args) == 1)
	testing.expect(t, matches_with_args[0].name == "save")
}

@(test)
test_commands_matching_no_match_returns_empty :: proc(t: ^testing.T) {
	matches := app.commands_matching("/zzz", true)
	defer delete(matches)
	testing.expect(t, len(matches) == 0)
}

@(test)
test_shell_content_commands_formats_heading_and_rows :: proc(t: ^testing.T) {
	items := []app.Command_Info{
		{name = "help", desc = "コマンド一覧を表示", home = true, game = true},
		{name = "settings", desc = "設定メニューを開く", home = true, game = true},
	}
	content := app.shell_content_commands("コマンド一覧", items, 80)
	defer app.shell_lines_destroy(content)

	testing.expect_value(t, len(content), 4) // heading + 空行 + 項目2
	testing.expect_value(t, content[0], "コマンド一覧")
	testing.expect_value(t, content[1], "")
	testing.expect(t, strings.contains(content[2], "/help"))
	testing.expect(t, strings.contains(content[2], "コマンド一覧を表示"))
	testing.expect(t, strings.contains(content[3], "/settings"))
	testing.expect(t, strings.contains(content[3], "設定メニューを開く"))
	// 2カラム整形: 短い方の名前(/help)が長い方(/settings)に揃うようパディングされている。
	help_name_end := strings.index(content[2], "コマンド一覧を表示")
	settings_name_end := strings.index(content[3], "設定メニューを開く")
	testing.expect_value(t, help_name_end, settings_name_end)
}

@(test)
test_shell_content_commands_empty_items_still_has_heading :: proc(t: ^testing.T) {
	content := app.shell_content_commands("コマンド一覧", []app.Command_Info{}, 80)
	defer app.shell_lines_destroy(content)
	testing.expect_value(t, len(content), 2)
}

@(test)
test_shell_content_commands_top_name_marker :: proc(t: ^testing.T) {
	items := []app.Command_Info{
		{name = "help", desc = "コマンド一覧を表示", home = true, game = true},
		{name = "settings", desc = "設定メニューを開く", home = true, game = true},
	}
	content := app.shell_content_commands("コマンド一覧", items, 80, "settings")
	defer app.shell_lines_destroy(content)

	testing.expect(t, strings.has_prefix(content[2], "  "), "help はマーカー対象でないので空白始まり")
	testing.expect(t, !strings.has_prefix(content[2], "▸"))
	testing.expect(t, strings.has_prefix(content[3], "▸ "), "settings がtop_nameなので▸始まり")
}

// --- Enter確定/Tab補完の先頭ヒット解決(T23-*) ---

@(test)
test_command_top_match_exact_wins_over_prefix :: proc(t: ^testing.T) {
	// head="set" はレジストリ順では "settings" が先に前方一致するが、完全一致の "set" が
	// 優先されなければならない("/set volume 30" が "/settings volume 30" に化けるのを防ぐ)。
	top, ok := app.command_top_match("set", false)
	testing.expect(t, ok)
	testing.expect_value(t, top.name, "set")

	top_with_args, ok_args := app.command_top_match("set volume 30", false)
	testing.expect(t, ok_args)
	testing.expect_value(t, top_with_args.name, "set")
}

@(test)
test_command_top_match_prefix_picks_registry_first :: proc(t: ^testing.T) {
	top, ok := app.command_top_match("br", false)
	testing.expect(t, ok)
	testing.expect_value(t, top.name, "browse")

	// ゲーム中の "re" は resume/reset の両方に前方一致するが、レジストリ順で resume が先。
	top_game, ok_game := app.command_top_match("re", true)
	testing.expect(t, ok_game)
	testing.expect_value(t, top_game.name, "resume")
}

@(test)
test_command_top_match_respects_context :: proc(t: ^testing.T) {
	// "save" はゲーム専用コマンドなのでホーム画面では見えない。
	_, ok_home := app.command_top_match("save", false)
	testing.expect(t, !ok_home)

	_, ok_game := app.command_top_match("save", true)
	testing.expect(t, ok_game)
}

@(test)
test_command_top_match_empty_head_or_alias_fails :: proc(t: ^testing.T) {
	_, ok_empty := app.command_top_match("", false)
	testing.expect(t, !ok_empty)

	_, ok_slash_only := app.command_top_match("/", false)
	testing.expect(t, !ok_slash_only)

	// "ls" は registry に無いエイリアス(parse_home_command 側で個別に受理する)なので
	// command_top_match は関知しない。
	_, ok_alias := app.command_top_match("ls", false)
	testing.expect(t, !ok_alias)
}

@(test)
test_command_resolve_input_home_prefix_and_exact :: proc(t: ^testing.T) {
	resolved := app.command_resolve_input("/br", false)
	defer delete(resolved)
	testing.expect_value(t, resolved, "/browse")

	resolved_exact := app.command_resolve_input("/set volume 30", false)
	defer delete(resolved_exact)
	testing.expect_value(t, resolved_exact, "/set volume 30")
}

@(test)
test_command_resolve_input_game_prefix :: proc(t: ^testing.T) {
	resolved := app.command_resolve_input("sav 2", true)
	defer delete(resolved)
	testing.expect_value(t, resolved, "/save 2")
}

@(test)
test_command_resolve_input_unknown_and_empty_pass_through :: proc(t: ^testing.T) {
	resolved := app.command_resolve_input("/nope", false)
	defer delete(resolved)
	testing.expect_value(t, resolved, "/nope")

	resolved_empty := app.command_resolve_input("", false)
	defer delete(resolved_empty)
	testing.expect_value(t, resolved_empty, "")
}
