package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import core "bbl:core"
import sdl "vendor:sdl2"

// config.odin: 設定ファイル(bbl.ini)の読み込み/生成(T8-1)。
// BluePrint「設定ファイルの場所」: 実行ファイルと同じ場所、起動時になければ全デフォルト値で作成。
// 優先順位は CLI引数 > 設定ファイル > デフォルト(BluePrint「引数で一時的な設定変更も可能」)。
// CLI引数は「一時的な変更」であり、設定ファイルへは書き戻さない。

CONFIG_FILE_NAME :: "bbl.ini"

// Config は bbl.ini の内容を表す(デフォルト値 = default_config())。
Config :: struct {
	scale:      int,
	fullscreen: bool,
	shader:     Shader_Kind,
	save_dir:   string, // 空 = ROM と同じ場所(T8-4で使用)
	state_dir:  string, // 空 = ROM と同じ場所(T8-4で使用)
	rom_dir:    string, // 空 = 実行ファイルのカレントディレクトリ(T9-2、TUIのROM一覧の起動ディレクトリ)
	volume:     int, // 0-100
	key_map:    [core.Button]sdl.Keycode,
	pad_map:    [core.Button]sdl.GameControllerButton,
}

DEFAULT_VOLUME :: 100

// default_key_map は input.odin の既存デフォルト割当(T3-7)と同じ内容(矢印キー=十字キー、
// Z=B、X=A、Enter=Start、右Shift=Select)。
default_key_map :: proc() -> [core.Button]sdl.Keycode {
	m: [core.Button]sdl.Keycode
	m[.Right] = .RIGHT
	m[.Left] = .LEFT
	m[.Up] = .UP
	m[.Down] = .DOWN
	m[.B] = .z
	m[.A] = .x
	m[.Start] = .RETURN
	m[.Select] = .RSHIFT
	return m
}

// default_pad_map はコントローラーのデフォルト割当(T8-5)。
// 落とし穴(phase-08「落とし穴」欄): SDL の GameControllerButton は Xbox 配置基準の命名で、
// 物理的な A/B の位置が Nintendo のゲームボーイと左右逆になる。Nintendo 配置に合わせるため
// GB の A ボタンには SDL の B ボタン(物理的に右側)を、GB の B ボタンには SDL の A ボタン
// (物理的に下側)を割り当てる。
default_pad_map :: proc() -> [core.Button]sdl.GameControllerButton {
	m: [core.Button]sdl.GameControllerButton
	m[.Right] = .DPAD_RIGHT
	m[.Left] = .DPAD_LEFT
	m[.Up] = .DPAD_UP
	m[.Down] = .DPAD_DOWN
	m[.A] = .B
	m[.B] = .A
	m[.Start] = .START
	m[.Select] = .BACK
	return m
}

default_config :: proc() -> Config {
	return Config {
		scale = DEFAULT_SCALE,
		fullscreen = false,
		shader = .Nearest,
		save_dir = "",
		state_dir = "",
		rom_dir = "",
		volume = DEFAULT_VOLUME,
		key_map = default_key_map(),
		pad_map = default_pad_map(),
	}
}

// gb_button_order はファイル出力・衝突チェックなどで安定した順序が欲しい箇所のための一覧。
// core.Button は Odin の enum なので for..in で網羅できるが、生成する bbl.ini の見た目を
// 分かりやすくする(十字キー→A/B→Start/Select の順)ためこの並びを使う。
gb_button_order := [8]core.Button{.Up, .Down, .Left, .Right, .A, .B, .Start, .Select}

@(private = "file")
button_key_name :: proc(b: core.Button) -> string {
	switch b {
	case .Right:
		return "right"
	case .Left:
		return "left"
	case .Up:
		return "up"
	case .Down:
		return "down"
	case .A:
		return "a"
	case .B:
		return "b"
	case .Select:
		return "select"
	case .Start:
		return "start"
	}
	return ""
}

// --- INI パース(依存ライブラリなしの自前パーサ) ---

