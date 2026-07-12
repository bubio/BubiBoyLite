package main

import "core:fmt"
import "core:strconv"

USAGE :: `使用法: bbl [options] game.gbc

  -h, --help        コマンドラインの使い方を表示
  -v, --version     バージョンを表示
  --scale N         表示倍率 (1-8、9以上は8に丸める、デフォルト 4)
  --fullscreen      フルスクリーン表示 (--scale は無視される)
  --shader KIND     シェーダー: nearest, smooth (デフォルト nearest)
  --recent          最近使ったファイルを表示して選択

キーボードショートカット(ROM実行中):
  矢印キー          十字キー
  Z / X             B / A
  Enter             Start
  右Shift           Select
  F1-F4             セーブステートのスロット選択 (1-4、デフォルト 1)
  F5                現在のスロットへセーブステートを保存
  F7                現在のスロットからセーブステートを復元
  Esc               終了
`

print_usage :: proc() {
	fmt.print(USAGE)
}

print_version :: proc() {
	fmt.printfln("bbl %s", VERSION)
}

Shader_Kind :: enum {
	Nearest,
	Smooth,
}

// Option_Field は「CLIで明示的に指定されたか」を表すフラグ(T8-1)。
// 優先順位 CLI > 設定ファイル > デフォルト を実現するには、「指定されなかった」ことを
// 区別できる必要がある(scale はデフォルト値自体が有効な値なので、フィールドの値だけでは
// 「明示指定 か デフォルトのまま か」を判別できない)。parse_args の戻り値のタプル形状
// (opts, err, ok)は cli_test.odin が分解構造で依存しているため変更せず、Options 構造体に
// bit_set を追加する形で表現する。
Option_Field :: enum {
	Scale,
	Fullscreen,
	Shader,
}

Options :: struct {
	scale:      int,
	fullscreen: bool,
	shader:     Shader_Kind,
	recent:     bool,
	headless:   bool,
	rom_path:   string,
	provided:   bit_set[Option_Field], // CLIで明示的に指定されたフィールド(config.odinのマージで使用)
}

DEFAULT_SCALE :: 4
MAX_SCALE :: 8

default_options :: proc() -> Options {
	return Options{scale = DEFAULT_SCALE, fullscreen = false, shader = .Nearest, recent = false, headless = false, rom_path = ""}
}

// parse_args は os.args に依存しない純関数。単体テスト可能にするため main からは
// args[1:] を渡す想定。ok == false のとき err にエラーメッセージが入る。
parse_args :: proc(args: []string) -> (opts: Options, err: string, ok: bool) {
	opts = default_options()

	i := 0
	for i < len(args) {
		arg := args[i]

		switch arg {
		case "--scale":
			i += 1
			if i >= len(args) {
				return opts, "--scale には値が必要です", false
			}
			n, parse_ok := strconv.parse_int(args[i])
			if !parse_ok {
				return opts, fmt.tprintf("--scale の値が不正です: %s", args[i]), false
			}
			if n <= 0 {
				return opts, fmt.tprintf("--scale は 1 以上を指定してください: %d", n), false
			}
			if n > MAX_SCALE {
				n = MAX_SCALE
			}
			opts.scale = n
			opts.provided += {.Scale}

		case "--fullscreen":
			opts.fullscreen = true
			opts.provided += {.Fullscreen}

		case "--shader":
			i += 1
			if i >= len(args) {
				return opts, "--shader には値が必要です", false
			}
			switch args[i] {
			case "nearest":
				opts.shader = .Nearest
			case "smooth":
				opts.shader = .Smooth
			case:
				return opts, fmt.tprintf("--shader の値が不正です: %s (nearest または smooth)", args[i]), false
			}
			opts.provided += {.Shader}

		case "--recent":
			opts.recent = true

		case "--headless":
			opts.headless = true

		case:
			if len(arg) > 0 && arg[0] == '-' {
				return opts, fmt.tprintf("不明なオプションです: %s", arg), false
			}
			if opts.rom_path != "" {
				return opts, "ROM ファイルは 1 個だけ指定できます", false
			}
			opts.rom_path = arg
		}

		i += 1
	}

	return opts, "", true
}
