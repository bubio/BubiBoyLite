package tests

import "core:testing"
import app "bbl:app"

// src/app/video.odin の video_compute_layout の単体テスト(T8-2、フルスクリーン全面見直し
// 2026-07-20 で改訂)。
// 「アスペクト比(160:144)維持の連続フィット、短手が出力に収まる最大倍率」の計算部分は
// 純粋関数として切り出してあるので、実ディスプレイ無しで検証できる
// (video_present自体の目視確認は phase-08-frontend.md 検証ログに別途記録する)。

@(test)
test_layout_exact_integer_multiple_windowed :: proc(t: ^testing.T) {
	// scale=4のウィンドウをそのまま作った場合(640x576)、ぴったり4倍でレターボックス無し。
	// ウィンドウモードでは窓が常に160*scale×144*scaleなので連続フィットでも整数倍のまま
	// (回帰なし)。
	rect, scale := app.video_compute_layout(640, 576)
	testing.expect(t, scale == 4)
	testing.expect(t, rect.x == 0)
	testing.expect(t, rect.y == 0)
	testing.expect(t, rect.w == 640)
	testing.expect(t, rect.h == 576)
}

@(test)
test_layout_fullscreen_continuous_fit_letterboxes :: proc(t: ^testing.T) {
	// 要件2026-07-20: 「短手が画面に収まる最大の連続倍率」。1920x1080では
	// scale_f = min(1920/160=12.0, 1080/144=7.5) = 7.5(高さが律速)。
	// content = 160*7.5=1200, 144*7.5=1080。縦は余白0、横は左右に均等の余白(360)。
	rect, scale := app.video_compute_layout(1920, 1080)
	testing.expect(t, rect.w == 1200)
	testing.expect(t, rect.h == 1080)
	testing.expect(t, rect.y == 0) // 律速軸(高さ)は余白0
	testing.expect(t, rect.x == 360) // (1920-1200)/2
	testing.expect(t, scale == 7) // ログ/smooth判定用の整数倍率(int(7.5)切り捨て)
}

@(test)
test_layout_fullscreen_non_integer_display_size :: proc(t: ^testing.T) {
	// 非整数倍率になる出力サイズでも連続フィットできること(1366x768、要件2026-07-20)。
	// scale_f = min(1366/160=8.5375, 768/144=5.3333...) = 5.3333...(幅方向が余裕大なので高さ律速)。
	// content_h = round(144*5.3333)=768ちょうど、content_w = round(160*5.3333)=853。
	rect, scale := app.video_compute_layout(1366, 768)
	testing.expect(t, rect.h == 768)
	testing.expect(t, rect.y == 0) // 律速軸(高さ)は余白0
	testing.expect(t, rect.w == 853)
	testing.expect(t, rect.x == 256) // (1366-853)/2 = 256(切り捨て)
	testing.expect(t, scale == 5) // int(5.333...)切り捨て
}

@(test)
test_layout_output_smaller_than_screen_clamps_to_scale_1 :: proc(t: ^testing.T) {
	// 異常系: 出力サイズがGB解像度を下回る場合でもクラッシュせず1倍に丸める。
	rect, scale := app.video_compute_layout(100, 100)
	testing.expect(t, scale == 1)
	testing.expect(t, rect.w == 160)
	testing.expect(t, rect.h == 144)
	testing.expect(t, rect.x == -30) // (100-160)/2、出力より内容が大きいので負(はみ出る、想定内)
	testing.expect(t, rect.y == -22) // (100-144)/2
}

@(test)
test_layout_centers_content_with_one_axis_flush :: proc(t: ^testing.T) {
	// 連続フィットでは律速軸(小さい方の比率の軸)は必ず余白0になり、非律速軸だけが
	// 左右または上下に均等な正の余白を持つ(整数倍フィット時代の「両軸に整数余白」テストを
	// 連続フィット向けに置換)。
	rect, scale := app.video_compute_layout(2000, 1300)
	// scale_f = min(2000/160=12.5, 1300/144=9.0277...) = 9.0277...(高さが律速)。
	testing.expect(t, scale == 9) // int(9.0277...)
	testing.expect(t, rect.y == 0) // 律速軸(高さ)は余白0
	testing.expect(t, rect.h == 1300) // round(144*9.0277...) = 1300ちょうど
	testing.expect(t, rect.x > 0) // 非律速軸(幅)は正の余白
	content_w := int(rect.w)
	testing.expect(t, int(rect.x) == (2000 - content_w) / 2) // 左右均等
}
