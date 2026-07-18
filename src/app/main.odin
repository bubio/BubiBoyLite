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

	// 設定ファイルの読み込み/自動生成(T8-1)。--headless の早期終了より前に行う必要がある。
	// 検証コマンド(phase-08-frontend.md T8-1)
	// `rm -f ./bbl.ini && ./bbl --headless && cat ./bbl.ini` はヘッドレス起動でも
	// bbl.ini が生成されることを期待しているため。実行ファイルの場所を特定できない場合は
	// 警告してデフォルト値のまま続行する(起動は止めない、T8-1の完了条件)。
	cfg := default_config()
	if dir, dir_ok := config_dir_path(); dir_ok {
		cfg = config_load(config_path(dir))
		delete(dir)
	} else {
		fmt.eprintln("config: 実行ファイルの場所を特定できませんでした(デフォルト値で続行します)")
	}
	// CLI引数は「一時的な変更」として設定ファイルの値を上書きする(書き戻しはしない)。
	cfg = config_apply_cli_overrides(cfg, opts)

	if opts.headless {
		// SDL を一切初期化しない経路。CI やテスト ROM ランナーの前提（architecture.md）。
		fmt.println("headless: nothing to do")
		os.exit(0)
	}

	if opts.rom_path != "" {
		run_rom_window(opts, cfg)
		// T9-3「ROM起動成功のたびに更新」。TUI経由でない直接起動(`bbl rom.gb`)でも
		// run_rom_window がここまで戻ってくれば(=os.exit(1)していなければ)起動成功とみなし、
		// 最近使ったファイル履歴を更新する(TUI側の run_tui と同じ判断基準)。
		if dir, dir_ok := config_dir_path(); dir_ok {
			recent_record_launch(dir, opts.rom_path)
			delete(dir)
		}
		return
	}

	// T9-1: ROM未指定時はTUIを起動する(BluePrint「Claude Codeなどに見られるTUIも提供する」)。
	// 非TTYの場合は run_tui 内で「TUIを起動できません」+ exit 1 になる(以前あった
	// run_test_pattern_window 呼び出しはTUIに置き換わったことで到達不能になったため削除)。
	run_tui(opts, cfg)
}

