package tests

import "core:fmt"
import "core:os"
import "core:testing"

// Mooneye acceptance の timer/・intr 系・halt 系・oam_dma 系の @(test) 一覧(T2-6)。
// 判定は tests/rom_runner.odin の run_mooneye_rom(LD B,B + レジスタ指紋)、
// 許可リストは tests/expected_failures.odin(blargg と共用)を参照。
// ROM ファイルが無ければスキップ(./scripts/fetch_test_roms.sh 未実行のローカル環境を壊さない)。

@(private = "file")
MOONEYE_ROMS_DIR :: "tests/roms/mooneye"

@(private = "file")
run_mooneye_test :: proc(t: ^testing.T, name: string, relative_path: string) {
	path := fmt.tprintf("%s/%s", MOONEYE_ROMS_DIR, relative_path)

	if !os.exists(path) {
		fmt.printfln(
			"mooneye_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			path,
		)
		return
	}

	result := run_mooneye_rom(path)
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
		fmt.printfln("mooneye_test: %s は許可リストにより %v でも成功扱い", name, result)
		return
	}

	testing.expectf(t, result == .Pass, "%s: PASS を期待したが結果は %v だった", name, result)
}

// --- timer/ 全13本(T2-3) ---

@(test)
mooneye_timer_div_write :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/div_write", "acceptance/timer/div_write.gb")
}

@(test)
mooneye_timer_rapid_toggle :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/rapid_toggle", "acceptance/timer/rapid_toggle.gb")
}

@(test)
mooneye_timer_tim00 :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/tim00", "acceptance/timer/tim00.gb")
}

@(test)
mooneye_timer_tim00_div_trigger :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/timer/tim00_div_trigger",
		"acceptance/timer/tim00_div_trigger.gb",
	)
}

@(test)
mooneye_timer_tim01 :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/tim01", "acceptance/timer/tim01.gb")
}

@(test)
mooneye_timer_tim01_div_trigger :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/timer/tim01_div_trigger",
		"acceptance/timer/tim01_div_trigger.gb",
	)
}

@(test)
mooneye_timer_tim10 :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/tim10", "acceptance/timer/tim10.gb")
}

@(test)
mooneye_timer_tim10_div_trigger :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/timer/tim10_div_trigger",
		"acceptance/timer/tim10_div_trigger.gb",
	)
}

@(test)
mooneye_timer_tim11 :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/tim11", "acceptance/timer/tim11.gb")
}

@(test)
mooneye_timer_tim11_div_trigger :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/timer/tim11_div_trigger",
		"acceptance/timer/tim11_div_trigger.gb",
	)
}

@(test)
mooneye_timer_tima_reload :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/timer/tima_reload", "acceptance/timer/tima_reload.gb")
}

@(test)
mooneye_timer_tima_write_reloading :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/timer/tima_write_reloading",
		"acceptance/timer/tima_write_reloading.gb",
	)
}

@(test)
mooneye_timer_tma_write_reloading :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/timer/tma_write_reloading",
		"acceptance/timer/tma_write_reloading.gb",
	)
}

// --- intr 系(T2-1/T2-2) ---

@(test)
mooneye_intr_ie_push :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/interrupts/ie_push", "acceptance/interrupts/ie_push.gb")
}

@(test)
mooneye_intr_if_ie_registers :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/if_ie_registers", "acceptance/if_ie_registers.gb")
}

@(test)
mooneye_intr_timing :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/intr_timing", "acceptance/intr_timing.gb")
}

@(test)
mooneye_intr_rapid_di_ei :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/rapid_di_ei", "acceptance/rapid_di_ei.gb")
}

@(test)
mooneye_intr_ei_timing :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/ei_timing", "acceptance/ei_timing.gb")
}

// --- halt 系(T2-2) ---

@(test)
mooneye_halt_ime0_ei :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/halt_ime0_ei", "acceptance/halt_ime0_ei.gb")
}

@(test)
mooneye_halt_ime0_nointr_timing :: proc(t: ^testing.T) {
	run_mooneye_test(
		t,
		"mooneye/acceptance/halt_ime0_nointr_timing",
		"acceptance/halt_ime0_nointr_timing.gb",
	)
}

@(test)
mooneye_halt_ime1_timing :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/halt_ime1_timing", "acceptance/halt_ime1_timing.gb")
}

// --- oam_dma 系(T2-5) ---

@(test)
mooneye_oam_dma_basic :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/oam_dma/basic", "acceptance/oam_dma/basic.gb")
}