// config_parse_ini は `key = value` 形式のテキストを解析する。`#` から行末まではコメント。
// 空行・空白のみの行は無視する。同じキーが複数回出現した場合は最後の値が勝つ。
// 引数・戻り値ともに純粋なデータのみを扱う(ファイルI/O非依存)ので単体テスト可能。
// 落とし穴: 戻り値のマップのキー・値は text 引数のスライスをそのまま指す(コピーしない)。
// text より長生きさせて参照する場合(save_dir/state_dir など)は呼び出し側で明示的に
// strings.clone すること(config_apply_raw 参照)。text 自体は呼び出し側が生存管理する。
config_parse_ini :: proc(text: string, allocator := context.allocator) -> map[string]string {
	result := make(map[string]string, allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 {
			continue // "=" が無い行は不正行として無視(致命的にしない)
		}
		key := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq + 1:])
		if key == "" {
			continue
		}
		result[key] = value
	}
	return result
}

// config_patch_ini は元の bbl.ini テキストを行単位で走査し、changes に含まれるキーの行だけ
// 値を置換する(T12-2)。config_parse_ini とは異なり、コメント・空行・他のキーの行・行順を
// 一切変更しない(map 再シリアライズだと `#` コメントと Odin の map 順不定によるキー順の
// 揺れで bbl.ini の見た目が壊れるため、この関数は使わない)。changes に無いキーで元ファイルに
// 存在しないものは末尾に追記する。呼び出し側は「そのセッションで /set により明示的に変更された
// キー」だけを changes に渡すこと(CLI 引数由来の一時的な値を混ぜないこと、config.odin 冒頭の
// 「CLI引数は一時的な変更であり書き戻さない」方針を守るため)。
config_patch_ini :: proc(original: string, changes: map[string]string, allocator := context.allocator) -> string {
	lines := strings.split_lines(original, context.temp_allocator)
	applied := make(map[string]bool, len(changes), context.temp_allocator)

	b: strings.Builder
	strings.builder_init(&b, allocator)

	for line, i in lines {
		trimmed := strings.trim_space(line)
		matched_key := ""
		if trimmed != "" && trimmed[0] != '#' {
			eq := strings.index_byte(trimmed, '=')
			if eq >= 0 {
				key := strings.trim_space(trimmed[:eq])
				if key in changes {
					matched_key = key
				}
			}
		}
		if matched_key != "" {
			strings.write_string(&b, fmt.tprintf("%s = %s", matched_key, changes[matched_key]))
			applied[matched_key] = true
		} else {
			strings.write_string(&b, line)
		}
		if i < len(lines) - 1 {
			strings.write_byte(&b, '\n')
		}
	}

	// changes のうち元ファイルに該当行が無かったキーは末尾に追記する。
	// gb_button_order と違い changes は任意のキー集合なので、安定した見た目は保証しない
	// (通常は /set で1キーずつ変更する運用のため実害は無い)。
	for key, value in changes {
		if key not_in applied {
			if len(strings.to_string(b)) > 0 {
				strings.write_byte(&b, '\n')
			}
			strings.write_string(&b, fmt.tprintf("%s = %s", key, value))
		}
	}

	return strings.to_string(b)
}

// config_patch_file は path を読み込み、config_patch_ini で changes を適用してから書き戻す
// (T12-2、/settings・/set の書き込み先)。読み込み・書き込みに失敗した場合は ok=false
// (呼び出し側はエラーメッセージを表示するに留め、クラッシュしないこと)。
config_patch_file :: proc(path: string, changes: map[string]string) -> (ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false
	}
	defer delete(data)

	patched := config_patch_ini(string(data), changes)
	defer delete(patched)

	if err := os.write_entire_file(path, transmute([]u8)patched); err != nil {
		return false
	}
	return true
}

