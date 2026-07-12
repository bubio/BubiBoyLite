package main

import "core:fmt"
import core "bbl:core"
import sdl "vendor:sdl2"

Video :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	texture:  ^sdl.Texture,
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

	window_flags: sdl.WindowFlags = sdl.WINDOW_SHOWN
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
	return video, true
}

video_present :: proc(video: ^Video, framebuffer: []u32) {
	pitch := i32(core.SCREEN_WIDTH * size_of(u32))
	sdl.UpdateTexture(video.texture, nil, raw_data(framebuffer), pitch)
	sdl.RenderClear(video.renderer)
	sdl.RenderCopy(video.renderer, video.texture, nil, nil)
	sdl.RenderPresent(video.renderer)
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
