#+build windows
package main

// tui_windows.odin: tui.odin が要求する tui_plat_* を Windows Console API で実装する(T9-1)。
// 【重要】この実装は Windows 環境が無いため実機でのビルド/実行検証ができていない
// (検証ログに正直に記載すること)。core:sys/windows の API シグネチャに基づいて実装しているが、
// 実際の Windows Terminal / conhost での動作確認はフェーズ10のCI導入後に行う。

import win "core:sys/windows"
import "core:os"

@(private = "file")
saved_in_mode: win.DWORD
@(private = "file")
saved_out_mode: win.DWORD
@(private = "file")
raw_active: bool
@(private = "file")
h_stdin: win.HANDLE
@(private = "file")
h_stdout: win.HANDLE
@(private = "file")
read_timeout_ms: win.DWORD = 100

// tui_plat_enable_raw: ECHO/LINE 入力を無効化し、ENABLE_VIRTUAL_TERMINAL_INPUT(矢印キー等を
// ANSI CSI シーケンスとして受け取る)を有効化する。出力側は ENABLE_VIRTUAL_TERMINAL_PROCESSING
// を有効化する(T9-1「作るもの」: Windows は SetConsoleMode で VT 処理を有効化)。
// ENABLE_PROCESSED_INPUT はあえて維持する(無効化すると Ctrl+C が生バイトとして届き、
// SetConsoleCtrlHandler 経由の復元処理[tui_plat_install_crash_restore]が働かなくなるため)。
tui_plat_enable_raw :: proc() -> bool {
	h_stdin = win.GetStdHandle(win.STD_INPUT_HANDLE)
	h_stdout = win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if h_stdin == win.INVALID_HANDLE_VALUE || h_stdout == win.INVALID_HANDLE_VALUE {
		return false
	}
	if !win.GetConsoleMode(h_stdin, &saved_in_mode) {
		return false
	}
	if !win.GetConsoleMode(h_stdout, &saved_out_mode) {
		return false
	}

	new_in_mode := (saved_in_mode & ~(win.ENABLE_ECHO_INPUT | win.ENABLE_LINE_INPUT)) | win.ENABLE_VIRTUAL_TERMINAL_INPUT
	if !win.SetConsoleMode(h_stdin, new_in_mode) {
		return false
	}

	new_out_mode := saved_out_mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING
	if !win.SetConsoleMode(h_stdout, new_out_mode) {
		win.SetConsoleMode(h_stdin, saved_in_mode)
		return false
	}

	raw_active = true
	return true
}

tui_plat_disable_raw :: proc "contextless" () {
	if !raw_active {
		return
	}
	win.SetConsoleMode(h_stdin, saved_in_mode)
	win.SetConsoleMode(h_stdout, saved_out_mode)
	raw_active = false
}

// tui_plat_set_read_timeout_deciseconds: POSIX 版の VTIME(1=100ms)に相当する待ち時間を
// WaitForSingleObject のタイムアウトとして使う。0 は「待たない(完全ノンブロッキング)」。
tui_plat_set_read_timeout_deciseconds :: proc(deciseconds: int) -> bool {
	if deciseconds <= 0 {
		read_timeout_ms = 0
	} else {
		read_timeout_ms = win.DWORD(deciseconds * 100)
	}
	return true
}

tui_plat_read :: proc(buf: []u8) -> int {
	if len(buf) == 0 || h_stdin == win.INVALID_HANDLE_VALUE {
		return 0
	}
	waited := win.WaitForSingleObject(h_stdin, read_timeout_ms)
	if waited != win.WAIT_OBJECT_0 {
		return 0
	}
	n_read: win.DWORD
	if !win.ReadFile(h_stdin, raw_data(buf), win.DWORD(len(buf)), &n_read, nil) {
		return 0
	}
	return int(n_read)
}

tui_plat_write_raw :: proc "contextless" (s: string) {
	if len(s) == 0 || h_stdout == win.INVALID_HANDLE_VALUE {
		return
	}
	written: win.DWORD
	win.WriteFile(h_stdout, raw_data(s), win.DWORD(len(s)), &written, nil)
}

// optimization_mode="none": tui_posix.odin の同名関数のコメント参照(T12-6)。
// Windows は対応プラットフォーム外(CLAUDE.md)で実機検証はできていないが、POSIX側と
// 同じ dev-2026-07 ツールチェインの疑いがあるコード生成不具合のため念のため揃えている。
@(optimization_mode = "none")
tui_plat_term_size :: proc() -> (cols, rows: int, ok: bool) {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	if !win.GetConsoleScreenBufferInfo(h_stdout, &info) {
		return 0, 0, false
	}
	cols = int(info.srWindow.Right - info.srWindow.Left + 1)
	rows = int(info.srWindow.Bottom - info.srWindow.Top + 1)
	return cols, rows, true
}

// tui_plat_install_crash_restore: SetConsoleCtrlHandler で Ctrl+C / ウィンドウクローズ /
// ログオフ/シャットダウンの通知を受けて端末を復元する。false を返して既定の終了処理へ
// フォールスルーする(復元は既に完了しているので、この後プロセスが終了しても問題ない)。
tui_plat_install_crash_restore :: proc() {
	win.SetConsoleCtrlHandler(console_ctrl_handler, true)
}

@(private = "file")
console_ctrl_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	tui_force_restore()
	return false
}

tui_plat_sleep_ms :: proc(ms: int) {
	win.Sleep(win.DWORD(ms))
}