// config_apply_set は TUI の `/set`/`/settings`(T12-4)で1キーの値を検証・適用する。
// 対象は scale/fullscreen/shader/volume の基本項目のみ(key_*/pad_* は対象外、プラン方針)。
// 不正な値は cfg を変更せずエラーメッセージだけ返す。成功時は cfg^ を更新した上で、
// config_dir が解決できていれば bbl.ini へそのキーだけを即時パッチする(config_patch_file、
// map 再シリアライズではなく行単位パッチなのでコメント・他の設定は保持される)。
// config_dir が空(config_dir_path() 解決失敗)の場合はファイル書き込みをスキップし、
// その旨をメッセージに含める(クラッシュしないこと)。
config_apply_set :: proc(cfg: ^Config, config_dir: string, key: string, value: string) -> (ok: bool, message: string) {
	switch key {
	case "scale":
		n, parse_ok := strconv.parse_int(value)
		if !parse_ok || n < 1 || n > MAX_SCALE {
			return false, fmt.tprintf("scale の値が不正です(1〜8の整数): %q", value)
		}
		cfg.scale = n
	case "fullscreen":
		b, parse_ok := parse_bool(value)
		if !parse_ok {
			return false, fmt.tprintf("fullscreen の値が不正です(true/false): %q", value)
		}
		cfg.fullscreen = b
	case "shader":
		switch strings.to_lower(value, context.temp_allocator) {
		case "nearest":
			cfg.shader = .Nearest
		case "smooth":
			cfg.shader = .Smooth
		case:
			return false, fmt.tprintf("shader の値が不正です(nearest/smooth): %q", value)
		}
	case "volume":
		n, parse_ok := strconv.parse_int(value)
		if !parse_ok || n < 0 || n > 100 {
			return false, fmt.tprintf("volume の値が不正です(0〜100の整数): %q", value)
		}
		cfg.volume = n
	case:
		return false, fmt.tprintf("不明な設定項目です: %q(scale/fullscreen/shader/volume のみ対応)", key)
	}

	if strings.trim_space(config_dir) == "" {
		return true, fmt.tprintf("%s を更新しました(設定の保存先が見つからないためメモリ上のみ反映)", key)
	}
	// config_path は fmt.tprintf(temp_allocator)の戻り値なので明示的な delete はしない
	// (呼び出し元の main.odin/config_load と同じ扱い)。
	path := config_path(config_dir)
	changes := make(map[string]string, 1, context.temp_allocator)
	changes[key] = value
	if !config_patch_file(path, changes) {
		return true, fmt.tprintf("%s を更新しましたが bbl.ini への書き込みに失敗しました", key)
	}
	return true, fmt.tprintf("%s = %s に更新しました", key, value)
}

@(private = "file")
warn_invalid :: proc(key: string, value: string, reason: string) {
	fmt.eprintfln("config: %s の値が不正です(%s): %q。デフォルト値を使用します。", key, reason, value)
}

// config_apply_raw は config_parse_ini が返した生の key=value を base の上に適用する。
// 不正な値は警告して該当フィールドだけデフォルト(base の値)のままにする(起動は止めない、
// T8-1 完了条件)。
config_apply_raw :: proc(base: Config, raw: map[string]string) -> Config {
	cfg := base

	if v, ok := raw["scale"]; ok {
		n, parse_ok := strconv.parse_int(v)
		if !parse_ok || n < 1 || n > MAX_SCALE {
			warn_invalid("scale", v, "1〜8の整数である必要があります")
		} else {
			cfg.scale = n
		}
	}

	if v, ok := raw["fullscreen"]; ok {
		b, parse_ok := parse_bool(v)
		if !parse_ok {
			warn_invalid("fullscreen", v, "true/false である必要があります")
		} else {
			cfg.fullscreen = b
		}
	}

	if v, ok := raw["shader"]; ok {
		switch strings.to_lower(v, context.temp_allocator) {
		case "nearest":
			cfg.shader = .Nearest
		case "smooth":
			cfg.shader = .Smooth
		case:
			warn_invalid("shader", v, "nearest または smooth である必要があります")
		}
	}

	// save_dir/state_dir/rom_dir は Config として長生きするため、raw (text の一部を指す
	// スライス) をそのまま持たせず clone する(config_parse_ini の docコメント参照)。
	if v, ok := raw["save_dir"]; ok {
		cfg.save_dir = strings.clone(v)
	}
	if v, ok := raw["state_dir"]; ok {
		cfg.state_dir = strings.clone(v)
	}
	if v, ok := raw["rom_dir"]; ok {
		cfg.rom_dir = strings.clone(v)
	}

	if v, ok := raw["volume"]; ok {
		n, parse_ok := strconv.parse_int(v)
		if !parse_ok || n < 0 || n > 100 {
			warn_invalid("volume", v, "0〜100の整数である必要があります")
		} else {
			cfg.volume = n
		}
	}

	for b in gb_button_order {
		key_name := fmt.tprintf("key_%s", button_key_name(b))
		if v, ok := raw[key_name]; ok {
			cstr := strings.clone_to_cstring(v, context.temp_allocator)
			sym := sdl.GetKeyFromName(cstr)
			if sym == .UNKNOWN {
				warn_invalid(key_name, v, "SDLが認識できないキー名です")
			} else {
				cfg.key_map[b] = sym
			}
		}

		pad_key_name := fmt.tprintf("pad_%s", button_key_name(b))
		if v, ok := raw[pad_key_name]; ok {
			cstr := strings.clone_to_cstring(v, context.temp_allocator)
			btn := sdl.GameControllerGetButtonFromString(cstr)
			if btn == .INVALID {
				warn_invalid(pad_key_name, v, "SDLが認識できないボタン名です")
			} else {
				cfg.pad_map[b] = btn
			}
		}
	}

	return cfg
}

