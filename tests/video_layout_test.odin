package tests

import "core:testing"
import app "bbl:app"

// src/app/video.odin の video_compute_layout の単体テスト(T8-2)。
// 「倍率 = min(display_w/160, display_h/144) の整数、余白は黒(レターボックス)」の
// 計算部分は純粋関数として切り出してあるので、実ディスプレイ無しで検証できる
// (video_present自体の目視確認は phase-08-frontend.md 検証ログに別途記録する)。

@(test)
test_layout_exact_integer_multiple_windowed :: proc(t: ^testing.T) {
	// scale=4のウィンドウをそのまま作った場合(640x576)、ぴったり4倍でレターボックス無し。
	rect, scale := app.video_compute_layout(640, 576)
	testing.expect(t, scale == 4)
	testing.expect(t, rect.x == 0)
	testing.expect(t, rect.y == 0)
	testing.expect(t, rect.w == 640)
	testing.expect(t, rect.h == 576)
}

@(test)
test_layout_fullscreen_takes_min_axis_and_letterboxes :: proc(t: ^testing.T) {
	// BluePrint「画面に収まる最大の整数倍率」: 1920x1080 -> w方向12倍、h方向7.5倍 -> 7倍。
	rect, scale := app.video_compute_layout(1920, 1080)
	testing.expect(t, scale == 7)
	testing.expect(t, rect.w == 160 * 7)
	testing.expect(t, rect.h == 144 * 7)
	// 縦方向(1080/144=7.5)が律速で7倍に切り捨てられるため、縦横どちらにも
	// 余りが出て中央寄せ(レターボックス)される。
	testing.expect(t, rect.x == (1920 - 160 * 7) / 2)
	testing.expect(t, rect.y == (1080 - 144 * 7) / 2)
	testing.expect(t, rect.x > 0)
	testing.expect(t, rect.y > 0)
}

@(test)
test_layout_never_produces_non_integer_scale :: proc(t: ^testing.T) {
	// 4Kディスプレイ相当(3840x2160)でも整数倍率になること(ドット不均一の禁止、落とし穴)。
	rect, scale := app.video_compute_layout(3840, 2160)
	testing.expect(t, scale == 15) // min(3840/160=24, 2160/144=15) = 15
	testing.expect(t, rect.w == 160 * 15)
	testing.expect(t, rect.h == 144 * 15)
}

@(test)
test_layout_output_smaller_than_screen_clamps_to_scale_1 :: proc(t: ^testing.T) {
	// 異常系: 出力サイズがGB解像度を下回る場合でもクラッシュせず1倍に丸める。
	rect, scale := app.video_compute_layout(100, 100)
	testing.expect(t, scale == 1)
	testing.expect(t, rect.w == 160)
	testing.expect(t, rect.h == 144)
}

@(test)
test_layout_centers_content_both_axes :: proc(t: ^testing.T) {
	rect, scale := app.video_compute_layout(2000, 1300)
	testing.expect(t, scale == min(2000 / 160, 1300 / 144))
	content_w := i32(160 * scale)
	content_h := i32(144 * scale)
	testing.expect(t, rect.x == (2000 - content_w) / 2)
	testing.expect(t, rect.y == (1300 - content_h) / 2)
}
