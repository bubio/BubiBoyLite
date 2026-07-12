package main

import "core:fmt"
import core "bbl:core"
import sdl "vendor:sdl2"

// video.odin: SDL2ウィンドウ/レンダラー(T3-6)、フルスクリーン(T8-2)。

Video :: struct {
	window:            ^sdl.Window,
	renderer:          ^sdl.Renderer,
	texture:           ^sdl.Texture, // 160x144のフレームバッファテクスチャ
	shader:            Shader_Kind,
	fullscreen:        bool,
	last_logged_scale: int, // T8-2 DoD: 算出倍率をログ出力するための直近値(変化時のみログ)
}

video_init :: proc(scale: int, fullscreen: bool, shader: Shader_Kind) -> (video: Video, ok: bool) {
	if sdl.Init(sdl.INIT_VIDEO) != 0 {
		fmt.eprintfln("SDL_Init に失敗しました: %s", sdl.GetError())
		return video, false
	}

	if shader == .Nearest {
		sdl.SetHint(sdl.HINT_RENDER_SCALE_QUALITY, "0")
	} else {
		sdl.SetHint(sdl.HINT_RENDER_SCALE_QUALITY, "1")
	}

	window_flags: sdl.WindowFlags = sdl.WINDOW_SHOWN | sdl.WINDOW_RESIZABLE
	if fullscreen {
		window_flags |= sdl.WINDOW_FULLSCREEN_DESKTOP
	}

	w := i32(core.SCREEN_WIDTH * scale)
	h := i32(core.SCREEN_HEIGHT * scale)

	window := sdl.CreateWindow(
		"BubiBoyLite",
		sdl.WINDOWPOS_CENTERED,
		sdl.WINDOWPOS_CENTERED,
		w,
		h,
		window_flags,
	)
	if window == nil {
		fmt.eprintfln("SDL_CreateWindow に失敗しました: %s", sdl.GetError())
		sdl.Quit()
		return video, false
	}

	renderer := sdl.CreateRenderer(window, -1, sdl.RENDERER_ACCELERATED)
	if renderer == nil {
		fmt.eprintfln("SDL_CreateRenderer に失敗しました: %s", sdl.GetError())
		sdl.DestroyWindow(window)
		sdl.Quit()
		return video, false
	}
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255) // レターボックスの余白色(黒、T8-2)

	texture := sdl.CreateTexture(
		renderer,
		.ARGB8888,
		.STREAMING,
		i32(core.SCREEN_WIDTH),
		i32(core.SCREEN_HEIGHT),
	)
	if texture == nil {
		fmt.eprintfln("SDL_CreateTexture に失敗しました: %s", sdl.GetError())
		sdl.DestroyRenderer(renderer)
		sdl.DestroyWindow(window)
		sdl.Quit()
		return video, false
	}

	video.window = window
	video.renderer = renderer
	video.texture = texture
	video.shader = shader
	video.fullscreen = fullscreen
	video.last_logged_scale = 0
	return video, true
}

// video_compute_layout は出力サイズ(ウィンドウ/フルスクリーンのピクセルサイズ)から、
// GBの160x144を割り切れる最大の整数倍率と、その内容を中央寄せするための描画先矩形を返す。
// 余白はレターボックス(呼び出し側が黒でRenderClearする前提)。
// 整数倍率が1未満になる異常系(出力が160x144より小さい)は1に丸める(クラッシュ回避、
// 表示は多少はみ出るが実運用では起こらない想定)。
// 純粋関数(SDL初期化非依存)なのでテスト可能(T8-2 DoDの「算出倍率」の検証に使う)。
video_compute_layout :: proc(output_w, output_h: int) -> (rect: sdl.Rect, scale: int) {
	scale_w := output_w / core.SCREEN_WIDTH
	scale_h := output_h / core.SCREEN_HEIGHT
	scale = min(scale_w, scale_h)
	if scale < 1 {
		scale = 1
	}

	content_w := core.SCREEN_WIDTH * scale
	content_h := core.SCREEN_HEIGHT * scale
	x := (output_w - content_w) / 2
	y := (output_h - content_h) / 2

	rect = sdl.Rect{i32(x), i32(y), i32(content_w), i32(content_h)}
	return rect, scale
}

// video_present は1フレーム分のフレームバッファを、算出した整数倍矩形へ描画する
// (T8-2: はみ出た余白は黒でレターボックス)。
video_present :: proc(video: ^Video, framebuffer: []u32) {
	pitch := i32(core.SCREEN_WIDTH * size_of(u32))
	sdl.UpdateTexture(video.texture, nil, raw_data(framebuffer), pitch)

	out_w, out_h: i32
	sdl.GetRendererOutputSize(video.renderer, &out_w, &out_h)
	dst_rect, scale := video_compute_layout(int(out_w), int(out_h))

	if scale != video.last_logged_scale {
		fmt.eprintfln("video: 表示倍率 = %d (出力サイズ %dx%d)", scale, out_w, out_h)
		video.last_logged_scale = scale
	}

	sdl.RenderClear(video.renderer) // 黒でクリアしてからレターボックス領域外に描画しない(T8-2)
	sdl.RenderCopy(video.renderer, video.texture, nil, &dst_rect)
	sdl.RenderPresent(video.renderer)
}

// video_toggle_fullscreen はフルスクリーン/ウィンドウ表示をトグルする(T8-2、Alt+Enter /
// macOSはCmd+Enterでも呼ばれる。main.odinのキーイベント処理から呼ぶ)。
// SDL_SetWindowFullscreenが失敗した場合は video.fullscreen を変更前の値に戻す。
video_toggle_fullscreen :: proc(video: ^Video) -> bool {
	new_fullscreen := !video.fullscreen
	flags: sdl.WindowFlags = new_fullscreen ? sdl.WINDOW_FULLSCREEN_DESKTOP : {}
	if sdl.SetWindowFullscreen(video.window, flags) != 0 {
		fmt.eprintfln("video: フルスクリーン切替に失敗しました: %s", sdl.GetError())
		return false
	}
	video.fullscreen = new_fullscreen
	return true
}

// video_set_title はウィンドウタイトルを更新する(T7-4: セーブステート操作の結果表示)。
video_set_title :: proc(video: ^Video, title: string) {
	sdl.SetWindowTitle(video.window, fmt.ctprintf("%s", title))
}

video_destroy :: proc(video: ^Video) {
	sdl.DestroyTexture(video.texture)
	sdl.DestroyRenderer(video.renderer)
	sdl.DestroyWindow(video.window)
	sdl.Quit()
}