@(private = "file")
parse_bool :: proc(s: string) -> (value: bool, ok: bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "true", "1", "yes", "on":
		return true, true
	case "false", "0", "no", "off":
		return false, true
	}
	return false, false
}

// --- ショートカットキー衝突チェック(T8-6) ---

// is_reserved_shortcut_key はセーブステート操作(F1-F5、F7)・終了(Esc)に使われるキーかどうかを
// 返す。input.odin の input_handle_shortcut_key / main.odin の Esc 終了処理と対応関係を保つ
// (割当を変えたらここも合わせて変更すること)。
is_reserved_shortcut_key :: proc(key: sdl.Keycode) -> bool {
	#partial switch key {
	case .F1, .F2, .F3, .F4, .F5, .F7, .ESCAPE:
		return true
	}
	return false
}

// config_key_map_conflicts は key_map の中でショートカットキーと衝突しているボタンの集合を返す
// (T8-6「ショートカット(F5等)とゲーム入力の衝突チェック」)。純粋関数として実装し、
// 実際の警告出力(config_warn_key_conflicts)と分離することで単体テスト可能にする。
config_key_map_conflicts :: proc(key_map: [core.Button]sdl.Keycode) -> bit_set[core.Button] {
	conflicts: bit_set[core.Button]
	for b in core.Button {
		if is_reserved_shortcut_key(key_map[b]) {
			conflicts += {b}
		}
	}
	return conflicts
}

@(private = "file")
config_warn_key_conflicts :: proc(key_map: [core.Button]sdl.Keycode) {
	conflicts := config_key_map_conflicts(key_map)
	for b in core.Button {
		if b in conflicts {
			fmt.eprintfln(
				"config: key_%s (%s) はセーブステート/終了ショートカットと衝突しています",
				button_key_name(b),
				sdl.GetKeyName(key_map[b]),
			)
		}
	}
}

// --- デフォルト bbl.ini の生成内容 ---

// config_render_default_ini は default_config() の内容をコメント付き INI として文字列化する
// (T8-1 DoD「デフォルト生成内容」、T8-6「デフォルト生成される bbl.ini に全割当をコメント付きで
// 出力」)。SDL の GetKeyName/GetStringForButton を使って往復可能な名前で書き出す(手書き文字列と
// パーサの不整合を避けるため)。
config_render_default_ini :: proc() -> string {
	cfg := default_config()
	b: strings.Builder
	strings.builder_init(&b)

	strings.write_string(&b, "# BubiBoyLite 設定ファイル (bbl.ini)\n")
	strings.write_string(&b, "# 起動時にこのファイルが無ければ全デフォルト値で自動生成されます。\n")
	strings.write_string(&b, "# コマンドライン引数はここに書かれた値を一時的に上書きしますが、書き戻しはしません。\n")
	strings.write_string(&b, "# '#' から行末まではコメントです。\n\n")

	strings.write_string(&b, "# 表示倍率 (1-8、9以上は8として扱われます)\n")
	strings.write_string(&b, fmt.tprintf("scale = %d\n\n", cfg.scale))

	strings.write_string(&b, "# フルスクリーン表示 (true / false)\n")
	strings.write_string(&b, fmt.tprintf("fullscreen = %s\n\n", cfg.fullscreen ? "true" : "false"))

	strings.write_string(&b, "# シェーダー (nearest / smooth)\n")
	strings.write_string(&b, fmt.tprintf("shader = %s\n\n", cfg.shader == .Smooth ? "smooth" : "nearest"))

	strings.write_string(&b, "# セーブファイル(.sav/.rtc)の保存先ディレクトリ。空欄ならROMファイルと同じ場所。\n")
	strings.write_string(&b, "# ~ や環境変数(HOME/USERPROFILE等)展開に対応。例: save_dir = ~/BubiBoyLite/saves\n")
	strings.write_string(&b, fmt.tprintf("save_dir = %s\n\n", cfg.save_dir))

	strings.write_string(&b, "# ステートファイル(.state)の保存先ディレクトリ。空欄ならROMファイルと同じ場所。\n")
	strings.write_string(&b, fmt.tprintf("state_dir = %s\n\n", cfg.state_dir))

	strings.write_string(&b, "# TUI(bblを引数無しで起動した時)のROM一覧が開く起動ディレクトリ。空欄ならカレントディレクトリ。\n")
	strings.write_string(&b, fmt.tprintf("rom_dir = %s\n\n", cfg.rom_dir))

	strings.write_string(&b, "# 音量 (0-100)\n")
	strings.write_string(&b, fmt.tprintf("volume = %d\n\n", cfg.volume))

	strings.write_string(&b, "# --- キーボード割当(SDLキー名。SDL_GetKeyFromNameで解釈されます) ---\n")
	for btn in gb_button_order {
		strings.write_string(
			&b,
			fmt.tprintf("key_%s = %s\n", button_key_name(btn), sdl.GetKeyName(cfg.key_map[btn])),
		)
	}
	strings.write_string(&b, "\n")

	strings.write_string(
		&b,
		"# --- コントローラー割当(SDL_GameControllerButton名。SDL_GameControllerGetButtonFromStringで解釈されます) ---\n",
	)
	for btn in gb_button_order {
		strings.write_string(
			&b,
			fmt.tprintf(
				"pad_%s = %s\n",
				button_key_name(btn),
				sdl.GameControllerGetStringForButton(cfg.pad_map[btn]),
			),
		)
	}

	return strings.to_string(b)
}