@(test)
mooneye_oam_dma_reg_read :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/oam_dma/reg_read", "acceptance/oam_dma/reg_read.gb")
}

@(test)
mooneye_oam_dma_start :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/acceptance/oam_dma_start", "acceptance/oam_dma_start.gb")
}

// --- emulator-only/mbc1 系(T4-2/T4-7) ---
// mbc1/multicart_rom_8Mb.gb はMBC1M(マルチカート)専用ROM向けでスコープ外のため対象外
// (phase-04-cartridge.md T4-7の落とし穴、fetch_test_roms.shでも取得しない)。

@(test)
mooneye_mbc1_bits_bank1 :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/bits_bank1", "emulator-only/mbc1/bits_bank1.gb")
}

@(test)
mooneye_mbc1_bits_bank2 :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/bits_bank2", "emulator-only/mbc1/bits_bank2.gb")
}

@(test)
mooneye_mbc1_bits_mode :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/bits_mode", "emulator-only/mbc1/bits_mode.gb")
}

@(test)
mooneye_mbc1_bits_ramg :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/bits_ramg", "emulator-only/mbc1/bits_ramg.gb")
}

@(test)
mooneye_mbc1_ram_64kb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/ram_64kb", "emulator-only/mbc1/ram_64kb.gb")
}

@(test)
mooneye_mbc1_ram_256kb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/ram_256kb", "emulator-only/mbc1/ram_256kb.gb")
}

@(test)
mooneye_mbc1_rom_512kb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/rom_512kb", "emulator-only/mbc1/rom_512kb.gb")
}

@(test)
mooneye_mbc1_rom_1mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/rom_1Mb", "emulator-only/mbc1/rom_1Mb.gb")
}

@(test)
mooneye_mbc1_rom_2mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/rom_2Mb", "emulator-only/mbc1/rom_2Mb.gb")
}

@(test)
mooneye_mbc1_rom_4mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/rom_4Mb", "emulator-only/mbc1/rom_4Mb.gb")
}

@(test)
mooneye_mbc1_rom_8mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/rom_8Mb", "emulator-only/mbc1/rom_8Mb.gb")
}

@(test)
mooneye_mbc1_rom_16mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc1/rom_16Mb", "emulator-only/mbc1/rom_16Mb.gb")
}

// --- emulator-only/mbc2 系(T4-3/T4-7) ---

@(test)
mooneye_mbc2_bits_ramg :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/bits_ramg", "emulator-only/mbc2/bits_ramg.gb")
}

@(test)
mooneye_mbc2_bits_romb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/bits_romb", "emulator-only/mbc2/bits_romb.gb")
}

@(test)
mooneye_mbc2_bits_unused :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/bits_unused", "emulator-only/mbc2/bits_unused.gb")
}

@(test)
mooneye_mbc2_ram :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/ram", "emulator-only/mbc2/ram.gb")
}

@(test)
mooneye_mbc2_rom_512kb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/rom_512kb", "emulator-only/mbc2/rom_512kb.gb")
}

@(test)
mooneye_mbc2_rom_1mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/rom_1Mb", "emulator-only/mbc2/rom_1Mb.gb")
}

@(test)
mooneye_mbc2_rom_2mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc2/rom_2Mb", "emulator-only/mbc2/rom_2Mb.gb")
}

// --- emulator-only/mbc5 系(T4-5/T4-7) ---

@(test)
mooneye_mbc5_rom_512kb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_512kb", "emulator-only/mbc5/rom_512kb.gb")
}

@(test)
mooneye_mbc5_rom_1mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_1Mb", "emulator-only/mbc5/rom_1Mb.gb")
}

@(test)
mooneye_mbc5_rom_2mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_2Mb", "emulator-only/mbc5/rom_2Mb.gb")
}

@(test)
mooneye_mbc5_rom_4mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_4Mb", "emulator-only/mbc5/rom_4Mb.gb")
}

@(test)
mooneye_mbc5_rom_8mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_8Mb", "emulator-only/mbc5/rom_8Mb.gb")
}

@(test)
mooneye_mbc5_rom_16mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_16Mb", "emulator-only/mbc5/rom_16Mb.gb")
}

@(test)
mooneye_mbc5_rom_32mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_32Mb", "emulator-only/mbc5/rom_32Mb.gb")
}

@(test)
mooneye_mbc5_rom_64mb :: proc(t: ^testing.T) {
	run_mooneye_test(t, "mooneye/emulator-only/mbc5/rom_64Mb", "emulator-only/mbc5/rom_64Mb.gb")
}
