package tests

// まだ安定して PASS しないことが分かっている Blargg テスト ROM の許可リスト(T1-8/T1-9)。
// testing.md「許可リスト方式」: ここに載っている ROM は FAIL/TIMEOUT でもテスト全体は
// 成功扱いになる。フェーズが進んで通るようになったらエントリを削除すること
// (削除を忘れると blargg_test.odin が「予期せぬ PASS」として検出し FAIL する)。
//
// T1-9 完了時点で cpu_instrs 個別 11 本中 10 本(02-interrupts を除く)+ instr_timing
// が PASS。02-interrupts はフェーズ2で IME/IF/IE の実際の割り込みディスパッチを
// 実装した後にパス予定のため、この許可リストに残す。cpu_instrs 統合版
// (cpu_instrs.gb)は MBC1 が必要なためフェーズ4まで別途許可リストに残す
// (現時点では @(test) 化していないためここには含めない)。
expected_failures := [?]string{"cpu_instrs/individual/02-interrupts"}

is_expected_failure :: proc(name: string) -> bool {
	for entry in expected_failures {
		if entry == name {
			return true
		}
	}
	return false
}
