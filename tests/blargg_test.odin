package tests

import "core:fmt"
import "core:os"
import "core:testing"

// Blargg cpu_instrs 個別 11 本 + instr_timing の @(test) 一覧(T1-8/T1-9)。
// ROM ファイルが無ければスキップ(./scripts/fetch_test_roms.sh 未実行のローカル環境を壊さない)。
// 結果判定は tests/rom_runner.odin、許可リストは tests/expected_failures.odin を参照。

@(private = "file")
BLARGG_ROMS_DIR :: "tests/roms/blargg"

@(private = "file")
run_blargg_test :: proc(t: ^testing.T, name: string, relative_path: string) {
	// tprintf は temp_allocator を使うため、ここでの delete は不要(かつ誤り)。
	path := fmt.tprintf("%s/%s", BLARGG_ROMS_DIR, relative_path)

	if !os.exists(path) {
		fmt.printfln(
			"blargg_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			path,
		)
		return
	}

	result := run_blargg_rom(path)
	expected_fail := is_expected_failure(name)

	if expected_fail {
		if result == .Pass {
			testing.fail_now(
				t,
				fmt.tprintf(
					"%s は expected_failures 許可リストに入っているが PASS した。tests/expected_failures.odin から外すこと",
					name,
				),
			)
		}
		fmt.printfln("blargg_test: %s は許可リストにより %v でも成功扱い", name, result)
		return
	}

	testing.expectf(t, result == .Pass, "%s: PASS を期待したが結果は %v だった", name, result)
}

@(test)
blargg_cpu_instrs_01_special :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/01-special", "cpu_instrs/individual/01-special.gb")
}

@(test)
blargg_cpu_instrs_02_interrupts :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/02-interrupts", "cpu_instrs/individual/02-interrupts.gb")
}

@(test)
blargg_cpu_instrs_03_op_sp_hl :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/03-op sp,hl", "cpu_instrs/individual/03-op sp,hl.gb")
}

@(test)
blargg_cpu_instrs_04_op_r_imm :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/04-op r,imm", "cpu_instrs/individual/04-op r,imm.gb")
}

@(test)
blargg_cpu_instrs_05_op_rp :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/05-op rp", "cpu_instrs/individual/05-op rp.gb")
}

@(test)
blargg_cpu_instrs_06_ld_r_r :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/06-ld r,r", "cpu_instrs/individual/06-ld r,r.gb")
}

@(test)
blargg_cpu_instrs_07_jr_jp_call_ret_rst :: proc(t: ^testing.T) {
	run_blargg_test(
		t,
		"cpu_instrs/individual/07-jr,jp,call,ret,rst",
		"cpu_instrs/individual/07-jr,jp,call,ret,rst.gb",
	)
}

@(test)
blargg_cpu_instrs_08_misc_instrs :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/08-misc instrs", "cpu_instrs/individual/08-misc instrs.gb")
}

@(test)
blargg_cpu_instrs_09_op_r_r :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/09-op r,r", "cpu_instrs/individual/09-op r,r.gb")
}

@(test)
blargg_cpu_instrs_10_bit_ops :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/10-bit ops", "cpu_instrs/individual/10-bit ops.gb")
}

@(test)
blargg_cpu_instrs_11_op_a_hl :: proc(t: ^testing.T) {
	run_blargg_test(t, "cpu_instrs/individual/11-op a,(hl)", "cpu_instrs/individual/11-op a,(hl).gb")
}

@(test)
blargg_instr_timing :: proc(t: ^testing.T) {
	run_blargg_test(t, "instr_timing/instr_timing", "instr_timing/instr_timing.gb")
}

// cpu_instrs 統合版(T4-2)。11本の個別テストを直列に実行する MBC1 カートリッジ(64KiB、
// type=0x01)なので、MBC1 のバンク切替が正しく動くことの結合確認を兼ねる
// (phase-04-cartridge.md T4-2 の完了条件)。共通タイムアウトを超えるため個別に長めの
// タイムアウトを指定する(rom_runner.odin の CPU_INSTRS_INTEGRATED_TIMEOUT_TCYCLES 参照)。
@(test)
blargg_cpu_instrs_integrated :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/%s", BLARGG_ROMS_DIR, "cpu_instrs/cpu_instrs.gb")

	if !os.exists(path) {
		fmt.printfln(
			"blargg_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			path,
		)
		return
	}

	result := run_blargg_rom(path, CPU_INSTRS_INTEGRATED_TIMEOUT_TCYCLES)
	name := "cpu_instrs/cpu_instrs (integrated)"
	expected_fail := is_expected_failure(name)

	if expected_fail {
		if result == .Pass {
			testing.fail_now(
				t,
				fmt.tprintf(
					"%s は expected_failures 許可リストに入っているが PASS した。tests/expected_failures.odin から外すこと",
					name,
				),
			)
		}
		fmt.printfln("blargg_test: %s は許可リストにより %v でも成功扱い", name, result)
		return
	}

	testing.expectf(t, result == .Pass, "%s: PASS を期待したが結果は %v だった", name, result)
}
