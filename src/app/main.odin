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

	if opts.headless {
		// SDL を一切初期化しない経路。CI やテスト ROM ランナーの前提（architecture.md）。
		fmt.println("headless: nothing to do")
		os.exit(0)
	}

	if opts.rom_path != "" {
		run_rom_window(opts)
		return
	}

	run_test_pattern_window(opts)
}

// run_rom_window は ROM を読み込み実際にエミュレーションを実行しながら SDL2 ウィンドウへ
// 描画するメインループ(T3-6)。Esc またはウィンドウクローズで終了する。
run_rom_window :: proc(opts: Options) {
	rom_data, read_err := os.read_entire_file(opts.rom_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("ROM を読み込めません: %s (%v)", opts.rom_path, read_err)
		os.exit(1)
	}
	defer delete(rom_data)

	emu: core.Emulator
	if !core.emulator_load_rom(&emu, rom_data) {
		message := core.cartridge_error_message(emu.bus.cart_load_error, emu.bus.cart.info.type_code)
		fmt.eprintfln("ROM のロードに失敗しました: %s (%s)", opts.rom_path, message)
		os.exit(1)
	}

	video, video_ok := video_init(opts.scale, opts.fullscreen, opts.shader)
	if !video_ok {
		os.exit(1)
	}
	defer video_destroy(&video)

	// 暫定ペーシング: 1フレームの所要時間(70224/4194304秒 ≈ 16.74ms)を壁時計で待つ。
	// SDL_Delayの分解能は粗く誤差が蓄積しうるため、SDL_GetPerformanceCounterで基準時刻を
	// 管理し毎フレームの誤差を補正する。VSyncには頼らない(高リフレッシュレートモニタで
	// 実行速度が変わってしまうため)。
	// TODO(フェーズ5): オーディオ駆動のペーシング(SDL2オーディオのバッファ残量に基づく)に
	// 置き換える(architecture.md「タイミングモデル」)。壁時計ベースの本実装はそれまでの暫定。
	frame_seconds := f64(core.CYCLES_PER_FRAME) / f64(core.CPU_HZ)
	perf_freq := f64(sdl.GetPerformanceFrequency())
	next_frame_at := sdl.GetPerformanceCounter()

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
				input_handle_key_event(&emu, event.key, true)
			case .KEYUP:
				input_handle_key_event(&emu, event.key, false)
			}
		}

		core.emulator_run_frame(&emu)
		video_present(&video, emu.bus.ppu.framebuffer[:])

		next_frame_at += u64(frame_seconds * perf_freq)
		now := sdl.GetPerformanceCounter()
		if next_frame_at > now {
			remaining_ms := f64(next_frame_at - now) / perf_freq * 1000.0
			sdl.Delay(u32(remaining_ms))
		} else {
			// 大幅に遅延している場合は基準時刻を現在時刻へ再同期する(遅延の際限ない蓄積を防ぐ)。
			next_frame_at = now
		}
	}
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
