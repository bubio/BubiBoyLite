package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:terminal"
import "core:time"
import core "bbl:core"

// tui.odin: Claude Code 風 TUI の基盤(T9-1)。
// 設計方針(phase-09-tui.md「TUI の設計方針」): 依存ライブラリなし、ANSI エスケープ +
// ターミナル raw mode を自前で扱う。プラットフォーム固有の実装(termios/SetConsoleMode 等)は
// このファイルではなく tui_posix.odin / tui_windows.odin に分離する(Odin の
// `core:sys/posix` は windows ターゲットではパッケージごと存在しないため、
// `when ODIN_OS` の分岐だけでは1ファイルに収められない。architecture.md が
// `src/app/tui.odin` 1ファイルを想定しているが、ビルド制約上この3ファイル構成が必要)。
// このファイル自身はプラットフォーム非依存: 純粋関数(レンダリング/キー解析)と
// tui_plat_* を呼び出すオーケストレーションのみを置く。
//
// 【phase-09-tui.md の記述との重要な相違点(実装前の検証で判明)】
// 「Odin の defer はパニックでも走る」という前提は誤り。実際に検証したところ、
// Odin の panic()/assert() は例外アンワインドを行わず即座に trap するため defer は
// 一切実行されない(境界: 通常の return によるスコープ離脱でのみ defer が走る)。
// 代わりに `context.assertion_failure_proc` を上書きすることで panic() 直前にフックできる
// (これは実行時に os.exit 相当のスタックアンワインドなしで正しく動作することを確認済み)。
// 境界チェック違反(index out of range 等)や nil 参照は assertion_failure_proc すら経由せず
// `runtime.trap()`(このプラットフォームでは実測で SIGTRAP)へ直行するため、
// tui_plat_install_crash_restore で SIGILL/SIGTRAP/SIGSEGV/SIGBUS/SIGABRT/SIGFPE も
// ハンドルしてセーフティネットにする(SIGINT/TERM/HUP と合わせて T9-6「パニックでも
// ターミナル状態が復元される」を満たす。実装中に意図的な index out-of-range を発生させ、
// SIGTRAP ハンドラが無いと復元されないまま落ちることを確認した上で追加した)。

// --- ANSI 制御シーケンス ---

// ALT_SCREEN_ENTER: 代替スクリーンへの切替(\x1b[?1049h)に続けて DECSTBM スクロール領域を
// パラメータなしでリセットする(\x1b[r = 全画面をスクロール領域にする、T16-2)。
// 直前に動作していた別プログラム(tmux 等のターミナルマルチプレクサ、他のTUIアプリ)が
// 独自のスクロール領域を設定したまま解除せずに終了していた場合、alt screen へ切り替えても
// スクロール領域の制限自体は端末側のモードとして引き継がれる実装が一般的(xterm系の一般的
// 挙動)。その場合、本来 rows 全体のつもりで描画しても古いスクロール領域の下端でスクロールが
// 起き、コマンドエリア(区切り線+ステータス行+入力行)が画面の途中で止まって見える不具合が
// 実機(macOS Terminal.app)で報告された(2026-07-19)。alt screen 突入時に必ずリセットする
// ことで、直前のターミナル状態に関わらず常に全画面へ正しく描画されるようにする。
ALT_SCREEN_ENTER :: "\x1b[?1049h\x1b[r"
ALT_SCREEN_EXIT :: "\x1b[?1049l"
CURSOR_HIDE :: "\x1b[?25l"
CURSOR_SHOW :: "\x1b[?25h"
CURSOR_HOME :: "\x1b[H"
CLEAR_SCREEN :: "\x1b[2J"

// --- 表示幅計算(全角文字対応) ---

// rune_display_width は東アジアの全角文字(ひらがな/カタカナ/漢字/全角記号など)を2、
// それ以外を1として扱う簡易実装(厳密な East Asian Width 実装ではないが、本 TUI が
// 表示する日本語見出し・ROM名の範囲では十分)。
rune_display_width :: proc(r: rune) -> int {
	switch {
	case r >= 0x1100 && r <= 0x115F: // ハングル字母
		return 2
	case r >= 0x2E80 && r <= 0x303E: // CJK部首・記号
		return 2
	case r >= 0x3041 && r <= 0x33FF: // ひらがな・カタカナ・CJK互換記号
		return 2
	case r >= 0x3400 && r <= 0x4DBF: // CJK拡張A
		return 2
	case r >= 0x4E00 && r <= 0x9FFF: // CJK統合漢字
		return 2
	case r >= 0xAC00 && r <= 0xD7A3: // ハングル音節
		return 2
	case r >= 0xF900 && r <= 0xFAFF: // CJK互換漢字
		return 2
	case r >= 0xFF00 && r <= 0xFF60: // 全角英数記号
		return 2
	case r >= 0xFFE0 && r <= 0xFFE6:
		return 2
	}
	return 1
}

// display_width は文字列全体の表示幅を返す(純粋関数、単体テスト対象)。
display_width :: proc(s: string) -> int {
	w := 0
	for r in s {
		w += rune_display_width(r)
	}
	return w
}

// write_padded は s を width 幅ちょうどになるよう b に書く(幅超過分は打ち切り、
// 不足分は半角スペースで埋める)。全角文字がちょうど境界に来て1幅分だけ余る場合は
// スペース1個で埋める(2幅分の文字は書かない、崩れ防止)。
write_padded :: proc(b: ^strings.Builder, s: string, width: int) {
	w := 0
	for r in s {
		rw := rune_display_width(r)
		if w + rw > width {
			break
		}
		strings.write_rune(b, r)
		w += rw
	}
	for w < width {
		strings.write_byte(b, ' ')
		w += 1
	}
}

// --- キー入力の解析(純粋関数、単体テスト対象) ---

Key :: enum {
	None,
	Up,
	Down,
	Left,
	Right,
	Enter,
	Escape,
	Backspace,
	Char,
}

Key_Event :: struct {
	key: Key,
	ch:  rune, // key == .Char のときのみ有効
}

// tui_parse_key は raw mode で読み取った生バイト列の先頭1イベント分を解釈する。
// 戻り値 consumed は buf から消費したバイト数(呼び出し側はこの分だけ buf を進める)。
// 空入力(consumed==0, key==.None)は「まだ解釈できるイベントが無い」を表す
// (例: ESC 単体で終わっている場合は少なくとも1バイトは消費して .Escape を返す。
// CSI シーケンスが1バイトだけ届いて `\x1b` の次が届いていない場合は 0 を返し、
// 呼び出し側が次の read で続きを取得してから再度呼ぶ想定)。
tui_parse_key :: proc(buf: []u8) -> (event: Key_Event, consumed: int) {
	if len(buf) == 0 {
		return Key_Event{}, 0
	}

	b0 := buf[0]

	if b0 == 0x1b { // ESC
		if len(buf) == 1 {
			return Key_Event{key = .Escape}, 1
		}
		if buf[1] != '[' {
			return Key_Event{key = .Escape}, 1
		}
		if len(buf) < 3 {
			return Key_Event{}, 0 // "ESC [" までしか届いていない。続きを待つ
		}
		switch buf[2] {
		case 'A':
			return Key_Event{key = .Up}, 3
		case 'B':
			return Key_Event{key = .Down}, 3
		case 'C':
			return Key_Event{key = .Right}, 3
		case 'D':
			return Key_Event{key = .Left}, 3
		}
		// 未対応の CSI シーケンス。ESC 単体として扱い、残りは次回以降で再解釈させる。
		return Key_Event{key = .Escape}, 1
	}

	if b0 == '\r' || b0 == '\n' {
		return Key_Event{key = .Enter}, 1
	}
	if b0 == 0x7f || b0 == 0x08 {
		return Key_Event{key = .Backspace}, 1
	}

	// ASCII 範囲のみ1バイト文字として扱う(メニュー操作のショートカットキーは全て ASCII)。
	// マルチバイト UTF-8 の非ASCII入力(ファイル名の手入力などは無い)はここでは想定しない。
	if b0 < 0x80 {
		return Key_Event{key = .Char, ch = rune(b0)}, 1
	}

	return Key_Event{key = .None}, 1 // 未対応バイトは読み捨てる
}

// --- 画面描画(純粋関数、単体テスト対象) ---

List_Item :: struct {
	label: string, // 左側のテキスト
	info:  string, // 右寄せの付加情報(空文字なら無し)
}

// T14-2: 旧 Tui_Frame(枠線付き全画面フレーム)は固定レイアウトシェル(Shell_Frame、下記)に
// 置き換えられて撤去した。List_Item と幅の定数は shell_content_list が引き続き使う。

FRAME_MIN_WIDTH :: 40
FRAME_MAX_WIDTH :: 100

// --- 固定レイアウトシェル(T14-1、T19-1 で meta 行を追加) ---
// Claude Code 風の固定レイアウト: 上部コンテンツ領域(rows-4)+区切り線+meta行+
// ステータス行+入力行。ホーム/ブラウザ/設定/ゲーム中の全画面がこの1本のレンダラで
// 描画され、**ゲーム起動中も全く同じ画面構成を維持する**(phase-14 の中核要件)。
// T19-1: 実機でユーザーから「ROM名は(コンテンツ領域でなく)固定フッターの中で別行に」
// との指摘を受け、区切り線とステータス行の間に meta 行(ゲーム中は ROM名+カートリッジ
// 種別)を追加した(T18-2 でコンテンツ領域見出しに移した対応は誤りだったため巻き戻し、
// T19-3 参照)。

SHELL_RESERVED_ROWS :: 4 // 区切り線 + meta行 + ステータス行 + 入力行

Shell_Frame :: struct {
	cols:    int, // 端末の列数(0 以下ならフォールバック値)
	rows:    int,
	content: []string, // コンテンツ領域の行。rows-4 を超える分は切り捨て、不足分は空行
	meta:    string, // 区切り線とステータス行の間の1行(ゲーム中はROM名+カートリッジ種別、
	// それ以外の画面では空文字=空行のまま、T19-1)
	status:  string, // ステータス行(fps / vol / 操作結果メッセージ等)
	input:   string, // 入力行。"> " + input + "_" の形式で表示(擬似カーソル)
	hint:    string, // 入力行の右端に右寄せ表示するキーヒント(幅が足りなければ省略)
}

