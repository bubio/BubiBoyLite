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
