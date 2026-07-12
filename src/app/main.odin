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

	// T6-3: WRAM 8バンク化でEmulator構造体が大きくなりスタック確保が危険域(コンパイラ警告)に
	// なったため、ヒープ確保に切り替える(値ではなくポインタとして扱う。以下emuは^Emulator)。
	emu := new(core.Emulator)
	defer free(emu)
	if !core.emulator_load_rom(emu, rom_data) {
		message := core.cartridge_error_message(emu.bus.cart_load_error, emu.bus.cart.info.type_code)
		fmt.eprintfln("ROM のロードに失敗しました: %s (%s)", opts.rom_path, message)
		os.exit(1)
	}
	defer core.bus_destroy(&emu.bus)

	// バッテリーセーブ(.sav)のロード(T4-6)。BluePrint: 保存先はROMと同じ場所がデフォルト。
	save_path := save_ram_path_for_rom(opts.rom_path)
	if save_data, load_ok := save_ram_load(save_path); load_ok {
		defer delete(save_data)
		if !core.mbc_import_ram(&emu.bus.cart, save_data) {
			fmt.eprintfln(
				"セーブデータのサイズがカートリッジと一致しないためロードしませんでした: %s",
				save_path,
			)
		}
	}

	// MBC3 RTC の永続化(.rtc、T7-3)。保存されていた基準UNIX時刻から現在時刻までの経過秒を
	// core.emulator_set_wall_clock 経由でRTCへ反映する(mbc3_advance_rtcの停止ビット/桁あふれ
	// 処理をそのまま再利用する。落とし穴: 停止ビット(DH bit6)が立っていれば加算されない)。
	// .rtc が無い(初回起動)場合や RTC非搭載カートリッジでも emulator_set_wall_clock 自体は
	// 無害(mbc_sync_wall_clock 内で has_rtc ガードされる)なので、常に一度呼んで基準点を打つ。
	rtc_path := rtc_path_for_rom(opts.rom_path)
	if rtc_snapshot, rtc_load_ok := rtc_load(rtc_path); rtc_load_ok {
		core.mbc_import_rtc(
			&emu.bus.cart,
			rtc_snapshot.rtc,
			rtc_snapshot.latched_rtc,
			rtc_snapshot.latch_prepared,
			rtc_snapshot.rtc_base_unix,
		)
	}
	core.emulator_set_wall_clock(emu, wall_clock_now())

	video, video_ok := video_init(opts.scale, opts.fullscreen, opts.shader)
	if !video_ok {
		os.exit(1)
	}
	defer video_destroy(&video)

	audio: Audio
	if !audio_init(&audio, emu) {
		os.exit(1)
	}
	defer audio_destroy(&audio)

	// オーディオ駆動ペーシング(T5-6、T3-6の壁時計ペーシングを置換): オーディオバッファ残量が
	// 目標(3フレーム分)を下回っている間だけ emulator_run_frame を回し、満杯なら1ms待つ
	// (BubiBoy RuntimePacing.fs の方式、architecture.md「タイミングモデル」)。
	// 音声消費速度(48kHz)がそのまま実行速度を決めるため、映像60fpsと音声のドリフトが
	// 構造的に発生しない。

	// バッテリーセーブの保存タイミング(T4-6): RAM書き込みから約1秒相当(60フレーム分)
	// 書き込みが無かったら保存する。emu.bus.cart.ram_dirty はRAMへの実書き込みでのみ
	// core側が立てる(mbc.odin)ので、毎フレーム消費(false化)して次の書き込みを検出できるようにする。
	// オーディオ駆動ペーシングでは実行フレーム数と壁時計秒数の対応が厳密ではなくなるが、
	// 平均的には48kHz消費に合わせて約60fps相当で回るためヒューリスティックとして妥当。
	SAVE_IDLE_FRAMES :: 60
	save_pending := false
	save_idle_frames := 0

	// 定期診断ログ(T5-6): アンダーラン数はプレイ中に確認できないと意味がないため、
	// 終了時だけでなく約5秒(300フレーム相当)ごとにも累積値をログする。
	LOG_INTERVAL_FRAMES :: 300
	frames_executed := 0

	// セーブステートショートカット(T7-4)のスロット状態。F1-F4でここのstate_slotが変わる。
	input_state := input_state_default()

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
				input_handle_key_event(emu, event.key, true)
				// 落とし穴(T7-4): 保存/復元はメインループのフレーム境界で行う。ここは
				// このイテレーションでまだ emulator_run_frame を呼んでいない時点なので、
				// 直接処理してよい(次のフレーム実行の「外」であることが保証される)。
				action := input_handle_shortcut_key(&input_state, event.key)
				handle_shortcut_action(action, emu, &video, &audio, opts.rom_path, &input_state)
			case .KEYUP:
				input_handle_key_event(emu, event.key, false)
			}
		}

		if audio_buffered_pairs(&audio) < AUDIO_TARGET_BUFFERED_PAIRS {
			audio_run_frame_locked(&audio)
			// 表示は最新フレームのみ(中間フレームの描画スキップは行わない実装だが、
			// バッファが目標未満の間は毎回1フレームずつ生成するため実質最新フレーム表示になる)。
			video_present(&video, emu.bus.ppu.framebuffer[:])
			frames_executed += 1

			if frames_executed % LOG_INTERVAL_FRAMES == 0 {
				fmt.eprintfln(
					"audio: frames=%d buffered=%d underrun_events=%d underrun_samples=%d",
					frames_executed,
					audio_buffered_pairs(&audio),
					audio.underrun_events,
					audio.underrun_samples,
				)
			}

			if emu.bus.cart.ram_dirty {
				save_pending = true
				save_idle_frames = 0
				emu.bus.cart.ram_dirty = false // 消費して次の書き込みを検出できるようにする
			} else if save_pending {
				save_idle_frames += 1
				if save_idle_frames >= SAVE_IDLE_FRAMES {
					save_ram_now(emu, save_path)
					save_rtc_now(emu, rtc_path) // .savと同タイミングで.rtcも保存する(T7-3)
					save_pending = false
					save_idle_frames = 0
				}
			}
		} else {
			sdl.Delay(1)
		}
	}

	if audio.underrun_events > 0 {
		fmt.eprintfln(
			"audio: アンダーラン %d 回(無音で埋めたサンプル数 %d)",
			audio.underrun_events,
			audio.underrun_samples,
		)
	}

	// 終了時セーブ(T4-6)。バッテリー無し/外部RAM無しカートリッジでは save_ram_now が
	// 何もせず戻る(core.mbc_export_ram の ok=false)。
	save_ram_now(emu, save_path)
	save_rtc_now(emu, rtc_path)
}

