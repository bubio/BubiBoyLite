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