// tui_render_shell は Shell_Frame から1画面分の ANSI 文字列を組み立てる(純粋関数、
// 単体テスト対象。tui_render_frame と同じ理由で描画とI/Oを分離する)。
// - CURSOR_HOME 開始、各行 "\x1b[K"(行クリア)+ cols-1 幅の write_padded(パディング兼
//   打ち切り。自動折り返しによる行ズレ防止)
// - ちょうど rows 行を書く(改行は rows-1 個)。**最下行に改行を書かない**(書くと端末が
//   スクロールして全体が1行ズレるため)
tui_render_shell :: proc(f: Shell_Frame, allocator := context.allocator) -> string {
	cols := f.cols > 0 ? f.cols : TERM_FALLBACK_COLS
	rows := f.rows > 0 ? f.rows : TERM_FALLBACK_ROWS
	width := max(cols - 1, 1)
	content_rows := max(rows - SHELL_RESERVED_ROWS, 0)

	b: strings.Builder
	strings.builder_init(&b, allocator)

	strings.write_string(&b, CURSOR_HOME)

	// コンテンツ領域
	for i in 0 ..< content_rows {
		strings.write_string(&b, "\x1b[K")
		line := i < len(f.content) ? f.content[i] : ""
		write_padded(&b, line, width)
		strings.write_string(&b, "\n")
	}

	if rows >= SHELL_RESERVED_ROWS {
		// 区切り線
		strings.write_string(&b, "\x1b[K")
		for _ in 0 ..< width {
			strings.write_string(&b, "─")
		}
		strings.write_string(&b, "\n")

		// meta行(T19-1: ROM名+カートリッジ種別。非ゲーム画面では空文字=空行)
		strings.write_string(&b, "\x1b[K")
		write_padded(&b, f.meta, width)
		strings.write_string(&b, "\n")

		// ステータス行
		strings.write_string(&b, "\x1b[K")
		write_padded(&b, f.status, width)
		strings.write_string(&b, "\n")

		// 入力行(最下行、改行なし): "> " + input + "_" と右寄せヒント
		strings.write_string(&b, "\x1b[K")
		left := fmt.tprintf("> %s_", f.input)
		left_w := display_width(left)
		hint_w := display_width(f.hint)
		if f.hint != "" && left_w + 2 + hint_w <= width {
			pad := width - left_w - hint_w
			strings.write_string(&b, left)
			for _ in 0 ..< pad {
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, f.hint)
		} else {
			write_padded(&b, left, width)
		}
	}

	return strings.to_string(b)
}

// tui_write_shell は tui_render_shell の結果を書き出す。contextless な tui_plat_write_raw を
// 使う(T12-6 で os.write_string 直接呼び出しが -o:speed で `a.allocator.procedure != nil`
// アサーションを誘発した前例があるため、シェル描画は最初から contextless で書く)。
tui_write_shell :: proc(f: Shell_Frame) {
	s := tui_render_shell(f)
	defer delete(s)
	tui_plat_write_raw(s)
}

// shell_lines_destroy は shell_content_* が返す所有 []string を解放する。
shell_lines_destroy :: proc(lines: []string) {
	for l in lines {
		delete(l)
	}
	delete(lines)
}

// shell_content_list はリスト画面(ROMブラウザ/recent/設定メニュー)のコンテンツ領域を
// 組み立てる(T14-2、純粋関数)。heading + 空行 + 項目リスト(選択カーソル▸、info は右寄せ)。
// 選択が常に見えるようスクロール窓を計算する(avail_rows を超える項目は選択位置を含む
// 窓だけ表示)。戻り値は所有 []string(shell_lines_destroy で解放)。
// ファイルI/O(ディレクトリスキャン等)の直後に呼ばれるため temp_allocator は使わない
// (T9-6 の教訓、戻り値は allocator で確保)。
shell_content_list :: proc(heading: string, items: []List_Item, selected: int, avail_rows: int, cols: int, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, 0, avail_rows, allocator)
	append(&lines, strings.clone(heading, allocator))
	append(&lines, strings.clone("", allocator))

	item_rows := max(avail_rows - 2, 1)
	start := 0
	if selected >= item_rows {
		start = selected - item_rows + 1
	}
	end := min(start + item_rows, len(items))

	// info の右寄せ幅(tui_render_frame の項目行と同じ発想。極端に広い端末では読みにくいので
	// 上限を設ける)。
	width := clamp(cols - 1, FRAME_MIN_WIDTH, FRAME_MAX_WIDTH)

	for i in start ..< end {
		item := items[i]
		marker := i == selected ? "▸ " : "  "
		left := fmt.tprintf("%s%s", marker, item.label)
		line := left
		if item.info != "" {
			left_w := display_width(left)
			info_w := display_width(item.info)
			pad := width - 2 - left_w - info_w
			if pad < 1 {
				pad = 1
			}
			line = fmt.tprintf("%s%s%s", left, strings.repeat(" ", pad, context.temp_allocator), item.info)
		}
		append(&lines, strings.clone(line, allocator))
	}
	return lines[:]
}

// shell_content_home はホーム画面のコンテンツ領域(ロゴ中央寄せ+コマンド一覧)を組み立てる
// (T14-2、純粋関数)。幅が不足する場合は1行タイトルへフォールバック(T12-3 と同じ挙動)。
shell_content_home :: proc(cols: int, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, 0, 12, allocator)
	append(&lines, strings.clone("", allocator))

	logo_width := tui_logo_max_width()
	if cols >= logo_width + 4 {
		// ロゴ全体を1ブロックとして中央寄せ(行ごとの個別センタリングはジグザグに崩れる、
		// T12-3 検証ログ参照)。
		pad := (cols - logo_width) / 2
		pad_str := strings.repeat(" ", pad, context.temp_allocator)
		for line in strings.split_lines(TUI_LOGO, context.temp_allocator) {
			append(&lines, fmt.aprintf("%s%s", pad_str, line, allocator = allocator))
		}
	} else {
		title := fmt.tprintf("BubiBoyLite v%s", VERSION)
		w := display_width(title)
		pad := max((cols - w) / 2, 0)
		append(&lines, fmt.aprintf("%s%s", strings.repeat(" ", pad, context.temp_allocator), title, allocator = allocator))
	}

	append(&lines, strings.clone("", allocator))
	append(&lines, strings.clone(" /browse  /recent  /settings  /quit", allocator))
	return lines[:]
}

// --- TTY 判定 ---

// tui_available は標準入出力の両方が TTY に接続されているかを返す(T9-1「非TTYではTUI起動せず
// エラー+exit 1」)。パイプ(`echo | bbl`)やリダイレクト(`bbl > file`)のどちらか片方でも
// 非TTYなら false になる。
tui_available :: proc() -> bool {
	return terminal.is_terminal(os.stdin) && terminal.is_terminal(os.stdout)
}

// --- raw mode / alt screen のライフサイクル ---

@(private = "file")
tui_restored := true // 起動直後は「復元不要(まだ何も変更していない)」状態

// tui_force_restore は alt screen 終了 + カーソル表示 + raw mode 解除を行う。
// "contextless" にしてあるのはシグナルハンドラから直接呼べるようにするため
// (Odin のシグナルハンドラは "c" 呼び出し規約で、まだ context が張られていない可能性がある)。
// 二重呼び出しを許容する(tui_restored フラグで冪等)。
tui_force_restore :: proc "contextless" () {
	if tui_restored {
		return
	}
	tui_restored = true
	tui_plat_write_raw(CURSOR_SHOW)
	tui_plat_write_raw(ALT_SCREEN_EXIT)
	tui_plat_disable_raw()
}

// tui_assertion_failure は context.assertion_failure_proc として設定される。panic()/assert()
// が呼ばれた瞬間、デフォルトの trap 処理に入る前に端末を復元する。
// (package外には出さないが、main.odin(同じpackage)から run_rom_window 側で直接
// `context.assertion_failure_proc = tui_assertion_failure` する必要がある(T9-5、直接起動時の
// ターミナルホットキー用にrun_rom_window自身がraw modeを持つ場合)ため private="file" は付けない
// (tui_enter側コメントの「代入は呼び出し元自身の関数本体で行う必要がある」を参照)。
tui_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	tui_force_restore()
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// tui_enter は raw mode を有効化し、代替スクリーンバッファへ切り替え、カーソルを隠す。
// 失敗時(端末属性の取得/設定に失敗)は false を返し、何も変更しない。
//
// 落とし穴(実装中に検証で発見): `context.assertion_failure_proc` への代入は暗黙の
// context 引数を通じて伝播するため、「代入した proc の残り実行 + そこから呼び出す先」にしか
// 効かない。代入した proc が return した後、呼び出し元(の続きの処理)には効果が無い
// (呼び出し元は自分自身の context のコピーのまま)。そのため、この代入を tui_enter() の
// 中で行っても、tui_enter() が返った後に run_tui() が呼ぶ tui_run_demo() 以降には反映されない
// (パニックを意図的に発生させて確認: 復元シーケンスが書かれないまま SIGTRAP で死ぬことを確認した)。
// 呼び出し元である run_tui() 側で設定する必要があるため、この関数では行わない
// (run_tui 参照)。
tui_enter :: proc() -> bool {
	if !tui_plat_enable_raw() {
		return false
	}
	tui_restored = false
	tui_plat_install_crash_restore()
	tui_plat_write_raw(ALT_SCREEN_ENTER)
	tui_plat_write_raw(CURSOR_HIDE)
	return true
}

// tui_exit は tui_enter の逆操作。通常終了経路(qキー等)で呼ぶ。
tui_exit :: proc() {
	tui_force_restore()
}

// tui_exit_process は「TUI が有効な状態からプロセスを終了する」ときに使う(落とし穴:
// os.exit は defer を飛ばすため、TUI 起動中の exit は必ずこの関数を経由すること)。
tui_exit_process :: proc(code: int) -> ! {
	tui_force_restore()
	os.exit(code)
}

// --- 代替スクリーンの一時退避(T9-2: ROM選択→ゲーム実行→ROM選択の往復) ---
// raw mode(ECHO/ICANON off)は「代替スクリーン表示中か」とは独立した状態にしてある
// (T9-5でゲーム実行中もターミナルからホットキーを受け付ける設計のため、raw mode 自体は
// ゲーム実行中も維持し続け、代替スクリーンだけ抜ける)。tui_force_restore はどちらの
// 状態からでも安全に両方まとめて復元できる(ALT_SCREEN_EXITは既に代替スクリーン外でも
// 端末側で無視される冪等なシーケンスなので、サブ状態を追跡する必要が無い)。

// tui_suspend_for_game は ROM 選択画面から SDL ゲーム実行へ移る前に呼ぶ。
// T14-4: **alt screen は抜けない**(ゲーム中も TUI と同一の固定レイアウト画面構成を維持する、
// phase-14 の中核要件。ゲーム中のシェル描画は run_rom_window 側が行う)。
// ターミナル読み取りだけ完全ノンブロッキング(VMIN=0/VTIME=0)に切り替える
// (T9-5「メインループを止めない」)。
tui_suspend_for_game :: proc() {
	tui_plat_set_read_timeout_deciseconds(0)
}

// tui_resume_from_game は SDL ゲーム終了後に ROM 選択画面へ戻るときに呼ぶ。
// T14-4: alt screen は維持されたままなので読み取りタイムアウトを戻すだけ(100ms=1)。
tui_resume_from_game :: proc() {
	tui_plat_set_read_timeout_deciseconds(1)
}

// --- 直接起動(TUI非経由)時のターミナル機能(T9-4/T9-5) ---
// `bbl rom.gb` のように TUI を経由せず直接 ROM を起動した場合、raw mode はまだ誰も
// 有効化していない。ステータス行(T9-4)は raw mode 不要(stderr への書き込みだけ)だが、
// ホットキー(T9-5、Enterキー入力無しの1文字読み取りが要る)には raw mode が要る。
// alt screen には切り替えない(SDLウィンドウが主役であって代替スクリーンを表示する対象の
// 画面が無い。tui_suspend_for_game 後の状態と同じ「raw modeのみ有効」)。

