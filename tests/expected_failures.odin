package tests

// まだ安定して PASS しないことが分かっているテスト ROM(Blargg/Mooneye 共用)の許可リスト
// (T1-8/T1-9/T2-6)。testing.md「許可リスト方式」: ここに載っている ROM は FAIL/TIMEOUT でも
// テスト全体は成功扱いになる。フェーズが進んで通るようになったらエントリを削除すること
// (削除を忘れると blargg_test.odin/mooneye_test.odin が「予期せぬ PASS」として検出し FAIL する)。
//
// T1-9 完了時点で cpu_instrs 個別 11 本中 10 本(02-interrupts を除く)+ instr_timing
// が PASS。02-interrupts はフェーズ2で IME/IF/IE の実際の割り込みディスパッチを
// 実装した後にパス予定のため、この許可リストに残す。cpu_instrs 統合版
// (cpu_instrs.gb)は MBC1 が必要なためフェーズ4まで別途許可リストに残す
// (現時点では @(test) 化していないためここには含めない)。
//
// T2-6 で Mooneye 系を初期投入。timer/intr/halt/oam_dma はそれぞれ T2-3/T2-2/T2-5 の実装後に
// 個別に許可リストから外す(T2-7 で最終確認)。halt_ime0_ei / halt_ime0_nointr_timing /
// oam_dma_start は wait_ly(タイムアウト無し)や実際の VBlank 割り込み発火に依存しており、
// フェーズ2では PPU 未実装のため原理的にパスしない(タイムアウトする)。フェーズ3 で PPU を
// 実装した後に外す。
expected_failures := [?]string {
	"cpu_instrs/individual/02-interrupts",
	"mooneye/acceptance/timer/div_write",
	"mooneye/acceptance/timer/rapid_toggle",
	"mooneye/acceptance/timer/tim00",
	"mooneye/acceptance/timer/tim01_div_trigger",
	"mooneye/acceptance/timer/tim10",
	"mooneye/acceptance/timer/tim10_div_trigger",
	"mooneye/acceptance/timer/tim11",
	"mooneye/acceptance/timer/tima_reload",
	"mooneye/acceptance/timer/tima_write_reloading",
	"mooneye/acceptance/timer/tma_write_reloading",
	"mooneye/acceptance/interrupts/ie_push",
	"mooneye/acceptance/rapid_di_ei",
	"mooneye/acceptance/ei_timing",
	"mooneye/acceptance/halt_ime0_ei", // フェーズ3送り: wait_ly $00 が実PPU無しでは終わらない
	"mooneye/acceptance/halt_ime0_nointr_timing", // フェーズ3送り: wait_ly 10 が実PPU無しでは終わらない
	"mooneye/acceptance/halt_ime1_timing",
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