// run_rom_window は ROM を読み込み実際にエミュレーションを実行しながら SDL2 ウィンドウへ
// 描画するメインループ(T3-6)。Esc またはウィンドウクローズで終了する。
// standalone_terminal: true(デフォルト、`bbl rom.gb` のような直接起動)ならこの関数自身が
// ターミナルのraw mode(T9-5のホットキー用)を有効化/復元する。false(run_tui経由)なら
// 既にTUI側がraw modeを持っている(tui_suspend_for_game済み)ため何もしない
// (T9-2落とし穴と対称: 二重にtcgetattrすると復元用スナップショットが壊れる)。
run_rom_window :: proc(opts: Options, cfg: Config, standalone_terminal := true) {
	rom_data, read_err := os.read_entire_file(opts.rom_path, context.allocator)
	if read_err != nil {
		// T14-4: TUI経由の起動失敗時は alt screen が張られたまま(tui_suspend_for_game が
		// alt screen を抜けなくなった)なので、メッセージ表示と exit の前に必ず復元する
		// (tui_force_restore は未突入なら no-op の冪等関数)。以下の失敗経路も同様。
		tui_force_restore()
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
		tui_force_restore() // T14-4: alt screen 内での exit を避ける(上記コメント参照)
		fmt.eprintfln("ROM のロードに失敗しました: %s (%s)", opts.rom_path, message)
		os.exit(1)
	}
	defer core.bus_destroy(&emu.bus)

	// バッテリーセーブ(.sav)のロード(T4-6)。BluePrint: 保存先はROMと同じ場所がデフォルト、
	// bbl.ini の save_dir で変更可能(T8-4)。
	save_path := save_ram_path_for_rom_with_dir(opts.rom_path, cfg.save_dir)
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
	rtc_path := rtc_path_for_rom_with_dir(opts.rom_path, cfg.save_dir) // .rtcもsave_dirを共有する(T8-4)
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

	video, video_ok := video_init(cfg.scale, cfg.fullscreen, cfg.shader)
	if !video_ok {
		tui_force_restore() // T14-4: alt screen 内での exit を避ける
		os.exit(1)
	}
	defer video_destroy(&video)

	audio: Audio
	if !audio_init(&audio, emu, cfg.volume) {
		tui_force_restore() // T14-4: alt screen 内での exit を避ける
		os.exit(1)
	}
	defer audio_destroy(&audio)

	// T9-5: 直接起動(`bbl rom.gb`)時はここでraw modeを有効化する(TUI経由なら
	// standalone_terminal=falseで既にraw mode済み)。tui_game_terminal_begin と
	// context.assertion_failure_proc の代入は「同じ関数の中で」行う必要がある
	// (tui_enter/tui_game_terminal_begin のコメント参照: 代入は呼び出し元には伝播しない)。
	owns_terminal := false
	standalone_shell := false
	if standalone_terminal {
		owns_terminal, standalone_shell = tui_game_terminal_begin()
		if owns_terminal {
			context.assertion_failure_proc = tui_assertion_failure
		}
	}
	defer if owns_terminal {
		tui_exit()
	}

	// T14-4: 固定レイアウトシェルの有効判定。TUI経由(呼び出し元が alt screen を維持したまま)
	// か、直接起動で stdout も TTY(tui_game_terminal_begin が alt screen へ入った)なら、
	// ゲーム中もホーム画面と同一のシェル画面構成で描画する。どちらでもなければ従来の
	// 1行ステータス表示にフォールバック(非TTYフォールバック無変更の方針)。
	shell_active := !standalone_terminal || standalone_shell

	// T9-4: 実行中ステータス表示。standalone_terminal(直接起動)かTUI経由かに関わらず、
	// stderr が TTY なら表示する(T9-4「TUI経由でない起動でもTTYなら表示」)。
	// T14-3/T14-4: シェル有効時は操作メッセージを Message_Log にも貯め、Now Playing 画面の
	// コンテンツ領域に直近数件を表示する。
	msg_log: Message_Log
	defer message_log_destroy(&msg_log)
	status_line := status_line_init(opts.rom_path, emu.bus.cart.info)
	defer status_line_destroy(&status_line)
	if shell_active {
		status_line.log = &msg_log
	}

	// T9-5: ターミナルからのホットキー読み取り用(非ブロッキング)。raw modeが有効な場合
	// (TUI経由 or owns_terminal)だけ実際に何か読める。無効なら tui_plat_read が常に0を
	// 返すだけで実害は無い(ただし念のため hotkeys_available で読み取り自体をスキップする)。
	hotkeys_available := !standalone_terminal || owns_terminal
	game_kr: Key_Reader
	paused := false
	stop_reported := false

	// T12-5/T13-5: ゲーム中TUIモード。`/` で .Command(Line_Editor によるコマンド入力)、
	// `settings` 確定で .Menu(オーバーレイ設定メニュー)へ遷移する。.Menu はブロッキングループ
	// ではなく menu_step を毎フレーム1ステップ呼ぶ状態機械なので、sdl.PollEvent は止まらない
	// (0a78a66 のウィンドウ幽霊化パターンを構造的に回避)。/set・メニューで変更した値は
	// live_cfg に反映し、以降の処理は live_cfg を参照する(cfg は関数パラメータでアドレスを
	// 取れないため、ここでローカルコピーする)。
	tui_mode: Game_Tui_Mode = .Play
	mode_was_paused := false
	command_editor: Line_Editor
	defer line_editor_destroy(&command_editor)
	command_dirty := false
	menu_state: Menu_State
	defer menu_state_destroy(&menu_state)
	game_last_cols := -1
	game_last_rows := -1
	game_dirty := true // 初回は必ず描画(以降はキー入力・1秒窓満了・サイズ変化で dirty)
	live_cfg := cfg

	config_dir, config_dir_ok := config_dir_path()
	defer if config_dir_ok {
		delete(config_dir)
	}
	if !config_dir_ok {
		config_dir = ""
	}

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

	// ゲームコントローラー(T8-5)。起動時に既に挿さっている1台を開く。未接続でもok
	// (controllers.handleがnilのまま、以降のボタン/軸イベントは単に発生しない)。
	controllers: Controller_Manager
	controller_manager_open_first_available(&controllers)
	defer controller_manager_destroy(&controllers)

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
				if input_is_fullscreen_toggle(event.key) {
					video_toggle_fullscreen(&video)
				}
				input_handle_key_event(emu, cfg.key_map, event.key, true)
				// 落とし穴(T7-4): 保存/復元はメインループのフレーム境界で行う。ここは
				// このイテレーションでまだ emulator_run_frame を呼んでいない時点なので、
				// 直接処理してよい(次のフレーム実行の「外」であることが保証される)。
				action := input_handle_shortcut_key(&input_state, event.key)
				sdl_msg := handle_shortcut_action(action, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
				// T14-4: シェル有効時は SDL 側ショートカット(F1-F4/F5/F9等)の結果も
				// メッセージログ+ステータス行に載せる(stderr 直書きは画面を汚すため抑制)。
				if shell_active && sdl_msg != "" {
					status_line_set_message(&status_line, sdl_msg)
					game_dirty = true
				}
			case .KEYUP:
				input_handle_key_event(emu, cfg.key_map, event.key, false)
			case .CONTROLLERDEVICEADDED:
				controller_manager_handle_added(&controllers, event.cdevice.which)
			case .CONTROLLERDEVICEREMOVED:
				controller_manager_handle_removed(&controllers, sdl.JoystickID(event.cdevice.which))
			case .CONTROLLERBUTTONDOWN:
				input_handle_controller_button_event(emu, cfg.pad_map, event.cbutton, true)
			case .CONTROLLERBUTTONUP:
				input_handle_controller_button_event(emu, cfg.pad_map, event.cbutton, false)
			case .CONTROLLERAXISMOTION:
				input_handle_controller_axis_event(emu, event.caxis)
			}
		}

		if hotkeys_available {
			ev, ok := key_reader_poll(&game_kr)
			if ok {
				switch tui_mode {
				case .Command:
					#partial switch ev.key {
					case .Char, .Backspace:
						line_editor_feed(&command_editor, ev)
						command_dirty = true
					case .Escape:
						line_editor_feed(&command_editor, ev)
						tui_mode = .Play
						game_resume_after_command_mode(&paused, mode_was_paused)
						status_line_set_message(&status_line, "Command cancelled")
						if !shell_active {
							fmt.eprintf("\r\x1b[K") // 入力エコー行をクリア(レガシー1行表示のみ)
						}
					case .Enter:
						submitted, text := line_editor_feed(&command_editor, ev)
						if submitted {
							cmd := parse_game_command(text)
							msg := ""
							exit_to_play := true // .Settings で .Menu へ遷移するときだけ false
							switch cmd.kind {
							case .Empty:
								msg = ""
							case .Settings:
								// T14-4: シェルの設定ビューへ遷移(オーバーレイは撤去)。pause は解除せず
								// mode_was_paused をメニュー終了まで持ち越す(閉じるときに復元)。
								if shell_active {
									tui_mode = .Menu
									menu_state.selected = 0
									exit_to_play = false
								} else {
									msg = "設定メニューを表示できません(端末のシェル表示が無効です)"
								}
							case .Pause:
								paused = true
								// コマンドモード終了時の自動復元(game_resume_after_command_mode)で
								// 即座に resume されてしまわないよう、突入前状態を「一時停止中」に上書きする。
								mode_was_paused = true
								msg = "Paused"
							case .Resume:
								paused = false
								mode_was_paused = false
								msg = "Resumed"
							case .Save_State:
								if cmd.slot > 0 {
									input_state.state_slot = cmd.slot
								}
								msg = handle_shortcut_action(.Save_State, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
							case .Load_State:
								if cmd.slot > 0 {
									input_state.state_slot = cmd.slot
								}
								msg = handle_shortcut_action(.Load_State, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
							case .Select_Slot:
								input_state.state_slot = cmd.slot
								msg = handle_shortcut_action(.Select_Slot, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
							case .Quit:
								running = false
							case .Unknown:
								msg = fmt.tprintf("不明なコマンドです: %s", cmd.raw)
							case .Set:
								set_ok, apply_msg := config_apply_set(&live_cfg, config_dir, cmd.set_key, cmd.set_value)
								if set_ok && cmd.set_key == "volume" {
									audio_set_volume(&audio, live_cfg.volume)
								}
								msg = apply_msg
							}
							delete(text)
							if !shell_active {
								fmt.eprintf("\r\x1b[K") // 入力エコー行をクリア(レガシー1行表示のみ)
							}
							if exit_to_play {
								tui_mode = .Play
								game_resume_after_command_mode(&paused, mode_was_paused)
								status_line_set_message(&status_line, msg)
							}
						}
					}
				case .Menu:
					eff := menu_step(&menu_state, ev, live_cfg)
					switch eff.op {
					case .None, .Redraw:
					// 再描画はキーイベント処理後の一括 dirty 化(下記)で行う
					case .Adjust:
						set_ok, msg := config_apply_set(&live_cfg, config_dir, eff.key, eff.value)
						if set_ok && eff.key == "volume" {
							audio_set_volume(&audio, live_cfg.volume)
						}
						delete(eff.value)
						menu_set_status(&menu_state, msg)
					case .Close:
						// T14-4: シェルは全画面再構築なのでオーバーレイ消去処理は不要。
						menu_state_destroy(&menu_state)
						tui_mode = .Play
						game_resume_after_command_mode(&paused, mode_was_paused)
					}
				case .Play:
					action, slot := game_key_to_action(ev)
					#partial switch action {
					case .Volume_Up:
						v := audio_adjust_volume(&audio, AUDIO_VOLUME_STEP)
						status_line_set_message(&status_line, fmt.tprintf("Volume %d%%", v))
					case .Volume_Down:
						v := audio_adjust_volume(&audio, -AUDIO_VOLUME_STEP)
						status_line_set_message(&status_line, fmt.tprintf("Volume %d%%", v))
					case .Select_Slot:
						input_state.state_slot = slot
						msg := handle_shortcut_action(.Select_Slot, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
						status_line_set_message(&status_line, msg)
					case .Save_State:
						msg := handle_shortcut_action(.Save_State, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
						status_line_set_message(&status_line, msg)
					case .Load_State:
						msg := handle_shortcut_action(.Load_State, emu, &video, &audio, opts.rom_path, cfg.state_dir, &input_state, quiet_terminal = shell_active)
						status_line_set_message(&status_line, msg)
					case .Toggle_Pause:
						paused = !paused
						status_line_set_message(&status_line, paused ? "Paused" : "Resumed")
					case .Enter_Command_Mode:
						tui_mode = .Command
						mode_was_paused = game_pause_for_command_mode(&paused)
						line_editor_reset(&command_editor)
						command_dirty = true
					}
				}
				// T14-4: キーイベントを処理したら常にシェルを再描画する(入力行・選択・メッセージ
				// ログのいずれかが変わった可能性がある。キー押下時のみなのでコストは無視できる)。
				game_dirty = true
			}
		}

		if emu.cpu.stopped && !stop_reported {
			// core側は不正/未実装オペコードをstderrへログ済み(1回のみ、emulator_run_frame
			// がstopped後は呼ばれなくなったため)。ここではユーザーに気付けるようステータス行
			// にも表示する。フレーム実行自体はこれ以降行わない(画面は最後の状態で静止する)。
			status_line_set_message(&status_line, "CPU halted (illegal/unimplemented opcode)")
			stop_reported = true
		}

		underrun_before := audio.underrun_events
		if !paused && !emu.cpu.stopped && audio_buffered_pairs(&audio) < AUDIO_TARGET_BUFFERED_PAIRS {
			audio_run_frame_locked(&audio)
			// 表示は最新フレームのみ(中間フレームの描画スキップは行わない実装だが、
			// バッファが目標未満の間は毎回1フレームずつ生成するため実質最新フレーム表示になる)。
			video_present(&video, emu.bus.ppu.framebuffer[:])
			frames_executed += 1
			status_line_record_frame(&status_line)

			if !status_line.enabled && frames_executed % LOG_INTERVAL_FRAMES == 0 {
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
			sdl.Delay(paused ? 16 : 1)
		}
		underrun_now := audio.underrun_events > underrun_before
		if shell_active {
			// T14-4: ゲーム中もホーム画面と同一の固定レイアウトシェルで描画する。
			// 1秒窓の満了(fps・ステータス行の更新)も dirty 化して反映する。
			// メニュー表示中は paused のため sdl.Delay(16) 経路で約60Hzのポーリングが回り続け、
			// SDLポンプは止まらない(T13-5 と同じ構造)。
			if status_line_update(&status_line, audio.volume, input_state.state_slot, emu.bus.double_speed, paused, underrun_now) {
				game_dirty = true
			}
			view := tui_mode == .Menu ? Game_View.Settings : Game_View.Now_Playing
			input_text := tui_mode == .Command ? line_editor_text(command_editor) : ""
			info := Game_Panel_Info {
				volume       = audio.volume,
				slot         = input_state.state_slot,
				double_speed = emu.bus.double_speed,
				paused       = paused,
			}
			game_shell_draw(view, menu_state, live_cfg, &status_line, info, input_text, &game_last_cols, &game_last_rows, &game_dirty)
		} else {
			// レガシーフォールバック(stdout 非TTY等でシェルを使えない場合): 従来の1行表示。
			#partial switch tui_mode {
			case .Command:
				// T12-5: コマンドモード中は通常のステータス行の代わりに入力中の行をエコーする
				// (入力があった時だけ再描画、status_line_tick の1秒間引きとは独立)。
				if command_dirty {
					fmt.eprintf("\r\x1b[K/%s_", line_editor_text(command_editor))
					command_dirty = false
				}
			case .Play:
				status_line_tick(&status_line, audio.volume, input_state.state_slot, emu.bus.double_speed, paused, underrun_now)
			}
		}
	}

	// T14-4: シェル有効時(alt screen 内)は書いても復元時に消える上に画面を汚すため出さない
	// (アンダーランはプレイ中のステータス行 "⚠ underrun" で既に可視化されている)。
	if audio.underrun_events > 0 && !shell_active {
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

// Game_Tui_Mode は run_rom_window のターミナル側の入出力モード(T13-5)。
// .Play: 1文字ホットキー(game_key_to_action)+ステータス行。
// .Command: `/` で入り Line_Editor でコマンドを組み立てる(エコー行表示)。
// .Menu: オーバーレイ設定メニュー(menu_step を毎フレーム1ステップ。ブロッキングループでは
// ないため sdl.PollEvent が止まらず、SDL ウィンドウの幽霊化(0a78a66)は構造的に起きない)。
Game_Tui_Mode :: enum {
	Play,
	Command,
	Menu,
}

// game_pause_for_command_mode / game_resume_after_command_mode は T12-5 のコマンドモード突入時に
// エミュレーションを自動一時停止させるための小さなヘルパー。paused は run_rom_window 内の
// オーディオ駆動ペーシングを止めるだけの単純な bool であり(audio_run_frame_locked を呼ばず
// sdl.Delay に切り替わる)、他に連動する状態は無い(オーディオコールバック自体は止まらないため、
// 一時停止中もバッファ枯渇によるアンダーランは起こりうる、既存の p キー一時停止と同じ挙動)。
// 呼び出し元がコマンドモードに入る前の一時停止状態を憶えておき、抜けるときにその状態だけを
// 復元する(ユーザーが p で既に一時停止していた場合はコマンドモードを抜けても止まったままにする)。
@(private = "file")
game_pause_for_command_mode :: proc(paused: ^bool) -> (was_paused: bool) {
	was_paused = paused^
	paused^ = true
	return was_paused
}

@(private = "file")
game_resume_after_command_mode :: proc(paused: ^bool, was_paused: bool) {
	if !was_paused {
		paused^ = false
	}
}

// handle_shortcut_action は input_handle_shortcut_key が返した Shortcut_Action を実行する
// (T7-4)。保存/復元は core.Emulator 全体(APUのwave_ram等、オーディオコールバックスレッドが
// 触れない領域とはいえ同じ Apu 構造体内のフィールドではある)を書き換えるため、
// audio_run_frame_locked と同じ SDL_Lock/UnlockAudioDevice でオーディオコールバックスレッドと
// 直列化する(T5-6 落とし穴の踏襲)。
// 戻り値 message は実行結果の説明文(T9-5: ターミナルホットキー経由の呼び出し元が
// status_line_set_message へそのまま渡せるようにするため。SDLショートカット経由の
// 呼び出し元は従来通り show_status 済みなので無視してよい)。.None の時は ""。
handle_shortcut_action :: proc(
	action: Shortcut_Action,
	emu: ^core.Emulator,
	video: ^Video,
	audio: ^Audio,
	rom_path: string,
	state_dir: string,
	input_state: ^Input_State,
	quiet_terminal := false, // T14-4: シェル有効時は stderr への直書きを抑制(ログ経由で表示)
) -> (
	message: string,
) {
	switch action {
	case .None:
		return ""
	case .Select_Slot:
		message = fmt.tprintf("Slot %d selected", input_state.state_slot)
	case .Save_State:
		sdl.LockAudioDevice(audio.device)
		ok := state_save_with_dir(emu, rom_path, input_state.state_slot, state_dir)
		sdl.UnlockAudioDevice(audio.device)
		if ok {
			message = fmt.tprintf("State saved to slot %d", input_state.state_slot)
		} else {
			message = fmt.tprintf("Failed to save state to slot %d", input_state.state_slot)
		}
	case .Load_State:
		sdl.LockAudioDevice(audio.device)
		err, load_ok := state_load_with_dir(emu, rom_path, input_state.state_slot, state_dir)
		sdl.UnlockAudioDevice(audio.device)
		if !load_ok {
			message = fmt.tprintf("No state in slot %d", input_state.state_slot)
		} else if err != .None {
			message = fmt.tprintf(
				"Failed to load slot %d: %s",
				input_state.state_slot,
				state_load_error_message(err),
			)
		} else {
			message = fmt.tprintf("State loaded from slot %d", input_state.state_slot)
		}
	}
	show_status(video, message, quiet_terminal)
	return message
}

// show_status は実行結果を stderr とウィンドウタイトルの両方に表示する(T7-4)。
// T14-4: quiet_terminal=true(固定レイアウトシェル有効時)は stderr への直書きが alt screen の
// 画面を汚すため抑制し、ウィンドウタイトルのみ更新する(ターミナル側はメッセージログが担う)。
show_status :: proc(video: ^Video, message: string, quiet_terminal := false) {
	if !quiet_terminal {
		fmt.eprintln(message)
	}
	video_set_title(video, message)
}

