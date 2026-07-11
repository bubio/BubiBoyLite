package main

import "core:fmt"
import "core:os"

main :: proc() {
	args := os.args[1:]

	for arg in args {
		if arg == "-h" || arg == "--help" {
			print_usage()
			os.exit(0)
		}
		if arg == "-v" || arg == "--version" {
			print_version()
			os.exit(0)
		}
	}

	opts, err, ok := parse_args(args)
	if !ok {
		fmt.eprintln(err)
		os.exit(1)
	}

	// TODO(T0-5/T0-6): video/headless の実処理に置き換える。今は解析結果の確認用。
	fmt.printfln(
		"BubiBoyLite: scale=%d fullscreen=%v shader=%v recent=%v headless=%v rom=%q",
		opts.scale,
		opts.fullscreen,
		opts.shader,
		opts.recent,
		opts.headless,
		opts.rom_path,
	)
}
