package main

// SDL2 オーディオ出力とオーディオ駆動ペーシング(T5-6)。
// T3-6 で入れた壁時計ペーシング(SDL_Delay(16.74ms))を置き換える本エミュレータの速度制御の
// 本体(architecture.md「タイミングモデル」)。core 側は SDL2 に一切依存しない
// (apu.odin は純粋計算のみ)ので、SDL2 依存はこのファイルに閉じる。

import "base:runtime"
import "core:c"
import "core:fmt"
import core "bbl:core"
import sdl "vendor:sdl2"

AUDIO_FREQ :: 48000
AUDIO_CHANNELS :: 2
AUDIO_SAMPLES :: 1024 // AudioSpec.samples はサンプル"フレーム"数(チャンネル数で割った値)

// 「3フレーム分」の目標バッファ残量(ステレオペア数)。1フレーム≈803.6ペア(70224/4194304*48000)
// なので概ね2400ペア前後(phase-05-apu.md T5-6の例値)。
AUDIO_TARGET_BUFFERED_PAIRS :: 3 * 803

Audio :: struct {
	device:           sdl.AudioDeviceID,
	emu:              ^core.Emulator, // コールバックが apu_drain_samples を呼ぶために保持(borrow)
	underrun_events:  u64, // コールバックが要求分を満たせなかった回数(診断ログ用)
	underrun_samples: u64, // 無音で埋めた i16 要素の累計
}

// audio_callback は SDL のオーディオスレッドから呼ばれる(architecture.md: SDL2依存はapp側)。
// "c" 呼び出し規約が必須(AudioCallbackの型)。apu_drain_samples で埋まらなかった分は無音(0)で
// 埋め、アンダーランを記録する(T5-6落とし穴: ここでのメモリ競合はSDL_Lock/UnlockAudioDeviceで
// main側と直列化する前提。詳細はrun_rom_windowのコメント参照)。
audio_callback :: proc "c" (userdata: rawptr, stream: [^]u8, len: c.int) {
	context = runtime.default_context()
	audio := cast(^Audio)userdata
	n_i16 := int(len) / 2 // S16 = 2byte/サンプル
	dst := (cast([^]i16)stream)[:n_i16]

	got := core.apu_drain_samples(&audio.emu.bus.apu, dst)
	if got < n_i16 {
		for i in got ..< n_i16 {
			dst[i] = 0
		}
		audio.underrun_events += 1
		audio.underrun_samples += u64(n_i16 - got)
	}
}

// audio_init は SDL_OpenAudioDevice を 48000Hz/AUDIO_S16SYS/2ch/samples=1024 で開く。
// audio は呼び出し側が確保した安定アドレスを渡すこと(SDLのuserdataとして長期間保持される
// ため、戻り値を値渡しするAPIにはできない。video_initとの違いはここ)。
audio_init :: proc(audio: ^Audio, emu: ^core.Emulator) -> bool {
	audio.emu = emu

	if sdl.InitSubSystem(sdl.INIT_AUDIO) != 0 {
		fmt.eprintfln("SDL_InitSubSystem(AUDIO) に失敗しました: %s", sdl.GetError())
		return false
	}

	want: sdl.AudioSpec
	want.freq = AUDIO_FREQ
	want.format = sdl.AUDIO_S16SYS
	want.channels = AUDIO_CHANNELS
	want.samples = AUDIO_SAMPLES
	want.callback = audio_callback
	want.userdata = audio

	obtained: sdl.AudioSpec
	dev := sdl.OpenAudioDevice(nil, false, &want, &obtained, {})
	if dev == 0 {
		fmt.eprintfln("SDL_OpenAudioDevice に失敗しました: %s", sdl.GetError())
		return false
	}
	audio.device = dev
	sdl.PauseAudioDevice(dev, false) // 再生開始
	return true
}

audio_destroy :: proc(audio: ^Audio) {
	sdl.CloseAudioDevice(audio.device)
	sdl.QuitSubSystem(sdl.INIT_AUDIO)
}

// audio_buffered_pairs は現在リングバッファに溜まっているステレオペア数を返す
// (メインループのペーシング判断に使う)。オーディオコールバックスレッドとの競合を避けるため
// SDL_Lock/UnlockAudioDeviceで保護する(T5-6落とし穴)。
audio_buffered_pairs :: proc(audio: ^Audio) -> int {
	sdl.LockAudioDevice(audio.device)
	n := audio.emu.bus.apu.ring_count
	sdl.UnlockAudioDevice(audio.device)
	return n
}

// audio_run_frame_locked は emulator_run_frame を SDL_Lock/UnlockAudioDevice で挟んで実行する。
// emulator_run_frame は内部で apu_tick を呼びリングバッファに書き込むため、オーディオ
// コールバックスレッドの apu_drain_samples と同時に走るとデータ競合になる
// (T5-6落とし穴: SPSCリングでなく単純なcount管理のため、ロックでの直列化が必須)。
audio_run_frame_locked :: proc(audio: ^Audio) {
	sdl.LockAudioDevice(audio.device)
	core.emulator_run_frame(audio.emu)
	sdl.UnlockAudioDevice(audio.device)
}