// tui_game_terminal_available は標準入力と標準エラー出力の両方がTTYかを返す
// (ステータス行はstderr、ホットキー読み取りはstdinを使うため両方必要)。
tui_game_terminal_available :: proc() -> bool {
	return terminal.is_terminal(os.stdin) && terminal.is_terminal(os.stderr)
}

// tui_game_terminal_begin は直接起動経路でホットキーを使えるようにする。成功したら
// ok=true を返す(呼び出し側は対になる tui_exit() を必ず呼ぶこと)。TUI経由の場合はこの関数を
// 呼ばないこと(既にtui_enterでraw modeが有効なため、ここで再度tcgetattrすると
// 復元用に保存した「本来の端末状態」を上書きしてしまう)。
// T14-4: stdout も TTY なら alt screen へ入り(shell=true)、直接起動でも TUI 経由と同一の
// 固定レイアウトシェルを使えるようにする。stdout 非TTY(リダイレクト等)なら従来の
// 1行ステータス表示にフォールバックする(shell=false、非TTYフォールバック無変更の方針)。
// 復元は tui_exit() → tui_force_restore が ALT_SCREEN_EXIT を含むため追加処理不要。
// 落とし穴(tui_enterのコメント参照): `context.assertion_failure_proc` の代入はこの関数の
// 中で行っても呼び出し元には伝播しないため、呼び出し側(run_rom_window)自身の関数本体で
// `context.assertion_failure_proc = tui_assertion_failure` を設定すること。
tui_game_terminal_begin :: proc() -> (ok: bool, shell: bool) {
	if !tui_game_terminal_available() {
		return false, false
	}
	if !tui_plat_enable_raw() {
		return false, false
	}
	tui_restored = false
	tui_plat_install_crash_restore()
	tui_plat_set_read_timeout_deciseconds(0) // 完全ノンブロッキング(T9-5「メインループを止めない」)
	shell = terminal.is_terminal(os.stdout)
	if shell {
		tui_plat_write_raw(ALT_SCREEN_ENTER)
		tui_plat_write_raw(CURSOR_HIDE)
	}
	return true, shell
}

// --- 端末サイズ ---

TERM_FALLBACK_COLS :: 80
TERM_FALLBACK_ROWS :: 24

// tui_term_size は現在の端末サイズを返す。取得できない場合は 80x24 にフォールバックする
// (advisor 指摘: 変則的な端末でも落ちないようにする)。
// optimization_mode="none": tui_run_command_home 側のコメント参照(T12-6、3点セット必須)。
@(optimization_mode = "none")
tui_term_size :: proc() -> (cols, rows: int) {
	c, r, ok := tui_plat_term_size()
	if !ok || c <= 0 || r <= 0 {
		return TERM_FALLBACK_COLS, TERM_FALLBACK_ROWS
	}
	return c, r
}

// --- キー読み取り(ノンブロッキング) ---

// Key_Reader は tui_plat_read の生バイトから tui_parse_key でイベントを切り出すための
// 小さな状態(ESC の続きバイトが次回 read までまたがるケースに対応するための1バイト単位
// バッファ)。
Key_Reader :: struct {
	pending: [8]u8,
	len:     int,
}

// key_reader_poll は非ブロッキングで1イベント分読み取る(イベントが無ければ ok=false)。
key_reader_poll :: proc(kr: ^Key_Reader) -> (event: Key_Event, ok: bool) {
	if kr.len < len(kr.pending) {
		n := tui_plat_read(kr.pending[kr.len:])
		kr.len += n
	}
	if kr.len == 0 {
		return Key_Event{}, false
	}
	ev, consumed := tui_parse_key(kr.pending[:kr.len])
	if consumed == 0 {
		return Key_Event{}, false // 続きバイト待ち
	}
	copy(kr.pending[:], kr.pending[consumed:kr.len])
	kr.len -= consumed
	return ev, true
}

// --- ホーム画面(T12-3): ロゴ+コマンドプロンプト ---
// BluePrint「Claude Code などに見られる TUI も提供する」。起動直後にロゴとプロンプトを表示し、
// `/browse` 等のコマンドで既存の ROM ブラウザ(T9-2、T9-6 で実機検証済みの資産)へ遷移する
// (案C、検討経緯は `/Users/seiji/.claude/plans/tui-claude-code-bubiboylite-settings-snoopy-whale.md`)。

// TUI_LOGO は起動時に表示する複数行 ASCII アート(幅約56桁)。tui_render_home_screen が
// tui_term_size() の cols と比較し、収まらない場合は1行タイトルへフォールバックする。
TUI_LOGO :: `____        _     _ ____              _     _ _
| __ ) _   _| |__ (_) __ )  ___  _   _| |   (_) |_ ___
|  _ \| | | | '_ \| |  _ \ / _ \| | | | |   | | __/ _ \
| |_) | |_| | |_) | | |_) | (_) | |_| | |___| | ||  __/
|____/ \__,_|_.__/|_|____/ \___/ \__, |_____|_|\__\___|
                                   |___/`

@(private = "file")
tui_logo_max_width :: proc() -> int {
	w := 0
	for line in strings.split_lines(TUI_LOGO, context.temp_allocator) {
		lw := display_width(line)
		if lw > w {
			w = lw
		}
	}
	return w
}

Home_Command_Kind :: enum {
	Quit,
	Browse,
	Recent,
	Settings, // /settings(引数無し): ホーム画面内で対話メニューを開き、ループを継続する
	Set, // /set <key> <value>: ホーム画面内で即時適用し、ループを継続する
	Unknown,
}

Home_Command :: struct {
	kind:      Home_Command_Kind,
	raw:       string, // kind == .Unknown の時だけ意味を持つ(エラー表示用、入力文字列の借用)
	set_key:   string, // kind == .Set の時だけ意味を持つ(入力文字列の借用)
	set_value: string, // kind == .Set の時だけ意味を持つ(入力文字列の借用)
}

// parse_home_command はホーム画面のプロンプト入力を解釈する純粋関数(単体テスト対象)。
// 空Enterは /browse 相当。未対応のコマンドは .Unknown を返し、呼び出し側はエラー表示して
// ループを継続する(即座に終了・遷移しない)。戻り値の raw/set_key/set_value は input の
// 部分スライス(借用)なので、input より長生きさせて保持する場合は呼び出し側で clone すること。
parse_home_command :: proc(input: string) -> Home_Command {
	trimmed := strings.trim_space(input)
	switch trimmed {
	case "":
		return Home_Command{kind = .Browse}
	case "/browse", "/ls":
		return Home_Command{kind = .Browse}
	case "/recent":
		return Home_Command{kind = .Recent}
	case "/quit", "/exit":
		return Home_Command{kind = .Quit}
	case "/settings":
		return Home_Command{kind = .Settings}
	}
	SET_PREFIX :: "/set "
	if strings.has_prefix(trimmed, SET_PREFIX) {
		rest := strings.trim_space(trimmed[len(SET_PREFIX):])
		sp := strings.index_byte(rest, ' ')
		if sp > 0 {
			key := strings.trim_space(rest[:sp])
			value := strings.trim_space(rest[sp + 1:])
			if key != "" && value != "" {
				return Home_Command{kind = .Set, set_key = key, set_value = value}
			}
		}
		return Home_Command{kind = .Unknown, raw = trimmed}
	}
	return Home_Command{kind = .Unknown, raw = trimmed}
}

// T14-2: 旧 tui_render_home_screen/tui_write_home_screen は shell_content_home +
// tui_write_shell に置き換えられて撤去した(T12-6 の contextless 書き込みの知見は
// tui_write_shell が引き継いでいる)。

// --- /settings 対話メニュー(T12-4) ---
// ホーム画面限定(ゲーム実行中は対話メニューを開かない、T12-5 参照: SDL イベントポンプが
// 止まりウィンドウ幽霊化を再発するため)。scale/fullscreen/shader/volume のみ対象。

// T13-1: tests パッケージから menu_adjust_value(cfg, f, delta) を直接テストするため
// private を外して公開する(settings_fields 等の補助はファイル内利用のみなので private のまま)。
Settings_Field :: enum {
	Scale,
	Fullscreen,
	Shader,
	Volume,
}

@(private = "file")
settings_fields := [4]Settings_Field{.Scale, .Fullscreen, .Shader, .Volume}

@(private = "file")
settings_field_key :: proc(f: Settings_Field) -> string {
	switch f {
	case .Scale:
		return "scale"
	case .Fullscreen:
		return "fullscreen"
	case .Shader:
		return "shader"
	case .Volume:
		return "volume"
	}
	return ""
}

@(private = "file")
settings_field_value_string :: proc(cfg: Config, f: Settings_Field) -> string {
	switch f {
	case .Scale:
		return fmt.tprintf("%d", cfg.scale)
	case .Fullscreen:
		return cfg.fullscreen ? "true" : "false"
	case .Shader:
		return cfg.shader == .Smooth ? "smooth" : "nearest"
	case .Volume:
		return fmt.tprintf("%d", cfg.volume)
	}
	return ""
}

// --- メニュー状態機械(T13-1、純粋関数) ---
// 対話メニューの遷移ロジックを I/O から完全分離する。ホーム画面の /settings(T13-2)と
// ゲーム中オーバーレイ(T13-5)の両方がこの menu_step を共有し、描画だけを分岐させる。
// 適用(config_apply_set)は状態機械の外: menu_step は「何をすべきか」(Menu_Effect)を返すだけに
// して完全純粋化し、文字列比較で単体テスト可能にする。

Menu_State :: struct {
	selected: int, // settings_fields のインデックス(0..3)
	status:   string, // 直前の操作結果メッセージ(所有。呼び出し側が config_apply_set の結果等を反映する)
}

Menu_Op :: enum {
	None, // 何もしない(未対応キー、または境界で値が変わらなかった)
	Redraw, // 選択が動いた等、再描画だけ必要
	Adjust, // key/value で config_apply_set を呼ぶこと(value は呼び出し側が delete する)
	Close, // メニューを閉じること
}

Menu_Effect :: struct {
	op:    Menu_Op,
	key:   string, // .Adjust 時のみ有効(settings_field_key の静的文字列、delete 不要)
	value: string, // .Adjust 時のみ有効(allocator で確保した所有権付き文字列、呼び出し側が delete)
}

