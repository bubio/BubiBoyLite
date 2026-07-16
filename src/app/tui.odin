package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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

// tui_suspend_for_game は ROM 選択画面から SDL ゲーム実行へ移る前に呼ぶ: 代替スクリーンを
// 抜けてカーソルを表示し(SDLウィンドウが主役になるため、起動元ターミナルはBluePrint
// 「TUIを活かすアイデア」のステータス行表示に使う、T9-4)、ターミナル読み取りを
// 完全ノンブロッキング(VMIN=0/VTIME=0)に切り替える(T9-5「メインループを止めない」)。
tui_suspend_for_game :: proc() {
	tui_plat_write_raw(CURSOR_SHOW)
	tui_plat_write_raw(ALT_SCREEN_EXIT)
	tui_plat_set_read_timeout_deciseconds(0)
}

// tui_resume_from_game は SDL ゲーム終了後に ROM 選択画面へ戻るときに呼ぶ。
tui_resume_from_game :: proc() {
	tui_plat_write_raw(ALT_SCREEN_ENTER)
	tui_plat_write_raw(CURSOR_HIDE)
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
// true を返す(呼び出し側は対になる tui_exit() を必ず呼ぶこと)。TUI経由の場合はこの関数を
// 呼ばないこと(既にtui_enterでraw modeが有効なため、ここで再度tcgetattrすると
// 復元用に保存した「本来の端末状態」を上書きしてしまう)。
// 落とし穴(tui_enterのコメント参照): `context.assertion_failure_proc` の代入はこの関数の
// 中で行っても呼び出し元には伝播しないため、呼び出し側(run_rom_window)自身の関数本体で
// `context.assertion_failure_proc = tui_assertion_failure` を設定すること。
tui_game_terminal_begin :: proc() -> bool {
	if !tui_game_terminal_available() {
		return false
	}
	if !tui_plat_enable_raw() {
		return false
	}
	tui_restored = false
	tui_plat_install_crash_restore()
	tui_plat_set_read_timeout_deciseconds(0) // 完全ノンブロッキング(T9-5「メインループを止めない」)
	return true
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
			frame := Tui_Frame {
				cols     = cols,
				rows     = rows,
				title    = fmt.tprintf("BubiBoyLite v%s", VERSION),
				heading  = fmt.tprintf("ROM を選択してください  [%s]", cwd),
				status   = status,
				items    = items,
				selected = selected,
				footer   = "↑↓ 選択  Enter 起動/移動  q 終了",
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
			frame := Tui_Frame {
				cols     = cols,
				rows     = rows,
				title    = fmt.tprintf("BubiBoyLite v%s", VERSION),
				heading  = "最近使ったファイル",
				status   = status,
				items    = items,
				selected = selected,
				footer   = "↑↓ 選択  Enter 起動  q 終了",
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

// run_tui は main.odin から呼ばれるエントリポイント。非TTYなら起動せずエラー+exit 1
// (T9-1完了条件)。ROM選択→起動→終了後にROM選択へ戻る、を q で抜けるまで繰り返す(T9-2)。
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
	defer tui_exit() // 通常のreturn経路(qで抜けた場合)ではdeferで問題ない。
	// 異常系(シグナル/panic)は tui_plat_install_crash_restore(シグナル) と
	// context.assertion_failure_proc(panic/assert) の両方で復元される。

	start_dir := strings.trim_space(cfg.rom_dir) != "" ? cfg.rom_dir : "."

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
	// 表示して選択できる」。ゲームから戻るたびに履歴だけを再表示し続けると新しいROMを
	// 選びにくくなるため、2周目以降は通常のディレクトリ一覧に戻す)。
	// Odin の値渡し引数は書き換え不可なので、ループで変化させるローカル変数にコピーする。
	show_recent_first := opts.recent

	for {
		result: Rom_Browser_Result
		rom_path: string
		if show_recent_first {
			result, rom_path = tui_run_recent_browser(config_dir)
			show_recent_first = false
		} else {
			result, rom_path = tui_run_rom_browser(start_dir, config_dir)
		}
		if result == .Quit {
			return
		}
		defer delete(rom_path)

		// T9-2「選択してEnter→TUIを一時停止(画面復元)→SDLでゲーム実行→ゲーム終了後TUIに戻る」。
		// 落とし穴: run_rom_window はROM読み込み/SDL初期化失敗時に os.exit(1) する
		// (これ自体はTUI起動前から既存の挙動)。その場合ターミナルは既に代替スクリーン外
		// (tui_suspend_for_game 済み)なので復元は壊れない。
		tui_suspend_for_game()
		game_opts := opts
		game_opts.rom_path = rom_path
		run_rom_window(game_opts, cfg, standalone_terminal = false)
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

Status_Line :: struct {
	enabled:      bool,
	rom_name:     string, // 所有(basename)
	cart_label:   string, // 所有("MBC5+RAM"等)
	window_start: time.Time, // 直近のfps計測窓の開始時刻
	frame_count:  int, // 窓内での実フレーム数
	warn:         bool, // 窓内でアンダーランが発生したか(T9-4「アンダーラン発生時は警告色」相当)
	last_message: string, // 所有。直前の操作結果(T9-5)。""なら無し
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

status_line_tick :: proc(s: ^Status_Line, volume: int, slot: int, double_speed: bool, paused: bool, underrun_now: bool) {
	if !s.enabled {
		return
	}
	if underrun_now {
		s.warn = true
	}

	elapsed_secs := time.duration_seconds(time.since(s.window_start))
	if elapsed_secs < STATUS_LINE_INTERVAL_SECONDS {
		return
	}
	fps := f64(s.frame_count) / elapsed_secs

	icon := paused ? "⏸" : "▶"
	speed_label := double_speed ? " | 双速" : ""
	// T9-4「オーディオアンダーラン発生時は警告色」。ANSIの黄色前景色(\x1b[33m)で挟む
	// (色が出ない端末でも "⚠" 自体がテキストとして意味を持つのでフォールバックになる)。
	warn_marker := s.warn ? " \x1b[33m⚠ underrun\x1b[0m" : ""
	msg_suffix := s.last_message != "" ? fmt.tprintf(" | %s", s.last_message) : ""

	line := fmt.tprintf(
		"%s %s | %.1f fps | vol %d%% | slot %d | %s%s%s%s",
		icon,
		s.rom_name,
		fps,
		volume,
		slot,
		s.cart_label,
		speed_label,
		warn_marker,
		msg_suffix,
	)
	// "\x1b[K": カーソル位置から行末までクリアしてから書く(前回より短い行になった場合に
	// 古い文字が右側に残るのを防ぐ)。行末に改行は付けない(次回も同じ行を上書きするため)。
	fmt.eprintf("\r\x1b[K%s", line)

	s.frame_count = 0
	s.window_start = time.now()
	s.warn = false
}

// --- ゲーム実行中のターミナルホットキー(T9-5) ---

Game_Action :: enum {
	None,
	Volume_Up,
	Volume_Down,
	Select_Slot,
	Save_State,
	Load_State,
	Toggle_Pause,
}

// game_key_to_action は T9-5 のホットキー(+/-音量、1-4スロット、s保存、l復元、p一時停止)を
// 解釈する純粋関数(単体テスト対象)。slot は .Select_Slot の時だけ意味を持つ(1-4)。
game_key_to_action :: proc(ev: Key_Event) -> (action: Game_Action, slot: int) {
	if ev.key != .Char {
		return .None, 0
	}
	switch ev.ch {
	case '+':
		return .Volume_Up, 0
	case '-':
		return .Volume_Down, 0
	case '1':
		return .Select_Slot, 1
	case '2':
		return .Select_Slot, 2
	case '3':
		return .Select_Slot, 3
	case '4':
		return .Select_Slot, 4
	case 's':
		return .Save_State, 0
	case 'l':
		return .Load_State, 0
	case 'p':
		return .Toggle_Pause, 0
	}
	return .None, 0
}
