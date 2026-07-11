package main

import "core:fmt"
import "core:os"
import core "bbl:core"
import sdl "vendor:sdl2"

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

	run_test_pattern_window(opts)
}

// run_test_pattern_window は ROM 未指定 & TUI 未実装の間、テストパターンを表示する
// イベントループ。Esc またはウィンドウクローズで終了する。
run_test_pattern_window :: proc(opts: Options) {
	video, video_ok := video_init(opts.scale, opts.fullscreen, opts.shader)
	if !video_ok {
		os.exit(1)
	}
	defer video_destroy(&video)

	emu: core.Emulator
	core.emulator_render_test_pattern(&emu)

	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEYDOWN:
				if event.key.keysym.sym == .ESCAPE {
					running = false
				}
			}
		}

		video_present(&video, emu.framebuffer[:])
		sdl.Delay(16)
	}
}