// menu_adjust_value は ←→ 操作による値の増減/トグルを計算する(純粋関数、単体テスト対象)。
// scale は ±1 で 1..MAX_SCALE に clamp、volume は ±5 で 0..100 に clamp、fullscreen/shader は
// delta の符号に関わらずトグル。既に境界にいて値が変わらない場合は changed=false を返し、
// 文字列の確保もしない。config_apply_set は範囲外を clamp せずエラーにする仕様のため、
// ここで clamp してから渡すことで常に適用可能な値だけを返す。
// 戻り値 value は temp_allocator の借用ではなく allocator で確保した所有権付き文字列
// (呼び出し側が delete する。ファイルI/Oをまたいで生存するため temp_allocator 不可、
// config.odin の config_patch_ini コメント参照)。
menu_adjust_value :: proc(cfg: Config, f: Settings_Field, delta: int, allocator := context.allocator) -> (value: string, changed: bool) {
	switch f {
	case .Scale:
		n := clamp(cfg.scale + delta, 1, MAX_SCALE)
		if n == cfg.scale {
			return "", false
		}
		return fmt.aprintf("%d", n, allocator = allocator), true
	case .Fullscreen:
		return strings.clone(cfg.fullscreen ? "false" : "true", allocator), true
	case .Shader:
		return strings.clone(cfg.shader == .Smooth ? "nearest" : "smooth", allocator), true
	case .Volume:
		MENU_VOLUME_STEP :: 5
		n := clamp(cfg.volume + delta * MENU_VOLUME_STEP, 0, 100)
		if n == cfg.volume {
			return "", false
		}
		return fmt.aprintf("%d", n, allocator = allocator), true
	}
	return "", false
}

// menu_step は1キーイベントを状態機械へ与え、呼び出し側が実行すべき効果を返す(純粋関数、
// 単体テスト対象)。↑↓=選択移動(clamp)、←→=値サイクル/増減、Esc/q/Enter=Close。
menu_step :: proc(m: ^Menu_State, ev: Key_Event, cfg: Config, allocator := context.allocator) -> Menu_Effect {
	#partial switch ev.key {
	case .Up:
		if m.selected > 0 {
			m.selected -= 1
			return Menu_Effect{op = .Redraw}
		}
		return Menu_Effect{op = .None}
	case .Down:
		if m.selected < len(settings_fields) - 1 {
			m.selected += 1
			return Menu_Effect{op = .Redraw}
		}
		return Menu_Effect{op = .None}
	case .Left, .Right:
		delta := ev.key == .Right ? 1 : -1
		f := settings_fields[m.selected]
		value, changed := menu_adjust_value(cfg, f, delta, allocator)
		if !changed {
			return Menu_Effect{op = .None}
		}
		return Menu_Effect{op = .Adjust, key = settings_field_key(f), value = value}
	case .Escape, .Enter:
		return Menu_Effect{op = .Close}
	case .Char:
		if ev.ch == 'q' {
			return Menu_Effect{op = .Close}
		}
	}
	return Menu_Effect{op = .None}
}

// T14-4: T13-3 のオーバーレイ描画(tui_render_menu_overlay/MENU_OVERLAY_CLOSE/
// game_menu_overlay_draw)は固定レイアウトシェル(game_shell_draw、下記)に置き換えられて
// 撤去した。状態機械(menu_step/menu_adjust_value)はそのまま再利用している。

// menu_set_status は Menu_State.status を所有権付きで差し替える(T13-5)。
// config_apply_set の戻りメッセージは fmt.tprintf の借用のため、フレームをまたいで保持する
// には clone が必要(temp_allocator の借用をループをまたいで持たない方針、T9-6 の教訓)。
menu_set_status :: proc(m: ^Menu_State, msg: string) {
	delete(m.status)
	m.status = strings.clone(msg)
}

// menu_state_destroy は所有フィールドを解放する(メニューを閉じるときに呼ぶ)。
menu_state_destroy :: proc(m: ^Menu_State) {
	delete(m.status)
	m.status = ""
}

// --- ゲーム中シェル描画(T14-4、T16-1 で Now Playing パネルを簡素化) ---
// ゲーム実行中もホーム画面と同一の固定レイアウト(コンテンツ+区切り線+ステータス行+入力行)を
// 描画する。コンテンツ領域は Now Playing パネル(タイトル+メッセージログのみ。ROM名/状態/
// fps/音量/スロットはステータス行と重複するため T16-1 で削除)または設定メニュー
// (menu_step 状態機械、T13 から再利用)。

Game_View :: enum {
	Now_Playing,
	Settings,
}

// Game_Panel_Info は Now Playing パネルに表示する毎フレームの動的値(描画専用の入力)。
Game_Panel_Info :: struct {
	volume:       int,
	slot:         int,
	double_speed: bool,
	paused:       bool,
}

// shell_content_now_playing はゲーム中コンテンツ領域を組み立てる(T14-4、純粋関数)。
// メッセージログ直近数件(残り行数に収まる分、古→新の順)のみを表示する。
// T16-1でROM名/状態/fps/音量/スロットの詳細行を一旦削除した(ステータス行と完全に
// 重複表示だったため)。T18-2で見出し行を「BubiBoyLite v...」から ROM名+カートリッジ
// 種別に置き換えたが、これはユーザーの意図(固定フッターの中で別行にしてほしい)の
// 誤解だったため、T19-3で見出し行自体を削除して巻き戻した(ROM名+カートリッジ種別は
// T19-1/T19-2 で固定フッターのmeta行に移設済み)。先頭の空行だけは間隔として残す。
// info(Game_Panel_Info)はこの関数では使わなくなったが、呼び出し元 game_shell_draw の
// シグネチャ・Settings ビューとの対称性を保つため引数自体は残す。
// 戻り値は所有 []string(shell_lines_destroy で解放)。
shell_content_now_playing :: proc(s: ^Status_Line, info: Game_Panel_Info, avail_rows: int, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, 0, avail_rows, allocator)
	append(&lines, strings.clone("", allocator))

	// 残り行にメッセージログ(見出し1行+ログ行)。表示できる分だけ最新側から選び、古→新で並べる。
	if s.log != nil && message_log_len(s.log) > 0 {
		remaining := avail_rows - len(lines) - 2 // 空行+見出し
		if remaining >= 1 {
			append(&lines, strings.clone("", allocator))
			append(&lines, strings.clone("─ メッセージ ─", allocator))
			total := message_log_len(s.log)
			show := min(total, remaining)
			for i in total - show ..< total {
				append(&lines, fmt.aprintf("  %s", message_log_get(s.log, i), allocator = allocator))
			}
		}
	}
	return lines[:]
}

// game_shell_draw はゲームループ(main.odin)から毎フレーム呼ばれ、端末サイズの変化検知と
// dirty フラグに応じてシェル画面全体を再描画する。書き出しは tui_write_shell(contextless)。
// tui_term_size 呼び出し+描画をこの1関数に隔離している(T12-6 の -o:speed バグの発火パターン
// 「config_apply_set → ループ継続 → tui_term_size」と同型のため。まず素の実装で出荷し、
// -o:speed 検証でアサーションが再発した場合は @(optimization_mode="none") 付与を適用する方針、
// T13-6 の前例)。
game_shell_draw :: proc(
	view: Game_View,
	m: Menu_State,
	cfg: Config,
	s: ^Status_Line,
	info: Game_Panel_Info,
	input: string,
	last_cols: ^int,
	last_rows: ^int,
	dirty: ^bool,
) {
	cols, rows := tui_term_size()
	if cols != last_cols^ || rows != last_rows^ {
		last_cols^ = cols
		last_rows^ = rows
		dirty^ = true
	}
	if !dirty^ {
		return
	}

	avail := rows - SHELL_RESERVED_ROWS
	content: []string
	hint: string
	status := s.last_line
	// T19-1/T19-2: 固定フッターのmeta行にROM名+カートリッジ種別を表示する(実機で
	// ユーザーから「ROM名は固定フッターの中で別行に」との指摘を受けての対応。
	// Now Playing・ゲーム中設定ビューの両方で、ROMが読み込まれている間は常に表示する)。
	meta := fmt.tprintf("%s  %s", s.rom_name, s.cart_label)
	switch view {
	case .Settings:
		items := make([]List_Item, len(settings_fields))
		defer delete(items)
		for f, i in settings_fields {
			items[i] = List_Item{label = settings_field_key(f), info = menu_item_info(cfg, f)}
		}
		content = shell_content_list(
			fmt.tprintf("BubiBoyLite v%s 設定 — 設定項目を選択(←→ で値を変更)", VERSION),
			items,
			m.selected,
			avail,
			cols,
		)
		hint = "↑↓ 選択  ←→ 値を変更  Esc 戻る"
		if m.status != "" {
			status = m.status
		}
	case .Now_Playing:
		content = shell_content_now_playing(s, info, avail)
		// T16-1: フェーズ15(T15-1)で全ての生ホットキー(+,-,1-4,s,l,p)を廃止した際、
		// この案内文言を消し忘れていた(存在しない操作を案内するバグ)。入力行は常時
		// アクティブでスラッシュコマンドのみなので、特筆すべき固定ヒントは無い(空文字なら
		// tui_render_shell がヒント自体を表示しない)。
		hint = ""
	}
	defer shell_lines_destroy(content)

	tui_write_shell(Shell_Frame{cols = cols, rows = rows, content = content, meta = meta, status = status, input = input, hint = hint})
	dirty^ = false
}

// menu_item_info は設定メニューの List_Item.info 用の "◂ 3 ▸" 形式の文字列を作る
// (純粋関数、単体テスト対象)。戻り値は fmt.tprintf の借用(既存 settings_field_value_string と
// 同じ扱い、描画中のみ有効。ファイルI/Oをまたいで保持しないこと)。
menu_item_info :: proc(cfg: Config, f: Settings_Field) -> string {
	return fmt.tprintf("◂ %s ▸", settings_field_value_string(cfg, f))
}

// tui_run_settings_menu は /settings(引数無し)の対話メニュー。T13-2 で menu_step 駆動に
// 書き換え: ↑↓で項目選択、←→で値サイクル/増減(即時に config_apply_set で検証・適用・書き戻し)、
// Esc/q/Enter で戻る。従来の「Enter で編集モード → タイプ入力」は廃止(遷移ロジックと値計算を
// ゲーム中オーバーレイ(T13-5)と共有するため。描画だけがこちらはフル枠 tui_write_frame)。
// optimization_mode="none": tui_run_command_home 側のコメント参照(T12-6)。この関数も
// config_apply_set() 呼び出し後にループへ戻り tui_term_size() を呼ぶ同型のパターンを持つ
// (実機検証では発火しなかったが、予防的に揃える。30ms ポーリングループなのでコストは無視できる)。
@(optimization_mode = "none")
tui_run_settings_menu :: proc(cfg: ^Config, config_dir: string) {
	kr: Key_Reader
	m: Menu_State
	dirty := true
	status := ""

	for {
		cols, rows := tui_term_size()

		if dirty {
			items := make([]List_Item, len(settings_fields))
			defer delete(items)
			for f, i in settings_fields {
				items[i] = List_Item{label = settings_field_key(f), info = menu_item_info(cfg^, f)}
			}
			// T14-2: 固定レイアウトシェルで描画(キー処理・状態遷移は無変更)。
			content := shell_content_list(
				fmt.tprintf("BubiBoyLite v%s 設定 — 設定項目を選択(←→ で値を変更)", VERSION),
				items,
				m.selected,
				rows - SHELL_RESERVED_ROWS,
				cols,
			)
			tui_write_shell(Shell_Frame{cols = cols, rows = rows, content = content, status = status, hint = "↑↓ 選択  ←→ 値を変更  Esc 戻る"})
			shell_lines_destroy(content)
			dirty = false
		}

		ev, ok := key_reader_poll(&kr)
		if !ok {
			tui_plat_sleep_ms(30)
			continue
		}

		eff := menu_step(&m, ev, cfg^)
		switch eff.op {
		case .None:
		case .Redraw:
			dirty = true
		case .Adjust:
			_, msg := config_apply_set(cfg, config_dir, eff.key, eff.value)
			delete(eff.value)
			status = msg
			dirty = true
		case .Close:
			return
		}
	}
}

