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
// T2-6 で Mooneye 系を初期投入。oam_dma は T2-5 の実装後に個別に許可リストから外す
// (T2-7 で最終確認)。halt_ime0_ei / halt_ime0_nointr_timing / oam_dma_start は
// wait_ly(タイムアウト無し)や実際の VBlank 割り込み発火に依存しており、フェーズ2では
// PPU 未実装のため原理的にパスしない(タイムアウトする)。フェーズ3 で PPU を実装した後に外す。
expected_failures := [?]string {
	// 要デバッグ: TACへの書き込みでの落下エッジ検出(Pan Docs "Timer Obscure Behaviour")は
	// 実装済みで timer/ 13本中12本はこれでPASSするが、このROMは秒間数万回というTACの
	// 高速トグルに対する実機のANDゲート回路レベルのグリッチ挙動まで要求しており、
	// 割り込みは発生するもののBC値(タイミングの指紋)が一致せずFAILする。T2-7で再挑戦。
	"mooneye/acceptance/timer/rapid_toggle",
	"mooneye/acceptance/interrupts/ie_push",
	"mooneye/acceptance/halt_ime0_ei", // フェーズ3送り: wait_ly $00 が実PPU無しでは終わらない
	"mooneye/acceptance/halt_ime0_nointr_timing", // フェーズ3送り: wait_ly 10 が実PPU無しでは終わらない
	"mooneye/acceptance/oam_dma/basic",
	"mooneye/acceptance/oam_dma/reg_read",
	"mooneye/acceptance/oam_dma_start", // フェーズ3送り: wait_vblank が実PPU無しでは終わらない
}

is_expected_failure :: proc(name: string) -> bool {
	for entry in expected_failures {
		if entry == name {
			return true
		}
	}
	return false
}
