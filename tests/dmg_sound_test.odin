package tests

import "core:fmt"
import "core:os"
import "core:testing"

// T5-7: Blargg dmg_sound 個別 ROM(フェーズ5のマイルストーン)。
// 01-08/11 が対象。09/10/12(wave RAMアクセス制限系)はT5-3の判断を踏襲し許可リスト残留
// (tests/expected_failures.odin にコメント付きで理由を記録)。
// ROM ファイルが無ければスキップ(./scripts/fetch_test_roms.sh 未実行のローカル環境を壊さない)。

@(private = "file")
DMG_SOUND_ROMS_DIR :: "tests/roms/blargg/dmg_sound/rom_singles"

@(private = "file")
run_dmg_sound_test :: proc(t: ^testing.T, name: string, relative_path: string) {
	path := fmt.tprintf("%s/%s", DMG_SOUND_ROMS_DIR, relative_path)

	if !os.exists(path) {
		fmt.printfln(
			"dmg_sound_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			path,
		)
		return
	}

	result := run_blargg_rom_mem_result(path)
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
		fmt.printfln("dmg_sound_test: %s は許可リストにより %v でも成功扱い", name, result)
		return
	}

	testing.expectf(t, result == .Pass, "%s: PASS を期待したが結果は %v だった", name, result)
}

@(test)
dmg_sound_01_registers :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/01-registers", "01-registers.gb")
}

@(test)
dmg_sound_02_len_ctr :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/02-len ctr", "02-len ctr.gb")
}

@(test)
dmg_sound_03_trigger :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/03-trigger", "03-trigger.gb")
}

@(test)
dmg_sound_04_sweep :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/04-sweep", "04-sweep.gb")
}

@(test)
dmg_sound_05_sweep_details :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/05-sweep details", "05-sweep details.gb")
}

@(test)
dmg_sound_06_overflow_on_trigger :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/06-overflow on trigger", "06-overflow on trigger.gb")
}

@(test)
dmg_sound_07_len_sweep_period_sync :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/07-len sweep period sync", "07-len sweep period sync.gb")
}

@(test)
dmg_sound_08_len_ctr_during_power :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/08-len ctr during power", "08-len ctr during power.gb")
}

@(test)
dmg_sound_09_wave_read_while_on :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/09-wave read while on", "09-wave read while on.gb")
}

@(test)
dmg_sound_10_wave_trigger_while_on :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/10-wave trigger while on", "10-wave trigger while on.gb")
}

@(test)
dmg_sound_11_regs_after_power :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/11-regs after power", "11-regs after power.gb")
}

@(test)
dmg_sound_12_wave_write_while_on :: proc(t: ^testing.T) {
	run_dmg_sound_test(t, "dmg_sound/12-wave write while on", "12-wave write while on.gb")
}