// --- ファイルI/O ---

// config_dir_path は設定ファイルを置くディレクトリを返す(実行ファイルと同じ場所)。
// os.get_executable_path はプラットフォームごとに実体パス(シンボリックリンク解決済み)を
// 返す実装になっている(macOS: proc_pidpath、Linux: /proc/self/exe の readlink、
// Windows: GetModuleFileNameW)ため、os.args[0] を自前で絶対化・symlink解決するより頑健。
config_dir_path :: proc() -> (dir: string, ok: bool) {
	exe_path, err := os.get_executable_path(context.allocator)
	if err != nil {
		return "", false
	}
	defer delete(exe_path)

	last_slash := strings.last_index(exe_path, "/")
	last_backslash := strings.last_index(exe_path, "\\")
	last_sep := max(last_slash, last_backslash)
	if last_sep < 0 {
		return "", false
	}
	return strings.clone(exe_path[:last_sep]), true
}

// config_path は設定ファイルのフルパスを返す。
config_path :: proc(dir: string) -> string {
	return fmt.tprintf("%s/%s", dir, CONFIG_FILE_NAME)
}

// config_load は path を読み込みデフォルトへマージした Config を返す。
// ファイルが存在しない場合はデフォルト値で新規作成を試みる(書き込み不可の場所では警告して
// デフォルト値のまま続行する。T8-1「落とし穴」)。
config_load :: proc(path: string) -> Config {
	if !os.exists(path) {
		content := config_render_default_ini()
		defer delete(content)
		if err := os.write_entire_file(path, transmute([]u8)content); err != nil {
			fmt.eprintfln("config: 設定ファイルを作成できませんでした(デフォルト値で続行します): %s (%v)", path, err)
		}
		cfg := default_config()
		config_warn_key_conflicts(cfg.key_map)
		return cfg
	}

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("config: 設定ファイルを読み込めませんでした(デフォルト値で続行します): %s (%v)", path, read_err)
		return default_config()
	}
	defer delete(data)

	raw := config_parse_ini(string(data))
	defer delete(raw)

	cfg := config_apply_raw(default_config(), raw)
	config_warn_key_conflicts(cfg.key_map)
	return cfg
}

// config_apply_cli_overrides は CLI で明示的に指定されたフィールドだけを cfg の上に適用する
// (優先順位 CLI > 設定ファイル > デフォルト)。opts.provided に含まれないフィールドは
// 設定ファイル(あるいはデフォルト)の値をそのまま使う。この結果を設定ファイルへ書き戻すことは
// 無い(CLIは一時的な変更、BluePrint準拠)。
config_apply_cli_overrides :: proc(cfg: Config, opts: Options) -> Config {
	result := cfg
	if .Scale in opts.provided {
		result.scale = opts.scale
	}
	if .Fullscreen in opts.provided {
		result.fullscreen = opts.fullscreen
	}
	if .Shader in opts.provided {
		result.shader = opts.shader
	}
	return result
}
