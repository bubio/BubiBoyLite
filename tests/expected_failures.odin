package tests

// まだ安定して PASS しないことが分かっている Blargg テスト ROM の許可リスト(T1-8/T1-9)。
// testing.md「許可リスト方式」: ここに載っている ROM は FAIL/TIMEOUT でもテスト全体は
// 成功扱いになる。フェーズが進んで通るようになったらエントリを削除すること
// (削除を忘れると blargg_test.odin が「予期せぬ PASS」として検出し FAIL する)。
//
// 初期状態(T1-8 時点)は cpu_instrs 個別 11 本 + instr_timing の 12 本全部。
// T1-9 でデバッグして 02-interrupts (フェーズ2で割り込み実装後にパス予定) を除く
// 11 本を外す。cpu_instrs 統合版(cpu_instrs.gb)は MBC1 が必要なためフェーズ4まで
// 別途許可リストに残す(現時点では @(test) 化していないためここには含めない)。
expected_failures := [?]string {
	"cpu_instrs/individual/02-interrupts",
	"instr_timing/instr_timing",
}

is_expected_failure :: proc(name: string) -> bool {
	for entry in expected_failures {
		if entry == name {
			return true
		}
	}
	return false
}