// tui_run_command_home はロゴ+プロンプト画面を表示し、画面遷移を伴うコマンド
// (/browse, /recent, /quit)が確定するまでブロックする。/settings と /set はこの関数の中で
// 完結処理し(対話メニュー起動、または即時適用)、処理後はループを継続する(ホーム画面に留まる)。
// 未対応コマンドはエラー表示してループを継続する(呼び出し元に .Unknown を返すことはない)。
// optimization_mode="none"(T12-6、-o:speed 実機バグ回避、3箇所セット): この関数のループ内、
// config_apply_set() から戻った直後に再度ループ先頭へ戻り tui_term_size() を呼ぶと、
// `runtime assertion: a.allocator.procedure != nil` が発生する実機バグをデバッグマーカーで
// 突き止めた(-debug ビルドでは再現しない。config.odin 側の各関数を個別に "none" にしても
// 直らなかった)。切り分けの結果、この関数・tui_term_size・tui_plat_term_size(tui_posix.odin)
// の3つ全てに "none" を付けて初めて解消することを確認した(3点セットで実機検証済み。
// メカニズムの厳密な特定はできておらず、いずれか1つを外すと再発する可能性があるため、
// 3つとも揃えて保持すること。dev-2026-07 ツールチェイン固有のコード生成不具合と推測、
// 深追いはT9-6の前例に倣い打ち切る)。この関数は30ms間隔のキー入力ポーリングが主であり
// 最適化コストは無視できるため、最適化を無効化して回避する。
@(optimization_mode = "none")
tui_run_command_home :: proc(cfg: ^Config, config_dir: string) -> Home_Command {
	editor: Line_Editor
	defer line_editor_destroy(&editor)

	kr: Key_Reader
	status := ""
	last_cols, last_rows := -1, -1
	dirty := true

	for {
		cols, rows := tui_term_size()
		if cols != last_cols || rows != last_rows {
			last_cols, last_rows = cols, rows
			dirty = true
		}

		if dirty {
			// T14-2: 固定レイアウトシェルで描画(コンテンツ=ロゴ+コマンド一覧、入力行=編集中の
			// コマンド)。shell_content_home は所有 []string を返すので必ず解放する。
			content := shell_content_home(cols)
			tui_write_shell(Shell_Frame{cols = cols, rows = rows, content = content, status = status, input = line_editor_text(editor)})
			shell_lines_destroy(content)
			dirty = false
		}

		ev, ok := key_reader_poll(&kr)
		if !ok {
			tui_plat_sleep_ms(30)
			continue
		}

		#partial switch ev.key {
		case .Char, .Backspace:
			line_editor_feed(&editor, ev)
			dirty = true
		case .Escape:
			line_editor_feed(&editor, ev)
			status = ""
			dirty = true
		case .Enter:
			submitted, text := line_editor_feed(&editor, ev)
			if !submitted {
				break
			}
			cmd := parse_home_command(text)
			switch cmd.kind {
			case .Unknown:
				status = fmt.tprintf("不明なコマンドです: %s", cmd.raw)
				delete(text)
				dirty = true
			case .Settings:
				delete(text)
				tui_run_settings_menu(cfg, config_dir)
				status = ""
				last_cols, last_rows = -1, -1 // 設定メニューで書き換えた画面を強制再描画させる
				dirty = true
			case .Set:
				_, msg := config_apply_set(cfg, config_dir, cmd.set_key, cmd.set_value)
				delete(text)
				status = msg
				dirty = true
			case .Quit, .Browse, .Recent:
				delete(text)
				return cmd
			}
		}
	}
}

// --- ROM 選択画面(T9-2) ---
// BluePrint「Claude Codeなどに見られる TUI も提供する」。T4-1 の core.cartridge_parse_header_lite
// を再利用してヘッダの MBC種別/CGBフラグだけを読む(落とし穴: ファイル先頭 HEADER_MIN_LEN
// バイトだけ読む。巨大ディレクトリでの全ROM全読み込み禁止)。

ROM_EXT_GB :: ".gb"
ROM_EXT_GBC :: ".gbc"

// is_rom_filename はファイル名が .gb/.gbc(大小文字区別なし)で終わるかを返す(純粋関数)。
is_rom_filename :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	return strings.has_suffix(lower, ROM_EXT_GB) || strings.has_suffix(lower, ROM_EXT_GBC)
}

// mbc_kind_label / cartridge_info_label は core.Cartridge_Info を表示用ラベルへ変換する
// 純粋関数(単体テスト対象)。TUI設計方針のモックアップ「(MBC5, CGB)」「(MBC1)」の形式。
mbc_kind_label :: proc(kind: core.Mbc_Kind) -> string {
	switch kind {
	case .Rom_Only:
		return "ROM ONLY"
	case .Mbc1:
		return "MBC1"
	case .Mbc2:
		return "MBC2"
	case .Mbc3:
		return "MBC3"
	case .Mbc5:
		return "MBC5"
	}
	return "?"
}

cartridge_info_label :: proc(info: core.Cartridge_Info, allocator := context.allocator) -> string {
	kind_label := mbc_kind_label(info.mbc_kind)
	if info.cgb_flag == .Dmg_Only {
		return fmt.aprintf("(%s)", kind_label, allocator = allocator)
	}
	return fmt.aprintf("(%s, CGB)", kind_label, allocator = allocator)
}

// read_rom_header_label はROMファイルの先頭 HEADER_MIN_LEN バイトだけを読んで表示ラベルを
// 返す(戻り値は呼び出し側が delete する所有権付き文字列)。読み込み/解析に失敗しても
// 一覧表示自体は止めない(その旨のラベルを返すだけ)。
read_rom_header_label :: proc(path: string) -> string {
	f, open_err := os.open(path)
	if open_err != nil {
		return strings.clone("(読み込み不可)")
	}
	defer os.close(f)

	buf: [core.HEADER_MIN_LEN]u8
	n, read_err := os.read(f, buf[:])
	if read_err != nil || n < core.HEADER_MIN_LEN {
		return strings.clone("(不明)")
	}

	info, err := core.cartridge_parse_header_lite(buf[:])
	if err != .None {
		return strings.clone("(未対応)")
	}
	return cartridge_info_label(info)
}

Browser_Entry_Kind :: enum {
	Parent,
	Directory,
	Rom,
}

Browser_Entry :: struct {
	kind:      Browser_Entry_Kind,
	name:      string, // 表示名(所有)
	path:      string, // フルパス(所有): Rom は起動対象、Directory/Parent は移動先
	info:      string, // 右寄せ情報。Rom 以外は空文字(所有)
	is_recent: bool, // T9-3: 最近使ったファイル一覧から来たエントリなら true(表示上の目印用)
}

@(private = "file")
browser_entries_delete :: proc(entries: []Browser_Entry) {
	for e in entries {
		delete(e.name)
		delete(e.path)
		delete(e.info)
	}
	delete(entries)
}

@(private = "file")
browser_entry_less :: proc(a, b: Browser_Entry) -> bool {
	return a.name < b.name
}

// scan_rom_directory は dir 直下(絶対パスを渡すこと)を列挙し、「..」(親ディレクトリ、
// dir がルートでない限り) → サブディレクトリ(名前順) → .gb/.gbcファイル(名前順)の順で
// Browser_Entry のスライスを返す。失敗時 ok=false(呼び出し側は直前の一覧を保持し続ける想定)。
scan_rom_directory :: proc(dir: string) -> (entries: []Browser_Entry, ok: bool) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return nil, false
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	dirs := make([dynamic]Browser_Entry, 0, len(infos))
	roms := make([dynamic]Browser_Entry, 0, len(infos))
	defer delete(dirs)
	defer delete(roms)

	for info in infos {
		#partial switch info.type {
		case .Directory:
			append(&dirs, Browser_Entry{kind = .Directory, name = strings.clone(info.name), path = strings.clone(info.fullpath)})
		case .Regular:
			if is_rom_filename(info.name) {
				path := strings.clone(info.fullpath)
				label := read_rom_header_label(path)
				append(&roms, Browser_Entry{kind = .Rom, name = strings.clone(info.name), path = path, info = label})
			}
		case:
		// シンボリックリンク・特殊ファイル等は対象外(BluePrintのスコープ外機能に相当する複雑さを避ける)。
		}
	}

	slice.sort_by(dirs[:], browser_entry_less)
	slice.sort_by(roms[:], browser_entry_less)

	result := make([dynamic]Browser_Entry, 0, len(dirs) + len(roms) + 1)
	// filepath.dir(os.dir) は dir を指す借用スライスを返す(確保しない)ので、
	// Browser_Entry へ格納する前に clone して所有権を持たせる。
	parent := filepath.dir(dir)
	if parent != dir {
		// 落とし穴(実装中に検証で発見、malloc: pointer being freed was not allocated で顕在化):
		// name に文字列リテラル ".." をそのまま入れると、browser_entries_delete が全フィールドを
		// delete() する際にヒープ確保でない静的データを free しようとしてクラッシュする。
		// 他のフィールド(Directory/Romのname)は strings.clone 済みなので、ここも合わせる。
		append(&result, Browser_Entry{kind = .Parent, name = strings.clone(".."), path = strings.clone(parent)})
	}
	append(&result, ..dirs[:])
	append(&result, ..roms[:])

	return result[:], true
}

// --- 最近使ったファイル(T9-3) ---

// RECENT_LABEL_PREFIX は一覧上で「最近使ったファイル」由来のエントリだと分かるように
// 表示名の先頭へ付ける目印(BluePrint「--recent」、T9-3「TUI通常起動時も『最近使った
// ファイル』セクションを一覧の先頭に表示」)。
RECENT_LABEL_PREFIX :: "★ "

// build_recent_entries は config_dir の bbl_recent.txt から実在するパスだけを読み込み、
// Browser_Entry(kind=.Rom, is_recent=true)のスライスへ変換する。config_dir が空、または
// 履歴が無ければ空スライスを返す(呼び出し側はその場合 recent セクションを描画しない)。
build_recent_entries :: proc(config_dir: string) -> []Browser_Entry {
	if strings.trim_space(config_dir) == "" {
		return nil
	}
	path := recent_file_path(config_dir)
	defer delete(path)

	raw := recent_load(path)
	defer recent_list_delete(raw)

	existing := recent_filter_existing(raw)
	defer recent_list_delete(existing)

	result := make([dynamic]Browser_Entry, 0, len(existing))
	for p in existing {
		label := read_rom_header_label(p)
		base := filepath.base(p)
		append(&result, Browser_Entry{kind = .Rom, name = strings.clone(base), path = strings.clone(p), info = label, is_recent = true})
	}
	return result[:]
}

