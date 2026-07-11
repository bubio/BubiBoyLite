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

Options :: struct {
	scale:      int,
	fullscreen: bool,
	shader:     Shader_Kind,
	recent:     bool,
	headless:   bool,
	rom_path:   string,
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

		case "--fullscreen":
			opts.fullscreen = true

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
