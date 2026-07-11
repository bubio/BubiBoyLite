package tests

import "core:fmt"
import "core:os"
import "core:strings"
import core "bbl:core"

// テスト ROM をヘッドレスで実行する共通ランナー(T1-8)。
// testing.md「判定方式」の Blargg 方式(シリアル出力)を実装する。
// Mooneye 方式(LD B,B + レジスタ指紋)と acid2 方式(フレームバッファハッシュ)は
// 該当フェーズ(2, 3)で追加する。

// タイムアウト = 120,000,000 T-cycle (約 28.6 秒相当、testing.md 共通仕様)。
ROM_TIMEOUT_TCYCLES :: 120_000_000

// cpu_instrs.gb(統合版、T4-2)は11本の個別テストを直列に実行するため共通タイムアウトを
// 超える。実測 224,317,844 T-cycle で PASS することを確認済み(2026-07-11、MBC1実装完了時)。
// T-cycle数はホストの実行速度に依存しない決定的な値なのでマージンを乗せて固定する。
CPU_INSTRS_INTEGRATED_TIMEOUT_TCYCLES :: 240_000_000

Rom_Result :: enum {
	Pass,
	Fail,
	Timeout,
}

// run_blargg_rom は ROM-only カートリッジをロードして実行し、シリアル出力に
// "Passed"/"Failed" が現れたタイミングで判定する。タイムアウトまで現れなければ .Timeout。
// 失敗・タイムアウト時はデバッグのためシリアル出力全文を標準エラーに出す。
// timeout_tcycles を省略すると共通タイムアウト(ROM_TIMEOUT_TCYCLES)を使う
// (cpu_instrs.gb統合版のように長時間かかるROMは呼び出し側で個別に指定する、T4-2)。
run_blargg_rom :: proc(path: string, timeout_tcycles: u64 = ROM_TIMEOUT_TCYCLES) -> Rom_Result {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("rom_runner: ROM を読み込めません: %s (%v)", path, err)
		return .Fail
	}

	cpu: core.Cpu
	bus: core.Bus
	defer core.bus_destroy(&bus)
	defer delete(bus.cart.rom)
	defer delete(bus.serial_log)

	if !core.bus_load_rom(&bus, data) {
		fmt.eprintfln("rom_runner: ROM のロードに失敗: %s (%v)", path, bus.cart_load_error)
		return .Fail
	}
	core.bus_power_on(&bus)
	core.cpu_reset(&cpu, .DMG)

	for bus.cycles < timeout_tcycles {
		core.cpu_step(&cpu, &bus)

		log_str := core.serial_get_log(&bus)
		if strings.contains(log_str, "Passed") {
			return .Pass
		}
		if strings.contains(log_str, "Failed") {
			fmt.eprintfln(
				"rom_runner: FAIL: %s\n--- serial log ---\n%s\n------------------",
				path,
				log_str,
			)
			return .Fail
		}
	}

	fmt.eprintfln(
		"rom_runner: TIMEOUT: %s (%d T-cycle 経過)\n--- serial log ---\n%s\n------------------",
		path,
		bus.cycles,
		core.serial_get_log(&bus),
	)
	return .Timeout
}

// run_mooneye_rom は ROM-only カートリッジをロードして実行し、Mooneye 方式
// (LD B,B + レジスタ指紋)で判定する(T2-6、testing.md「Mooneye 方式」)。
// cpu.debug_break_on_ld_b_b を立てて実行し、0x40(LD B,B) が実行されたら停止する:
//   PASS: B=3, C=5, D=8, E=13, H=21, L=34(フィボナッチ数列)
//   FAIL: それ以外(典型的には全レジスタ 0x42)
run_mooneye_rom :: proc(path: string) -> Rom_Result {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("rom_runner: ROM を読み込めません: %s (%v)", path, err)
		return .Fail
	}

	cpu: core.Cpu
	bus: core.Bus
	defer core.bus_destroy(&bus)
	defer delete(bus.cart.rom)
	defer delete(bus.serial_log)

	if !core.bus_load_rom(&bus, data) {
		fmt.eprintfln("rom_runner: ROM のロードに失敗: %s (%v)", path, bus.cart_load_error)
		return .Fail
	}
	core.bus_power_on(&bus)
	core.cpu_reset(&cpu, .DMG)
	cpu.debug_break_on_ld_b_b = true

	for bus.cycles < ROM_TIMEOUT_TCYCLES {
		core.cpu_step(&cpu, &bus)

		if cpu.ld_b_b_hit {
			if cpu.b == 3 && cpu.c == 5 && cpu.d == 8 && cpu.e == 13 && cpu.h == 21 && cpu.l == 34 {
				return .Pass
			}
			fmt.eprintfln(
				"rom_runner: FAIL: %s (B=%02X C=%02X D=%02X E=%02X H=%02X L=%02X)",
				path,
				cpu.b,
				cpu.c,
				cpu.d,
				cpu.e,
				cpu.h,
				cpu.l,
			)
			return .Fail
		}
	}

	fmt.eprintfln("rom_runner: TIMEOUT: %s (%d T-cycle 経過)", path, bus.cycles)
	return .Timeout
}