// --- ROM ブラウザ画面 ---

Rom_Browser_Result :: enum {
	Quit,
	Launch,
}

// browser_entry_label は一覧の左側に表示するラベルを作る(純粋関数)。ディレクトリは
// 末尾に "/" を付け、最近使ったファイル由来のエントリには RECENT_LABEL_PREFIX を付ける。
browser_entry_label :: proc(e: Browser_Entry) -> string {
	name := e.name
	if e.kind == .Directory {
		name = fmt.tprintf("%s/", name)
	}
	if e.is_recent {
		return fmt.tprintf("%s%s", RECENT_LABEL_PREFIX, name)
	}
	return name
}

// scan_with_recent は scan_rom_directory の結果に、dir が「ホーム」(TUI起動時の初期
// ディレクトリ、cwdをどれだけ移動してもそこへ戻れば再度表示される)であれば
// build_recent_entries を先頭に連結したものを返す(T9-3「TUI通常起動時も『最近使った
// ファイル』セクションを一覧の先頭に表示」)。config_dir が空なら recent セクションは
// 付けない(履歴の保存場所が分からない = config_dir_path() の解決に失敗している場合)。
@(private = "file")
scan_with_recent :: proc(dir: string, home_dir: string, config_dir: string) -> (entries: []Browser_Entry, ok: bool) {
	scanned, scan_ok := scan_rom_directory(dir)
	if dir != home_dir {
		return scanned, scan_ok
	}
	recent := build_recent_entries(config_dir)
	if len(recent) == 0 {
		delete(recent)
		return scanned, scan_ok
	}
	combined := make([dynamic]Browser_Entry, 0, len(recent) + len(scanned))
	append(&combined, ..recent)
	append(&combined, ..scanned)
	delete(recent)
	delete(scanned)
	return combined[:], scan_ok
}

// tui_run_rom_browser はディレクトリを移動しながら ROM を選ぶ画面(T9-2)。
// Enter で ROM を選ぶと Rom_Browser_Result.Launch + そのフルパスを返す(呼び出し側が
// tui_suspend_for_game → 起動 → tui_resume_from_game する)。q/Esc で Quit を返す。
// config_dir は最近使ったファイル(T9-3)の保存場所。空文字なら recent セクションを出さない。
tui_run_rom_browser :: proc(start_dir: string, config_dir: string) -> (result: Rom_Browser_Result, rom_path: string) {
	cwd, abs_err := filepath.abs(start_dir)
	if abs_err != nil {
		cwd = strings.clone(".")
	}
	// cwd も entries と同じ理由(上記コメント参照)でブロックdeferにする: ディレクトリ移動時に
	// `delete(cwd); cwd = next` と再代入されるため、単純な defer だと最初の値を二重解放する。
	defer {
		delete(cwd)
	}
	home_dir := strings.clone(cwd) // 起動時ディレクトリ。ここに戻った時だけrecentセクションを出す。
	defer delete(home_dir)

	entries: []Browser_Entry
	scan_ok: bool
	entries, scan_ok = scan_with_recent(cwd, home_dir, config_dir)
	// 落とし穴(実装中に検証で発見、malloc: pointer being freed was not allocated で顕在化):
	// `defer browser_entries_delete(entries)` (単一のcall文)だと引数はdefer文の実行時点で
	// 即時評価される(Goのdeferと同じ挙動)。entries は reload() 内で &entries 経由で
	// 再代入されるため、単純な defer だと「最初のスキャン結果」を捕まえたまま関数末尾で
	// もう一度解放してしまい、reload() が既に解放済みの内容を二重解放していた。
	// ブロック `defer { ... }` にすると、ブロック内の変数参照は実行時(関数末尾)に
	// 評価される通常の変数読み取りになるため、常に「その時点の最新の entries」を解放できる。
	defer {
		browser_entries_delete(entries)
	}

	selected := 0
	kr: Key_Reader
	last_cols, last_rows := -1, -1
	dirty := true
	status := scan_ok ? "" : fmt.tprintf("ディレクトリを読み込めません: %s", cwd)

	reload :: proc(cwd: string, home_dir: string, config_dir: string, entries: ^[]Browser_Entry, selected: ^int, status: ^string) {
		browser_entries_delete(entries^)
		new_entries, ok := scan_with_recent(cwd, home_dir, config_dir)
		entries^ = new_entries
		selected^ = 0
		status^ = ok ? "" : fmt.tprintf("ディレクトリを読み込めません: %s", cwd)
	}

	for {
		cols, rows := tui_term_size()
		if cols != last_cols || rows != last_rows {
			last_cols, last_rows = cols, rows
			dirty = true
		}

		if dirty {
			// 落とし穴(実機検証で発見): context.temp_allocator で確保すると、build_recent_entries
			// 側のファイルI/O(recent_load 等)を経由した直後に -o:speed ビルドでこの make() が
			// 長さ0のスライスを返す(temp_allocator内部状態が壊れる、dev-2026-07 ツールチェイン固有の
			// 問題と推測。-debug では再現しない)。context.allocator(ヒープ)+明示的な delete に
			// 変更して回避する(詳細は phase-09-tui.md T9-6 検証ログ参照)。
			items := make([]List_Item, len(entries))
			defer delete(items)
			for e, i in entries {
				items[i] = List_Item{label = browser_entry_label(e), info = e.info}
			}
			// T14-2: 固定レイアウトシェルで描画(キー処理・entries 管理は無変更)。
			content := shell_content_list(
				fmt.tprintf("BubiBoyLite v%s — ROM を選択してください  [%s]", VERSION, cwd),
				items,
				selected,
				rows - SHELL_RESERVED_ROWS,
				cols,
			)
			tui_write_shell(Shell_Frame{cols = cols, rows = rows, content = content, status = status, hint = "↑↓ 選択  Enter 起動/移動  q 戻る"})
			shell_lines_destroy(content)
			dirty = false
		}

		ev, ok := key_reader_poll(&kr)
		if !ok {
			tui_plat_sleep_ms(30)
			continue
		}
		#partial switch ev.key {
		case .Up:
			if len(entries) > 0 && selected > 0 {
				selected -= 1
				dirty = true
			}
		case .Down:
			if len(entries) > 0 && selected < len(entries) - 1 {
				selected += 1
				dirty = true
			}
		case .Enter:
			if len(entries) == 0 {
				break
			}
			chosen := entries[selected]
			#partial switch chosen.kind {
			case .Rom:
				return .Launch, strings.clone(chosen.path)
			case .Parent, .Directory:
				next := strings.clone(chosen.path)
				delete(cwd)
				cwd = next
				reload(cwd, home_dir, config_dir, &entries, &selected, &status)
				dirty = true
			}
		case .Escape:
			return .Quit, ""
		case .Char:
			if ev.ch == 'q' {
				return .Quit, ""
			}
		}
	}
}

// tui_run_recent_browser は `--recent` 専用の画面(T9-3): ディレクトリ移動を持たない、
// 履歴だけのフラットな一覧。BluePrint「--recent : 最近使ったファイルを表示して選択できる」。
tui_run_recent_browser :: proc(config_dir: string) -> (result: Rom_Browser_Result, rom_path: string) {
	entries := build_recent_entries(config_dir)
	defer {
		browser_entries_delete(entries)
	}

	status := len(entries) == 0 ? "最近使ったファイルの履歴がありません" : ""
	selected := 0
	kr: Key_Reader
	last_cols, last_rows := -1, -1
	dirty := true

	for {
		cols, rows := tui_term_size()
		if cols != last_cols || rows != last_rows {
			last_cols, last_rows = cols, rows
			dirty = true
		}

		if dirty {
			// context.temp_allocator を避ける理由は tui_run_rom_browser 側の同種の
			// 箇所のコメント参照(phase-09-tui.md T9-6 検証ログ)。
			items := make([]List_Item, len(entries))
			defer delete(items)
			for e, i in entries {
				items[i] = List_Item{label = browser_entry_label(e), info = e.info}
			}
			// T14-2: 固定レイアウトシェルで描画(キー処理・entries 管理は無変更)。
			content := shell_content_list(
				fmt.tprintf("BubiBoyLite v%s — 最近使ったファイル", VERSION),
				items,
				selected,
				rows - SHELL_RESERVED_ROWS,
				cols,
			)
			tui_write_shell(Shell_Frame{cols = cols, rows = rows, content = content, status = status, hint = "↑↓ 選択  Enter 起動  q 戻る"})
			shell_lines_destroy(content)
			dirty = false
		}

		ev, ok := key_reader_poll(&kr)
		if !ok {
			tui_plat_sleep_ms(30)
			continue
		}
		#partial switch ev.key {
		case .Up:
			if len(entries) > 0 && selected > 0 {
				selected -= 1
				dirty = true
			}
		case .Down:
			if len(entries) > 0 && selected < len(entries) - 1 {
				selected += 1
				dirty = true
			}
		case .Enter:
			if len(entries) == 0 {
				break
			}
			return .Launch, strings.clone(entries[selected].path)
		case .Escape:
			return .Quit, ""
		case .Char:
			if ev.ch == 'q' {
				return .Quit, ""
			}
		}
	}
}

// Tui_Screen は run_tui 内部のみで使う画面状態(T12-3: ホーム画面 ⇄ ブラウザ画面の2段ループ)。
@(private = "file")
Tui_Screen :: enum {
	Home,
	Browse,
	Recent,
}

