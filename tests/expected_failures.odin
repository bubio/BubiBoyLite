package tests

// まだ安定して PASS しないことが分かっているテスト ROM(Blargg/Mooneye 共用)の許可リスト
// (T1-8/T1-9/T2-6)。testing.md「許可リスト方式」: ここに載っている ROM は FAIL/TIMEOUT でも
// テスト全体は成功扱いになる。フェーズが進んで通るようになったらエントリを削除すること
// (削除を忘れると blargg_test.odin/mooneye_test.odin が「予期せぬ PASS」として検出し FAIL する)。
//
// T2-2(IME 1命令遅延・HALT起床・HALTバグ)完了時点で cpu_instrs/02-interrupts、
// mooneye halt_ime1_timing・ei_timing・rapid_di_ei が PASS するようになったため除外済み。
// cpu_instrs 統合版(cpu_instrs.gb)は MBC1 が必要なためフェーズ4まで別途許可リストに残す
// (現時点では @(test) 化していないためここには含めない)。
//
// T2-3(DIV/TIMA落下エッジ実装)完了時点で timer/ 13本中 div_write・tim00・tim01_div_trigger・
// tim10・tim10_div_trigger・tim11・tima_reload・tima_write_reloading・tma_write_reloadingが
// PASSするようになったため除外済み。rapid_toggle はまだ通らないため残す(要デバッグ、T2-7で再挑戦)。
//
// T2-5(OAM DMA実装)完了時点で以下がフェーズ3送りと確定した。バイナリを逆アセンブルして
// 原因を特定済み: 該当ROM(2024-02リリースのc-sp/game-boy-test-romsに同梱のビルド)は
// 冒頭で `disable_ppu_safe`(LCDC bit7=1ならLYが$90になるまで**タイムアウト無しで**ポーリング
// し続ける版)を呼んでいる。LCDC/LYはフェーズ3までどちらも未実装の固定0xFFのため、
// この時点で無限ループしテスト本体(ie_push本来のIE破壊ロジックや、DMA転送内容の検証)へ
// 到達すらできない。ie_push のディスパッチ本体は tests/interrupt_test.odin の単体テストで
// 別途 mooneye ie_push.s のRound1/Round3を手でトレースして検証済み。
expected_failures := [?]string {
	// 未解決(T2-7で深く調査したが解決できず。PPU非依存でありフェーズ3送りにできる
	// 正当な理由がないため、この1件が原因でフェーズ2のマイルストーンは🟢にできていない):
	// TACへの書き込みでの落下エッジ検出(Pan Docs "Timer Obscure Behaviour")は実装済みで
	// timer/ 13本中12本はこれでPASSする。rapid_toggleは実測でB=C=D=E=H=L=0x42(FAIL)。
	// 調査結果: タイマー割り込み自体は発生している。ディスパッチ直前にBCを直接観測すると
	// BC=$FFD8(期待値$FFD9より1少ない=ループが1回多く回ってから割り込みが認識されている)。
	// 独立に書いたT-cycle精度のPythonシミュレータ(命令ごとの正確なサイクル数からdiv/edge
	// を再現)でこのROMの39回のループ全て(TAC書き込み78回ぶんのold_signal/new_signal/fired
	// を1件ずつ)を突き合わせたところ、Odin実装と完全一致(diff無し)。オーバーフロー自体は
	// Pan Docsの実測サンプル表(TIMA overflow worked example、SYS=2B..31)の列アラインメントを
	// 再確認し、「エッジ検出→TIMA=$00が見えるまで1 M-cycle→IF確定まで更に1 M-cycle」という
	// 2段階の遅延も自実装と一致することを確認済み。それでもBCが1ずれる原因は、割り込み確定
	// (IF bit2 セット)が DEC BC の内部サイクル中に完了するため、DEC BC自体は(命令境界でしか
	// 割り込みを認識しない通常のSM83モデルでは)最後まで実行されてしまう点にある。これが
	// 実機の挙動と一致するのか、DEC BCのような2 M-cycle命令に限り実機がM-cycle粒度で割り込みを
	// 認識する特例があるのかを、Pan Docsの記述だけでは判別できなかった(要: 実機トレース or
	// 既知の高精度エミュレータとの突き合わせ)。次セッションでの再挑戦時はこの調査結果から
	// 始めること。
	"mooneye/acceptance/timer/rapid_toggle",
	"mooneye/acceptance/interrupts/ie_push", // フェーズ3送り: disable_ppu_safeがLY待ちで無限ループ(下記注記)
	"mooneye/acceptance/halt_ime0_ei", // フェーズ3送り: wait_ly $00 が実PPU無しでは終わらない
	"mooneye/acceptance/halt_ime0_nointr_timing", // フェーズ3送り: wait_ly 10 が実PPU無しでは終わらない
	"mooneye/acceptance/oam_dma/basic", // フェーズ3送り: disable_ppu_safeがLY待ちで無限ループ(下記注記)
	"mooneye/acceptance/oam_dma/reg_read", // フェーズ3送り: disable_ppu_safeがLY待ちで無限ループ(下記注記)
	"mooneye/acceptance/oam_dma_start", // フェーズ3送り: disable_ppu_safeがLY待ちで無限ループ(下記注記)
}

is_expected_failure :: proc(name: string) -> bool {
	for entry in expected_failures {
		if entry == name {
			return true
		}
	}
	return false
}
