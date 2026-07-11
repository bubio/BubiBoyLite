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

Rom_Result :: enum {
	Pass,
	Fail,
	Timeout,
}

// run_blargg_rom は ROM-only カートリッジをロードして実行し、シリアル出力に
// "Passed"/"Failed" が現れたタイミングで判定する。タイムアウトまで現れなければ .Timeout。
// 失敗・タイムアウト時はデバッグのためシリアル出力全文を標準エラーに出す。
run_blargg_rom :: proc(path: string) -> Rom_Result {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("rom_runner: ROM を読み込めません: %s (%v)", path, err)
		return .Fail
	}

	cpu: core.Cpu
	bus: core.Bus
	defer delete(bus.rom)
	defer delete(bus.serial_log)

	if !core.bus_load_rom(&bus, data) {
		fmt.eprintfln("rom_runner: ROM のロードに失敗: %s", path)
		return .Fail
	}
	core.cpu_reset(&cpu, .DMG)

	for bus.cycles < ROM_TIMEOUT_TCYCLES {
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
	defer delete(bus.rom)
	defer delete(bus.serial_log)

	if !core.bus_load_rom(&bus, data) {
		fmt.eprintfln("rom_runner: ROM のロードに失敗: %s", path)
		return .Fail
	}
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
