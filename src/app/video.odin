package main

import "core:fmt"
import core "bbl:core"
import sdl "vendor:sdl2"

// video.odin: SDL2ウィンドウ/レンダラー(T3-6)、フルスクリーン(T8-2)、smoothシェーダー(T8-3)。

// INTERMEDIATE_SCALE は smooth シェーダーの「いったんnearestで整数倍する」段階の倍率
// (T8-3「2倍以上」)。最終的な表示倍率(video_compute_layoutが返すscale)へは、この中間
// テクスチャからlinearで引き伸ばす。中間段階を固定倍率にすることで、最終倍率が中間倍率の
// 整数倍にならない限り必ずlinear補間が効き、nearestとの見た目の差が出る。
INTERMEDIATE_SCALE :: 2

Video :: struct {
	window:            ^sdl.Window,
	renderer:          ^sdl.Renderer,
	texture:           ^sdl.Texture, // 160x144のフレームバッファテクスチャ(常にnearest)
	intermediate:      ^sdl.Texture, // smooth用の中間テクスチャ(TEXTUREACCESS_TARGET、遅延生成)
	shader:            Shader_Kind,
	fullscreen:        bool,
	last_logged_scale: int, // T8-2 DoD: 算出倍率をログ出力するための直近値(変化時のみログ)
}

video_init :: proc(scale: int, fullscreen: bool, shader: Shader_Kind) -> (video: Video, ok: bool) {
	// INIT_GAMECONTROLLER はここでまとめて初期化する(T8-5)。GameControllerは
	// INIT_JOYSTICKを内包するため個別に指定する必要は無い。
	if sdl.Init(sdl.INIT_VIDEO | sdl.INIT_GAMECONTROLLER) != 0 {
		fmt.eprintfln("SDL_Init に失敗しました: %s", sdl.GetError())
		return video, false
	}

	// nearest/smooth いずれもテクスチャ単位(SetTextureScaleMode)で制御するが、ヒントは
	// テクスチャ生成時にも参照されるため、streamingテクスチャ生成前に既定値を設定しておく。
	sdl.SetHint(sdl.HINT_RENDER_SCALE_QUALITY, "0")

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
	sdl.SetTextureScaleMode(texture, .Nearest) // このテクスチャ自体は常にnearest(中間テクスチャ経由でsmooth化する)

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

// video_ensure_intermediate は smooth シェーダー用の中間テクスチャを(無ければ)生成する。
// TEXTUREACCESS_TARGET で SetRenderTarget の描画先にできるようにする(T8-3)。
@(private = "file")
video_ensure_intermediate :: proc(video: ^Video) -> bool {
	if video.intermediate != nil {
		return true
	}
	tex := sdl.CreateTexture(
		video.renderer,
		.ARGB8888,
		.TARGET,
		i32(core.SCREEN_WIDTH * INTERMEDIATE_SCALE),
		i32(core.SCREEN_HEIGHT * INTERMEDIATE_SCALE),
	)
	if tex == nil {
		fmt.eprintfln("video: smooth用の中間テクスチャ生成に失敗しました: %s", sdl.GetError())
		return false
	}
	sdl.SetTextureScaleMode(tex, .Linear) // 中間テクスチャ→最終出力の段階でlinear補間する
	video.intermediate = tex
	return true
}

// video_present は1フレーム分のフレームバッファを描画する。
// nearest: フレームバッファテクスチャを直接、算出した整数倍矩形へnearestで描く。
// smooth: いったんINTERMEDIATE_SCALE倍にnearestで拡大した中間テクスチャを作り、
//   それを最終矩形へlinearで描く(sharp-bilinear、T8-3)。
//   落とし穴: SetRenderTargetを中間テクスチャに切り替えたら、必ず nil (バックバッファ) へ
//   戻してから最終描画とRenderPresentを行うこと(戻し忘れるとその後の描画が全部中間
//   テクスチャに乗ってしまい画面が更新されなくなる)。
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

	use_smooth := video.shader == .Smooth && scale >= INTERMEDIATE_SCALE
	if use_smooth && video_ensure_intermediate(video) {
		sdl.SetRenderTarget(video.renderer, video.intermediate)
		sdl.RenderCopy(video.renderer, video.texture, nil, nil) // 160x144 -> 320x288 相当、nearest
		sdl.SetRenderTarget(video.renderer, nil) // 戻し忘れ厳禁(落とし穴)

		sdl.RenderCopy(video.renderer, video.intermediate, nil, &dst_rect) // 中間 -> 最終矩形、linear
	} else {
		// nearestモード、またはsmoothだが最終倍率がINTERMEDIATE_SCALE未満(拡大の余地が無い)
		// ためフォールバックする経路。
		sdl.RenderCopy(video.renderer, video.texture, nil, &dst_rect)
	}

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

// 落とし穴(実機検証で発見、T9-6): HomebrewのSDL2は実体がsdl2-compat(SDL2 APIをSDL3上に
// 実装する互換シム)であり、libSDL3.0.dylibも同時にロードされる(otool -Lで確認)。
// SDL_HideWindow等でウィンドウを隠さずいきなりDestroyWindow+Quitすると、Cocoa側が
// ウィンドウの消去処理をイベントループに1周も回さないまま終了し、画面上にウィンドウの
// 見た目だけが「幽霊」として残ってマウスカーソルが回り続ける不具合を実機で確認した
// (アプリ自体はSDL_Quit後も正常にTUIへ戻り応答していたため、アプリ側のイベントループの
// 停止ではなくWindowServer側の後片付け不足と判明)。HideWindow → PumpEvents で
// Cocoaに消去処理を1周させてからDestroy/Quitする。
video_destroy :: proc(video: ^Video) {
	sdl.HideWindow(video.window)
	sdl.PumpEvents()

	if video.intermediate != nil {
		sdl.DestroyTexture(video.intermediate)
	}
	sdl.DestroyTexture(video.texture)
	sdl.DestroyRenderer(video.renderer)
	sdl.DestroyWindow(video.window)
	sdl.PumpEvents()
	sdl.Quit()
}