// save_ram_now はカートリッジの外部RAMをエクスポートし、.sav へアトミック書き込みする。
save_ram_now :: proc(emu: ^core.Emulator, save_path: string) {
	data, ok := core.mbc_export_ram(&emu.bus.cart)
	if !ok {
		return
	}
	defer delete(data)
	if !save_ram_write_atomic(save_path, data) {
		fmt.eprintfln("セーブの書き込みに失敗しました: %s", save_path)
	}
}

// save_rtc_now は現在の壁時計をRTCへ反映してから(このセッション中に経過した実時間を
// 取り込む)、MBC3のRTC状態を .rtc へアトミック書き込みする(T7-3)。RTC非搭載カートリッジ
// では core.mbc_export_rtc が ok=false を返すので何もしない。
save_rtc_now :: proc(emu: ^core.Emulator, rtc_path: string) {
	core.emulator_set_wall_clock(emu, wall_clock_now())
	rtc, latched_rtc, latch_prepared, rtc_base_unix, ok := core.mbc_export_rtc(&emu.bus.cart)
	if !ok {
		return
	}
	snapshot := Rtc_Snapshot {
		rtc            = rtc,
		latched_rtc    = latched_rtc,
		latch_prepared = latch_prepared,
		rtc_base_unix  = rtc_base_unix,
	}
	if !rtc_save(rtc_path, snapshot) {
		fmt.eprintfln("RTCの書き込みに失敗しました: %s", rtc_path)
	}
}

// handle_shortcut_action は input_handle_shortcut_key が返した Shortcut_Action を実行する
// (T7-4)。保存/復元は core.Emulator 全体(APUのwave_ram等、オーディオコールバックスレッドが
// 触れない領域とはいえ同じ Apu 構造体内のフィールドではある)を書き換えるため、
// audio_run_frame_locked と同じ SDL_Lock/UnlockAudioDevice でオーディオコールバックスレッドと
// 直列化する(T5-6 落とし穴の踏襲)。
handle_shortcut_action :: proc(
	action: Shortcut_Action,
	emu: ^core.Emulator,
	video: ^Video,
	audio: ^Audio,
	rom_path: string,
	input_state: ^Input_State,
) {
	switch action {
	case .None:
	case .Select_Slot:
		show_status(video, fmt.tprintf("Slot %d selected", input_state.state_slot))
	case .Save_State:
		sdl.LockAudioDevice(audio.device)
		ok := state_save(emu, rom_path, input_state.state_slot)
		sdl.UnlockAudioDevice(audio.device)
		if ok {
			show_status(video, fmt.tprintf("State saved to slot %d", input_state.state_slot))
		} else {
			show_status(video, fmt.tprintf("Failed to save state to slot %d", input_state.state_slot))
		}
	case .Load_State:
		sdl.LockAudioDevice(audio.device)
		err, load_ok := state_load(emu, rom_path, input_state.state_slot)
		sdl.UnlockAudioDevice(audio.device)
		if !load_ok {
			show_status(video, fmt.tprintf("No state in slot %d", input_state.state_slot))
		} else if err != .None {
			show_status(
				video,
				fmt.tprintf("Failed to load slot %d: %s", input_state.state_slot, state_load_error_message(err)),
			)
		} else {
			show_status(video, fmt.tprintf("State loaded from slot %d", input_state.state_slot))
		}
	}
}

// show_status は実行結果を stderr とウィンドウタイトルの両方に表示する(T7-4)。
show_status :: proc(video: ^Video, message: string) {
	fmt.eprintln(message)
	video_set_title(video, message)
}

// run_test_pattern_window は ROM 未指定 & TUI 未実装の間、テストパターンを表示する
// イベントループ。Esc またはウィンドウクローズで終了する。
run_test_pattern_window :: proc(opts: Options) {
	video, video_ok := video_init(opts.scale, opts.fullscreen, opts.shader)
	if !video_ok {
		os.exit(1)
	}
	defer video_destroy(&video)

	emu := new(core.Emulator) // T6-3: run_rom_window と同じ理由でヒープ確保(スタックオーバーフロー警告回避)
	defer free(emu)
	core.emulator_render_test_pattern(emu)

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
