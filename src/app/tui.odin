package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"

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

ALT_SCREEN_ENTER :: "\x1b[?1049h"
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

Tui_Frame :: struct {
	cols:     int, // 端末の列数(0 以下ならデフォルト幅を使う)
	rows:     int,
	title:    string, // 上枠に表示するタイトル
	heading:  string, // 本文見出し
	status:   string, // 見出し下に出す追加行(エラー等)。空文字なら出さない
	items:    []List_Item,
	selected: int, // items のうちカーソル(▸)が当たっている index。範囲外なら非表示
	footer:   string, // 枠の下に出すキーヒント行
}

FRAME_MIN_WIDTH :: 40
FRAME_MAX_WIDTH :: 100
FRAME_DEFAULT_COLS :: 80

// tui_render_frame は Tui_Frame から1画面分の ANSI 文字列を組み立てる。
// 副作用なし(ファイル書き込み等は行わない)なので、内容の検証は文字列比較で完結できる
// (advisor 指摘: 「実際の見た目を目で確認できない」ことへの対策として、描画とI/Oを分離する)。
tui_render_frame :: proc(frame: Tui_Frame) -> string {
	b: strings.Builder
	strings.builder_init(&b)

	cols := frame.cols
	if cols <= 0 {
		cols = FRAME_DEFAULT_COLS
	}
	width := cols - 4
	if width < FRAME_MIN_WIDTH {
		width = FRAME_MIN_WIDTH
	}
	if width > FRAME_MAX_WIDTH {
		width = FRAME_MAX_WIDTH
	}

	strings.write_string(&b, CURSOR_HOME)
	strings.write_string(&b, CLEAR_SCREEN)

	// 上枠: "┌─ <title> ────...──┐"
	strings.write_string(&b, "┌─ ")
	strings.write_string(&b, frame.title)
	strings.write_string(&b, " ")
	used := display_width(frame.title) + 4 // "┌─ "(2幅+1) + title + " "(1) の合計相当
	dash_count := width - used
	if dash_count < 0 {
		dash_count = 0
	}
	for _ in 0 ..< dash_count {
		strings.write_string(&b, "─")
	}
	strings.write_string(&b, "┐\n")

	write_row(&b, width, fmt.tprintf("  %s", frame.heading))
	if frame.status != "" {
		write_row(&b, width, fmt.tprintf("  %s", frame.status))
	}
	write_row(&b, width, "")

	for item, i in frame.items {
		marker := i == frame.selected ? "▸ " : "  "
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
		write_row(&b, width, line)
	}

	strings.write_string(&b, "└")
	for _ in 0 ..< width {
		strings.write_string(&b, "─")
	}
	strings.write_string(&b, "┘\n")

	strings.write_string(&b, " ")
	strings.write_string(&b, frame.footer)
	strings.write_string(&b, "\n")

	return strings.to_string(b)
}

@(private = "file")
write_row :: proc(b: ^strings.Builder, width: int, text: string) {
	strings.write_string(b, "│")
	write_padded(b, text, width)
	strings.write_string(b, "│\n")
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
@(private = "file")
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

// --- 端末サイズ ---

TERM_FALLBACK_COLS :: 80
TERM_FALLBACK_ROWS :: 24

// tui_term_size は現在の端末サイズを返す。取得できない場合は 80x24 にフォールバックする
// (advisor 指摘: 変則的な端末でも落ちないようにする)。
tui_term_size :: proc() -> (cols, rows: int) {
	c, r, ok := tui_plat_term_size()
	if !ok || c <= 0 || r <= 0 {
		return TERM_FALLBACK_COLS, TERM_FALLBACK_ROWS
	}
	return c, r
}

// --- 描画の書き出し ---

// tui_write_frame は tui_render_frame の結果を1回の write でまとめて出力する
// (T9-1「描画は全画面を文字列バッファに構築して一括write」)。
tui_write_frame :: proc(frame: Tui_Frame) {
	s := tui_render_frame(frame)
	defer delete(s)
	os.write_string(os.stdout, s)
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

// --- T9-1 デモ画面 ---

// tui_run_demo は T9-1 の完了条件「デモ画面(枠+カーソル移動)が表示され、q で元のターミナル
// 状態に完全復元される」を満たす最小デモ。矢印キーでカーソル(▸)を上下に動かし、q/Escで終了する。
// この画面が使う tui_render_frame / Tui_Frame は T9-2 で実際の ROM 一覧描画にそのまま再利用する。
tui_run_demo :: proc() {
	items := []List_Item {
		{label = "デモ項目 1", info = "(A)"},
		{label = "デモ項目 2", info = "(B)"},
		{label = "デモ項目 3", info = "(C)"},
	}
	selected := 0
	kr: Key_Reader

	// dirty: 「今の画面内容がまだ描画されていない」を表す。落とし穴(実装中に検証で発見):
	// ループの毎回 tui_write_frame するとキー入力が無いアイドル中も高頻度(30msごと)に
	// 全画面書き込みが走り続け、端末側の読み出しが追いつかない状況(遅い端末エミュレータ、
	// 自動テストのパイプ等)で write が長時間ブロックしうる。「状態が変わった時だけ描画」に
	// することでアイドル中の書き込みを完全に無くす(ちらつき防止の観点でも本来この方が正しい)。
	last_cols, last_rows := -1, -1
	dirty := true

	for {
		cols, rows := tui_term_size()
		if cols != last_cols || rows != last_rows {
			last_cols, last_rows = cols, rows
			dirty = true
		}

		if dirty {
			frame := Tui_Frame {
				cols     = cols,
				rows     = rows,
				title    = fmt.tprintf("BubiBoyLite v%s (デモ)", VERSION),
				heading  = "矢印キーでカーソルを動かせます",
				items    = items,
				selected = selected,
				footer   = "↑↓ 選択  q 終了",
			}
			tui_write_frame(frame)
			dirty = false
		}

		ev, ok := key_reader_poll(&kr)
		if !ok {
			tui_plat_sleep_ms(30)
			continue
		}
		#partial switch ev.key {
		case .Up:
			if selected > 0 {
				selected -= 1
				dirty = true
			}
		case .Down:
			if selected < len(items) - 1 {
				selected += 1
				dirty = true
			}
		case .Escape:
			return
		case .Char:
			if ev.ch == 'q' {
				return
			}
		}
	}
}

// run_tui は main.odin から呼ばれるエントリポイント(T9-1時点ではデモのみ、T9-2以降で
// ROM選択に置き換える)。非TTYなら起動せずエラー+exit 1(T9-1完了条件)。
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
	// これにより tui_run_demo 以降(将来の ROM 一覧・ゲーム起動フロー含む)の panic() を
	// 全てここで捕捉できる。
	context.assertion_failure_proc = tui_assertion_failure
	defer tui_exit() // 通常のreturn経路(qで抜けた場合)ではdeferで問題ない。
	// 異常系(シグナル/panic)は tui_plat_install_crash_restore(シグナル) と
	// context.assertion_failure_proc(panic/assert) の両方で復元される。

	tui_run_demo()
}
