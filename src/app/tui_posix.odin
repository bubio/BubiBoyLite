#+build linux, darwin, netbsd, openbsd, freebsd
package main

// tui_posix.odin: tui.odin が要求する tui_plat_* を POSIX (termios/ioctl/signal) で実装する
// (T9-1)。`core:sys/posix` は windows ターゲットではパッケージ自体が存在しないため、
// この実装は windows ビルドから完全に除外される(tui_windows.odin 参照)。

import "base:runtime"
import "core:c"
import "core:os"
import "core:sys/posix"

@(private = "file")
saved_termios: posix.termios
@(private = "file")
raw_active: bool

// tui_plat_enable_raw は ECHO/ICANON を無効化し、VMIN=0/VTIME=1(100ms タイムアウト)に設定する
// (T9-1「作るもの」)。ISIG は意図的に触らない(Ctrl+C が SIGINT を発生させ続けることを
// 前提に、その SIGINT ハンドラ側で端末復元する設計。T9-6「Ctrl+Cでも復元される」)。
tui_plat_enable_raw :: proc() -> bool {
	if posix.tcgetattr(posix.STDIN_FILENO, &saved_termios) != .OK {
		return false
	}
	raw := saved_termios
	raw.c_lflag -= {.ECHO, .ICANON}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 1
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw) != .OK {
		return false
	}
	raw_active = true
	return true
}

// tui_plat_disable_raw は tui_plat_enable_raw 前の termios 属性へ戻す。
// "contextless": tui_force_restore からシグナルハンドラ経由で呼ばれる可能性があるため。
// 落とし穴(実装中に検証で発見): TCSAFLUSH は「未転送の出力がすべて転送されるまで待つ」
// (tcdrain 相当)ため、端末側の読み出しが止まっている瞬間に呼ぶと無期限にブロックしうる
// (自動テストでの再現: 直前の書き込みバーストを読み手が消費し切っていない状態で
// tcsetattr(TCSAFLUSH) が固まった)。復元は「直前に書いたバイト列の転送完了を待つ」必要が
// 無いので TCSANOW(即時適用、drain/discardなし)を使う。
tui_plat_disable_raw :: proc "contextless" () {
	if !raw_active {
		return
	}
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &saved_termios)
	raw_active = false
}

// tui_plat_set_read_timeout_deciseconds は VTIME を動的に変更する(VMIN は常に0のまま)。
// T9-2 の ROM 一覧ナビゲーション(応答性重視、100ms=1)と T9-5 のゲームループ中ポーリング
// (メインループを止めない、0=完全ノンブロッキング)を使い分けるために使う。
tui_plat_set_read_timeout_deciseconds :: proc(deciseconds: int) -> bool {
	if !raw_active {
		return false
	}
	cur: posix.termios
	if posix.tcgetattr(posix.STDIN_FILENO, &cur) != .OK {
		return false
	}
	cur.c_cc[.VMIN] = 0
	cur.c_cc[.VTIME] = posix.cc_t(deciseconds)
	return posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &cur) == .OK
}

// tui_plat_read は非ブロッキング(VTIME設定に従う)で読み取る。読めたバイト数を返す(0もあり得る)。
tui_plat_read :: proc(buf: []u8) -> int {
	if len(buf) == 0 {
		return 0
	}
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
	if n < 0 {
		return 0
	}
	return int(n)
}

// tui_plat_write_raw は write(2) を直接呼ぶ("contextless"、シグナルハンドラから呼べるように
// アロケーションもfmtも使わない)。
tui_plat_write_raw :: proc "contextless" (s: string) {
	if len(s) == 0 {
		return
	}
	posix.write(posix.STDOUT_FILENO, raw_data(s), c.size_t(len(s)))
}

// --- 端末サイズ (ioctl TIOCGWINSZ) ---
// core:sys/posix には ioctl のバインディングが無いため、libc の ioctl を直接 foreign import する。
// TIOCGWINSZ の値は BSD 系(macOS含む)と Linux で異なる。

when ODIN_OS == .Darwin {
	foreign import libc_ioctl "system:System"
} else {
	foreign import libc_ioctl "system:c"
}

foreign libc_ioctl {
	ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

@(private = "file")
Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

when ODIN_OS == .Linux {
	TIOCGWINSZ :: 0x5413
} else {
	// macOS(Darwin) / FreeBSD / NetBSD / OpenBSD は共通してこの値。
	TIOCGWINSZ :: 0x40087468
}

tui_plat_term_size :: proc() -> (cols, rows: int, ok: bool) {
	ws: Winsize
	if ioctl(c.int(posix.STDOUT_FILENO), c.ulong(TIOCGWINSZ), &ws) != 0 {
		return 0, 0, false
	}
	if ws.ws_col == 0 || ws.ws_row == 0 {
		return 0, 0, false
	}
	return int(ws.ws_col), int(ws.ws_row), true
}

// --- 異常終了時の端末復元(シグナルハンドラ) ---

// tui_plat_install_crash_restore は Ctrl+C(SIGINT)・終了要求(SIGTERM/SIGHUP)に加え、
// Odin のバウンドチェック等が発する「回復不能トラップ」系シグナル(SIGILL/SIGTRAP/SIGSEGV/
// SIGBUS/SIGABRT/SIGFPE)もハンドルする。tui.odin 冒頭のコメント参照: これらは
// context.assertion_failure_proc を経由しないため、シグナルハンドラでの捕捉が必須。
// 実機検証で判明: このシグナル一覧に SIGTRAP を含め忘れていたところ、意図的な
// index-out-of-range(境界チェック違反)が `runtime.trap()` 経由で SIGTRAP を送出し、
// ハンドラ未登録のため端末が復元されないまま落ちることを確認した(その後追加して解消)。
tui_plat_install_crash_restore :: proc() {
	posix.signal(.SIGINT, tui_signal_handler)
	posix.signal(.SIGTERM, tui_signal_handler)
	posix.signal(.SIGHUP, tui_signal_handler)
	posix.signal(.SIGABRT, tui_signal_handler)
	posix.signal(.SIGILL, tui_signal_handler)
	posix.signal(.SIGTRAP, tui_signal_handler)
	posix.signal(.SIGSEGV, tui_signal_handler)
	posix.signal(.SIGBUS, tui_signal_handler)
	posix.signal(.SIGFPE, tui_signal_handler)
}

@(private = "file")
tui_signal_handler :: proc "c" (sig: posix.Signal) {
	tui_force_restore()
	context = runtime.default_context()
	os.exit(1)
}

// tui_plat_sleep_ms はキー入力が無いときのアイドル待ち(ビジーループ回避)。
tui_plat_sleep_ms :: proc(ms: int) {
	req := posix.timespec {
		tv_sec  = posix.time_t(ms / 1000),
		tv_nsec = c.long((ms % 1000) * 1_000_000),
	}
	posix.nanosleep(&req, nil)
}