// run_tui は main.odin から呼ばれるエントリポイント。非TTYなら起動せずエラー+exit 1
// (T9-1完了条件)。ホーム画面(T12-3)→ `/browse`/`/recent` でブラウザ画面→起動→終了後は
// ホーム画面へ戻る、を `/quit` で抜けるまで繰り返す。
run_tui :: proc(opts: Options, cfg: Config) {
	if !tui_available() {
		fmt.eprintln("TUI を起動できません: 標準入出力が端末(TTY)に接続されていません")
		os.exit(1)
	}
	if !tui_enter() {
		fmt.eprintln("TUI を起動できません: 端末属性の取得/設定に失敗しました")
		os.exit(1)
	}
	// context.assertion_failure_proc は「代入した proc から呼ばれる範囲」にしか効かない
	// (tui_enter 側コメント参照)ので、ここ(TUIを実際に動かす run_tui 自身)で設定する。
	context.assertion_failure_proc = tui_assertion_failure
	defer tui_exit() // 通常のreturn経路(/quitで抜けた場合)ではdeferで問題ない。
	// 異常系(シグナル/panic)は tui_plat_install_crash_restore(シグナル) と
	// context.assertion_failure_proc(panic/assert) の両方で復元される。

	start_dir := strings.trim_space(cfg.rom_dir) != "" ? cfg.rom_dir : "."

	// T12-4: /set で変更した値をメモリ上に保持するため、ローカル変数へコピーしてアドレスを
	// 取れるようにする(Odin は関数パラメータのアドレスを直接取れない制約があるため)。
	// 以降 run_rom_window へはこの live_cfg を渡す。
	live_cfg := cfg

	// T9-3: 履歴ファイルの保存場所は設定ファイルと同じ場所(config_dir_path を共有)。
	// 解決できない場合は recent 機能全体を静かに無効化する(TUI自体の起動は妨げない、
	// config_load 側の「実行ファイルの場所を特定できない場合も起動は止めない」方針と揃える)。
	config_dir, config_dir_ok := config_dir_path()
	defer if config_dir_ok {
		delete(config_dir)
	}
	if !config_dir_ok {
		config_dir = ""
	}

	// --recent はTUIの初回表示だけに効かせる(BluePrint「--recent : 最近使ったファイルを
	// 表示して選択できる」)。T12-3でホーム画面を導入した後もこの優先順位を維持し、初回は
	// ホーム画面をスキップして直接 recent 画面を開く(2周目以降はホーム画面経由に戻る)。
	screen := Tui_Screen.Home
	if opts.recent {
		screen = .Recent
	}

	for {
		if screen == .Home {
			cmd := tui_run_command_home(&live_cfg, config_dir)
			if cmd.kind == .Quit {
				return
			}
			screen = cmd.kind == .Recent ? Tui_Screen.Recent : Tui_Screen.Browse
		}

		result: Rom_Browser_Result
		rom_path: string
		if screen == .Recent {
			result, rom_path = tui_run_recent_browser(config_dir)
		} else {
			result, rom_path = tui_run_rom_browser(start_dir, config_dir)
		}
		// ブラウザ画面から戻ったら次はホーム画面へ(q/Escで抜けた場合もLaunchした場合も)。
		screen = .Home

		if result == .Quit {
			continue // ホーム画面へ戻る(ループ先頭で tui_run_command_home が呼ばれる)
		}
		defer delete(rom_path)

		// T9-2「選択してEnter→TUIを一時停止(画面復元)→SDLでゲーム実行→ゲーム終了後TUIに戻る」。
		// 落とし穴: run_rom_window はROM読み込み/SDL初期化失敗時に os.exit(1) する
		// (これ自体はTUI起動前から既存の挙動)。その場合ターミナルは既に代替スクリーン外
		// (tui_suspend_for_game 済み)なので復元は壊れない。
		tui_suspend_for_game()
		game_opts := opts
		game_opts.rom_path = rom_path
		run_rom_window(game_opts, live_cfg, standalone_terminal = false)
		tui_resume_from_game()

		// T9-3「ROM起動成功のたびに更新」。run_rom_window がここまで戻ってきた時点で
		// (os.exit(1)していない=)起動成功とみなす。
		if config_dir_ok {
			recent_record_launch(config_dir, rom_path)
		}
	}
}

// --- 実行中ステータス表示(T9-4) ---
// BluePrint「TUIを活かすアイデアがあると助かります」。1行ステータスを stderr へ `\r` 上書きで
// 出す(落とし穴: stdout はシリアル出力等のログと衝突しうる)。TUI経由・直接起動どちらでも
// stderr が TTY なら表示する(T9-4「TUI経由でない起動でもTTYなら表示」)。

// status_cart_label は "MBC5+RAM" のようなラベルを作る(純粋関数)。
status_cart_label :: proc(info: core.Cartridge_Info, allocator := context.allocator) -> string {
	kind := mbc_kind_label(info.mbc_kind)
	if info.ram_size > 0 {
		return fmt.aprintf("%s+RAM", kind, allocator = allocator)
	}
	return strings.clone(kind, allocator)
}

// --- メッセージログ(T14-3) ---
// 単発表示だった操作メッセージ(音量変更/セーブ/ロード等)を履歴付きリングバッファに貯め、
// ゲーム中の Now Playing 画面(T14-4)のコンテンツ領域に直近数件を表示する。
// entries は必ず clone した所有文字列(借用を保持しない。呼び出し元の tprintf 借用が
// 次フレームで無効になるため)。
// タイムスタンプは付けない(core:time の time.now() は UTC で、ローカル時刻表示には
// タイムゾーン処理が必要になる。UTC の時刻表示はかえって誤解を招くため見送り、
// 将来 localtime 対応を入れる場合に再検討する)。

MESSAGE_LOG_CAP :: 32

Message_Log :: struct {
	entries: [MESSAGE_LOG_CAP]string, // 所有(clone 済み)。リングバッファ
	next:    int, // 次に書き込むインデックス
	count:   int, // 現在の件数(最大 MESSAGE_LOG_CAP)
}

// message_log_append は msg を clone してリングへ追記する(満杯なら最古を上書き解放)。
message_log_append :: proc(l: ^Message_Log, msg: string) {
	delete(l.entries[l.next])
	l.entries[l.next] = strings.clone(msg)
	l.next = (l.next + 1) % MESSAGE_LOG_CAP
	if l.count < MESSAGE_LOG_CAP {
		l.count += 1
	}
}

message_log_len :: proc(l: ^Message_Log) -> int {
	return l.count
}

// message_log_get は i 番目(0=最古、count-1=最新)のメッセージを返す(借用)。範囲外は ""。
message_log_get :: proc(l: ^Message_Log, i: int) -> string {
	if i < 0 || i >= l.count {
		return ""
	}
	start := (l.next - l.count + MESSAGE_LOG_CAP) % MESSAGE_LOG_CAP
	return l.entries[(start + i) % MESSAGE_LOG_CAP]
}

message_log_destroy :: proc(l: ^Message_Log) {
	for i in 0 ..< MESSAGE_LOG_CAP {
		delete(l.entries[i])
		l.entries[i] = ""
	}
	l.next = 0
	l.count = 0
}

Status_Line :: struct {
	enabled:      bool,
	rom_name:     string, // 所有(basename)
	cart_label:   string, // 所有("MBC5+RAM"等)
	window_start: time.Time, // 直近のfps計測窓の開始時刻
	frame_count:  int, // 窓内での実フレーム数
	warn:         bool, // 窓内でアンダーランが発生したか(T9-4「アンダーラン発生時は警告色」相当)
	last_message: string, // 所有。直前の操作結果(T9-5)。""なら無し
	last_line:    string, // 所有。直近に組み立てたステータス行(T13-3。シェルのステータス行にも使う)。""なら未組み立て
	last_fps:     f64, // T14-4: 直近の1秒窓で算出した fps(Now Playing パネル表示用)
	log:          ^Message_Log, // T14-3: 非nilなら set_message がここへも追記する(所有はしない)
}

// status_line_init は rom_path のベース名と cart_info から Status_Line を組み立てる。
// stderr が TTY でなければ enabled=false になり、以降の tick は何もしない(T9-4「非TTYなら
// 出さない」)。
status_line_init :: proc(rom_path: string, cart_info: core.Cartridge_Info) -> Status_Line {
	return Status_Line {
		enabled = terminal.is_terminal(os.stderr),
		rom_name = strings.clone(filepath.base(rom_path)),
		cart_label = status_cart_label(cart_info),
		window_start = time.now(),
	}
}

status_line_destroy :: proc(s: ^Status_Line) {
	delete(s.rom_name)
	delete(s.cart_label)
	delete(s.last_message)
	delete(s.last_line)
	// ステータス行(\rで行頭に戻ったまま終わっている)の後にシェルのプロンプト等が
	// そのまま続くと読みにくいので、有効だった場合だけ改行して終える。
	if s.enabled {
		fmt.eprintln()
	}
}

// status_line_set_message は直前の操作結果(T9-5: 音量変更/スロット選択/セーブ/ロード/
// 一時停止など)をステータス行に反映する。次の status_line_tick の描画時に一緒に出す
// (操作のたびに別行を eprintln すると `\r` の1行更新と競合して表示が乱れるため)。
status_line_set_message :: proc(s: ^Status_Line, msg: string) {
	if !s.enabled {
		return
	}
	delete(s.last_message)
	s.last_message = strings.clone(msg)
	// T14-3: ログが接続されていれば履歴にも残す(空メッセージはログを汚さない)。
	if s.log != nil && msg != "" {
		message_log_append(s.log, msg)
	}
}

STATUS_LINE_INTERVAL_SECONDS :: 1.0

// status_line_tick は毎フレーム呼ぶ(落とし穴: architecture.md「フレーム毎のアロケーション
// 禁止」を守るため、1秒の窓が満了した時だけ文字列を組み立てて書き出す。それ以外は
// frame_count のインクリメントのみでアロケーションなし)。
// status_line_record_frame は実フレームが1枚描画されるたびに呼ぶ(fps計測用のカウンタ加算
// のみ。バッファが目標を超えていて描画をスキップしたループ反復ではこれを呼ばないこと)。
status_line_record_frame :: proc(s: ^Status_Line) {
	if !s.enabled {
		return
	}
	s.frame_count += 1
}

// status_line_update は1秒窓の満了判定と last_line/last_fps の更新だけを行う(T14-4 で
// tick から分離)。窓が満了して内容を更新したら true を返す(シェル有効時は呼び出し側が
// これを dirty フラグに変換して再描画する。stderr への書き出しは行わない)。
status_line_update :: proc(s: ^Status_Line, volume: int, slot: int, double_speed: bool, paused: bool, underrun_now: bool) -> (updated: bool) {
	if !s.enabled {
		return false
	}
	if underrun_now {
		s.warn = true
	}

	elapsed_secs := time.duration_seconds(time.since(s.window_start))
	if elapsed_secs < STATUS_LINE_INTERVAL_SECONDS {
		return false
	}
	fps := f64(s.frame_count) / elapsed_secs
	s.last_fps = fps

	line := status_line_format(s^, fps, volume, slot, double_speed, paused)
	// 直近の描画内容を保持する(T13-3)。tprintf の借用をループをまたいで持つことはできない
	// ため clone する(context.allocator、temp不可の方針どおり)。
	delete(s.last_line)
	s.last_line = strings.clone(line)

	s.frame_count = 0
	s.window_start = time.now()
	s.warn = false
	return true
}

// status_line_tick は従来の1行ステータス表示(レガシーフォールバック: シェルを使えない
// 非TTY stdout 等の環境)。毎フレーム呼ぶ(落とし穴: architecture.md「フレーム毎の
// アロケーション禁止」を守るため、1秒の窓が満了した時だけ文字列を組み立てて書き出す)。
status_line_tick :: proc(s: ^Status_Line, volume: int, slot: int, double_speed: bool, paused: bool, underrun_now: bool) {
	if !status_line_update(s, volume, slot, double_speed, paused, underrun_now) {
		return
	}
	// "\x1b[K": カーソル位置から行末までクリアしてから書く(前回より短い行になった場合に
	// 古い文字が右側に残るのを防ぐ)。行末に改行は付けない(次回も同じ行を上書きするため)。
	fmt.eprintf("\r\x1b[K%s", s.last_line)
}

// status_line_format はステータス行の文字列を組み立てる(T13-3 で status_line_tick から抽出した
// 純粋関数、単体テスト対象)。fps は呼び出し側(tick)が計測窓から算出して渡す。
// T18-1: 実機でユーザーから「1行に詰め込みすぎ」との指摘があり整理した。
// ROM名・カートリッジ種別は shell_content_now_playing のコンテンツ領域見出しへ移動済み
// (T18-2)。コマンド実行結果(last_message)はコンテンツ領域のメッセージログに既に
// 表示されている(status_line_set_message が message_log へも追記する、tui.odin参照)ため
// ステータス行への重複表示をやめた。「双速」は分かりにくいとの指摘を受け「2倍速」に変更。
// 戻り値は fmt.tprintf の借用(使い捨て。保持する場合は呼び出し側が clone する)。
status_line_format :: proc(s: Status_Line, fps: f64, volume: int, slot: int, double_speed: bool, paused: bool) -> string {
	icon := paused ? "⏸" : "▶"
	speed_label := double_speed ? " | 2倍速" : ""
	// T9-4「オーディオアンダーラン発生時は警告色」。ANSIの黄色前景色(\x1b[33m)で挟む
	// (色が出ない端末でも "⚠" 自体がテキストとして意味を持つのでフォールバックになる)。
	warn_marker := s.warn ? " \x1b[33m⚠ underrun\x1b[0m" : ""

	return fmt.tprintf(
		"%s %.1f fps | vol %d%% | slot %d%s%s",
		icon,
		fps,
		volume,
		slot,
		speed_label,
		warn_marker,
	)
}

// T14-4: status_line_repaint(オーバーレイを閉じた直後の1行復元)はオーバーレイ撤去に伴い
// 削除した。シェル描画は毎回全画面を再構築するため復元処理自体が不要になった。

// --- ゲーム中の入力ルーティング(T14-5、T15-1 で生ホットキー廃止に伴い簡素化、純粋関数) ---
// T15-1: ユーザー要望「ゲーム中も同じモードで動くこと」により、1キーの生ホットキー
// (+,-,1-4,s,l,p、旧 game_key_to_action/Game_Action)を完全に廃止した。
// 印字可能な文字は常に入力行へ(バッファが空かどうかによる分岐は無くなった)。
// 音量の相対増減・セーブ/ロード・スロット選択・一時停止は全てスラッシュコマンド
// (/volume up|down、/save、/load、/slot N、/pause、/resume)経由になる(T15-2 参照)。
// 設定ビュー表示中は ↑↓←→ を常にメニューへ、Enter/Esc はバッファが空のときだけメニューへ
// (非空なら入力行の確定/クリア)、印字文字は入力行へ。

Game_Input_Route :: enum {
	None, // 無視(空バッファでの Enter 等)
	Menu, // menu_step へ渡す(設定ビュー)
	Editor, // 入力行へ(Char/Backspace)
	Submit, // コマンド確定(parse_game_command)
	Clear, // 入力バッファをクリア
}

game_input_route :: proc(ev: Key_Event, buffer_empty: bool, view: Game_View) -> Game_Input_Route {
	if view == .Settings {
		#partial switch ev.key {
		case .Up, .Down, .Left, .Right:
			return .Menu
		case .Enter, .Escape:
			if buffer_empty {
				return .Menu // menu_step が .Close を返す
			}
			return ev.key == .Enter ? .Submit : .Clear
		case .Char, .Backspace:
			return .Editor
		}
		return .None
	}

	#partial switch ev.key {
	case .Char, .Backspace:
		return .Editor
	case .Escape:
		return .Clear
	case .Enter:
		return buffer_empty ? .None : .Submit
	}
	return .None
}

// --- ゲーム実行中のコマンドモード(T12-5、T13-4 で拡張) ---
// T13-4: /set 以外にも settings/pause/resume/save/load/slot/quit を追加。全て既存バックエンド
// (handle_shortcut_action、paused、running)への写像のみで新規エミュ機能は無い。
// `settings` は T13-5 のオーバーレイメニュー(状態機械+毎フレーム1ステップ)を開く:
// ブロッキングループではないため SDL イベントポンプは止まらない(0a78a66 の幽霊化パターンを
// 構造的に回避。T12-5 時代の Settings_Unavailable workaround は廃止)。

Game_Command_Kind :: enum {
	Set,
	Settings, // オーバーレイ設定メニューを開く(T13-5)
	Pause,
	Resume,
	Save_State, // slot 引数は省略可(0=現在のスロット)
	Load_State, // slot 引数は省略可(0=現在のスロット)
	Select_Slot, // slot 引数必須(1-4)
	Volume_Up, // T15-2: 旧 `+` ホットキーの相対増減(AUDIO_VOLUME_STEP、非永続)を移植
	Volume_Down, // T15-2: 旧 `-` ホットキーの相対増減(AUDIO_VOLUME_STEP、非永続)を移植
	Quit,
	Unknown,
	Empty, // 空Enter(何もしない、コマンドモードを抜けるだけ)
}

Game_Command :: struct {
	kind:      Game_Command_Kind,
	raw:       string, // .Unknown 時のエラー表示用(input の借用)
	set_key:   string, // .Set 時のみ意味を持つ(input の借用)
	set_value: string, // .Set 時のみ意味を持つ(input の借用)
	slot:      int, // .Save_State/.Load_State/.Select_Slot 用。0=指定なし(現在のスロットを使う)
}

// game_command_parse_slot はスロット引数(1-4)を解釈する。範囲外・非数値は ok=false。
@(private = "file")
game_command_parse_slot :: proc(s: string) -> (slot: int, ok: bool) {
	n, parse_ok := strconv.parse_int(s)
	if !parse_ok || n < 1 || n > 4 {
		return 0, false
	}
	return n, true
}

// parse_game_command はゲーム中コマンドモードの入力を解釈する純粋関数(単体テスト対象)。
// `/` キー自体がコマンドモードへの唯一のトリガーであり画面上のプロンプトが常に "/" を
// 前置して表示するため(tui_run_command_home と違いプロンプト欄自体が空にならない)、
// ここで受け取る input には先頭の "/" を含めない(ユーザーは "/" キー押下後 "set volume 30"
// のように続けて打つ)。ホーム画面の parse_home_command と違い、画面遷移コマンド
// (/browse 等)は一切受け付けない(ゲーム中に ROM ブラウザへ遷移する概念が無いため)。
parse_game_command :: proc(input: string) -> Game_Command {
	trimmed := strings.trim_space(input)
	// T14-5: 入力行は常時アクティブになり、ユーザーが「/pause」のように `/` 付きで打つのが
	// 自然になった(ホーム画面のコマンド体系と同じ見た目)。先頭の `/` は1個だけ剥がして
	// 両対応にする(「pause」も「/pause」も同じ)。
	if strings.has_prefix(trimmed, "/") {
		trimmed = strings.trim_space(trimmed[1:])
	}
	if trimmed == "" {
		return Game_Command{kind = .Empty}
	}

	head := trimmed
	rest := ""
	if sp := strings.index_byte(trimmed, ' '); sp >= 0 {
		head = trimmed[:sp]
		rest = strings.trim_space(trimmed[sp + 1:])
	}

	switch head {
	case "settings":
		if rest == "" {
			return Game_Command{kind = .Settings}
		}
	case "pause":
		if rest == "" {
			return Game_Command{kind = .Pause}
		}
	case "resume":
		if rest == "" {
			return Game_Command{kind = .Resume}
		}
	case "quit", "exit":
		if rest == "" {
			return Game_Command{kind = .Quit}
		}
	case "save", "load":
		kind := head == "save" ? Game_Command_Kind.Save_State : Game_Command_Kind.Load_State
		if rest == "" {
			return Game_Command{kind = kind}
		}
		if slot, ok := game_command_parse_slot(rest); ok {
			return Game_Command{kind = kind, slot = slot}
		}
	case "slot":
		if slot, ok := game_command_parse_slot(rest); ok {
			return Game_Command{kind = .Select_Slot, slot = slot}
		}
	case "volume":
		// T15-2: 旧 `+`/`-` ホットキーの相対増減を移植(AUDIO_VOLUME_STEP刻み、非永続)。
		// `/set volume <n>`(絶対値・config_apply_set 経由で bbl.ini へ永続化)とは別物として共存する。
		if rest == "up" {
			return Game_Command{kind = .Volume_Up}
		}
		if rest == "down" {
			return Game_Command{kind = .Volume_Down}
		}
	case "set":
		sp := strings.index_byte(rest, ' ')
		if sp > 0 {
			key := strings.trim_space(rest[:sp])
			value := strings.trim_space(rest[sp + 1:])
			if key != "" && value != "" {
				return Game_Command{kind = .Set, set_key = key, set_value = value}
			}
		}
	}
	return Game_Command{kind = .Unknown, raw = trimmed}
}

// --- Line_Editor(T12-1): 複数文字コマンド入力用の最小限の行入力バッファ ---
// ホーム画面(T12-3)とゲーム実行中のコマンドモード(T12-5)の両方で再利用する。
// カーソル移動(左右)は実装しない(末尾追記 + Backspace のみ、要望に含まれないため)。
// context.temp_allocator は使わない(T9-6 で踏んだ -o:speed ビルド時の実機バグの再発防止、
// このファイル冒頭コメント参照)。

Line_Editor :: struct {
	buf: [dynamic]u8,
}

line_editor_destroy :: proc(e: ^Line_Editor) {
	delete(e.buf)
}

// line_editor_text は現在バッファされている文字列を返す(借用、e より長生きさせないこと)。
line_editor_text :: proc(e: Line_Editor) -> string {
	return string(e.buf[:])
}

// line_editor_reset はバッファを空にする(確定後の再利用、またはキャンセル時に呼ぶ)。
line_editor_reset :: proc(e: ^Line_Editor) {
	clear(&e.buf)
}

// line_editor_feed は1キーイベントを処理する純粋関数(単体テスト対象)。
// Enter で確定(submitted=true、text は呼び出し側の allocator で確保した所有権付き文字列。
// 呼び出し側が delete すること)。内部バッファは確定と同時にクリアする(次の入力に混ざらないため)。
// Escape はバッファをクリアしてキャンセル扱い(submitted=false)。
// 印字可能文字(0x20-0x7E)のみ受理し、Tab や Ctrl 系(0x01-0x1F)は無視する
// (tui_parse_key は 0x80 未満を無条件で .Char にするため、ここでフィルタする)。
line_editor_feed :: proc(e: ^Line_Editor, ev: Key_Event, allocator := context.allocator) -> (submitted: bool, text: string) {
	#partial switch ev.key {
	case .Enter:
		s := strings.clone(string(e.buf[:]), allocator)
		clear(&e.buf)
		return true, s
	case .Backspace:
		if len(e.buf) > 0 {
			pop(&e.buf)
		}
	case .Escape:
		clear(&e.buf)
	case .Char:
		if ev.ch >= 0x20 && ev.ch <= 0x7E {
			append(&e.buf, u8(ev.ch))
		}
	}
	return false, ""
}
