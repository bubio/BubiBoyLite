package tests

import "core:testing"
import core "bbl:core"

// T6-6: ダブルスピードモード(KEY1 + STOPによる切替)の単体テスト。
// DoD: 「切替でKEY1 bit7反転・DIVリセット」「ダブルスピード時に1フレームのCPUサイクルが2倍」。

// write_stop_program は WRAM(0xC000、書き込み可能な領域。ROM領域はカートリッジ未ロードの
// テストではmbc_writeが無視するため使えない)にSTOP命令(0x10 0x00)を置きPCをそこへ合わせる。
@(private = "file")
write_stop_program :: proc(bus: ^core.Bus, cpu: ^core.Cpu, addr: u16) {
	core.bus_write(bus, addr, 0x10)
	core.bus_write(bus, addr + 1, 0x00)
	cpu.pc = addr
}

@(test)
test_key1_prepare_and_stop_toggles_double_speed :: proc(t: ^testing.T) {
	cpu: core.Cpu
	bus: core.Bus
	bus.mode = .Cgb
	core.cpu_reset(&cpu, .Cgb)

	testing.expect(t, !bus.double_speed, "初期状態は等速のはず")
	testing.expectf(t, core.bus_read(&bus, core.KEY1_ADDR) == 0x7E, "初期KEY1読み出しは0x7Eのはず, got=%02X", core.bus_read(&bus, core.KEY1_ADDR))

	// 切替準備(bit0=1)を書き込んでからSTOPを実行する。
	core.bus_write(&bus, core.KEY1_ADDR, 0x01)
	testing.expectf(t, core.bus_read(&bus, core.KEY1_ADDR) == 0x7F, "準備済みKEY1はbit0=1で0x7Fのはず, got=%02X", core.bus_read(&bus, core.KEY1_ADDR))

	// DIVを非ゼロにしてからSTOPでリセットされることを確認する。
	core.bus_tick(&bus, 4096) // div_counterの上位8bit(DIV)が0でなくなる程度に進める

	write_stop_program(&bus, &cpu, 0xC000)
	core.cpu_step(&cpu, &bus)

	testing.expect(t, bus.double_speed, "STOP実行後はダブルスピードに切り替わるはず")
	testing.expect(t, !bus.speed_switch_prepared, "切替後はprepared状態がクリアされるはず")
	testing.expectf(t, core.bus_read(&bus, core.KEY1_ADDR) == 0xFE, "切替後のKEY1はbit7=1で0xFEのはず(bit0は既にクリア), got=%02X", core.bus_read(&bus, core.KEY1_ADDR))
	testing.expectf(t, core.bus_read(&bus, core.DIV_ADDR) == 0x00, "STOPによる速度切替でDIVがリセットされるはず, got=%02X", core.bus_read(&bus, core.DIV_ADDR))

	// もう一度切替準備してSTOPすると等速に戻る。
	core.bus_write(&bus, core.KEY1_ADDR, 0x01)
	write_stop_program(&bus, &cpu, 0xC002)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, !bus.double_speed, "再度STOPすると等速に戻るはず")
}

@(test)
test_stop_without_prepare_does_not_toggle_speed :: proc(t: ^testing.T) {
	cpu: core.Cpu
	bus: core.Bus
	bus.mode = .Cgb
	core.cpu_reset(&cpu, .Cgb)

	// speed_switch_prepared を立てずにSTOPを実行しても速度は変わらない(既存のopcode
	// カバレッジテストが期待する「無視」挙動を維持することの確認)。
	write_stop_program(&bus, &cpu, 0xC000)
	core.cpu_step(&cpu, &bus)

	testing.expect(t, !bus.double_speed, "prepared無しのSTOPでは速度が変わらないはず")
}

@(test)
test_stop_speed_switch_ignored_in_dmg_mode :: proc(t: ^testing.T) {
	cpu: core.Cpu
	bus: core.Bus
	bus.mode = .Dmg
	core.cpu_reset(&cpu, .Dmg)

	// DMGモードではKEY1書き込み自体が無視されるため、speed_switch_preparedは立たない。
	core.bus_write(&bus, core.KEY1_ADDR, 0x01)
	testing.expect(t, !bus.speed_switch_prepared, "DMGモードではKEY1書き込みが無視されるはず")

	write_stop_program(&bus, &cpu, 0xC000)
	core.cpu_step(&cpu, &bus)
	testing.expect(t, !bus.double_speed, "DMGモードではSTOPで速度が変わらないはず")
}

@(test)
test_double_speed_frame_consumes_double_cpu_cycles :: proc(t: ^testing.T) {
	// ダブルスピード中、emulator_run_frame は PPU 側クロック(hw_cycles)で70224に
	// 達するまでループするため、CPU側クロック(bus.cycles)は等速時のほぼ2倍消費されるはず。
	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)

	// ROM無しで直接bus/cpuを起動状態にする(emulator_load_romは実際のROMが要るため、
	// ここではcpu_reset+bus_power_onを手動で呼ぶ)。CGBモードを手動セットし、
	// 全アドレスがNOP(0x00)であるROM相当のバッファを用意してdouble_speedをtrueにする。
	rom := make([]u8, 0x8000)
	defer delete(rom)
	// 全部NOP(0x00)なので初期値のままでよい。ヘッダのCGBフラグだけ立てる。
	rom[core.HEADER_CGB_FLAG_ADDR] = 0xC0
	rom[core.HEADER_TYPE_ADDR] = 0x00
	rom[core.HEADER_ROM_SIZE_ADDR] = 0x00
	rom[core.HEADER_RAM_SIZE_ADDR] = 0x00

	loaded := core.emulator_load_rom(emu, rom)
	testing.expect(t, loaded, "ROMロードに失敗した")
	testing.expect(t, emu.bus.mode == .Cgb, "CGBモードで起動しているはず")

	// 等速で1フレーム実行し、消費CPUサイクルを記録する。
	core.emulator_run_frame(emu)
	single_speed_cycles := emu.bus.cycles

	// ダブルスピードへ切替(STOPを直接呼ぶ代わりにbus状態を直接操作して検証を単純化する)。
	emu.bus.double_speed = true
	before := emu.bus.cycles
	core.emulator_run_frame(emu)
	double_speed_cycles := emu.bus.cycles - before

	testing.expectf(
		t,
		double_speed_cycles >= single_speed_cycles * 2 - 8 && double_speed_cycles <= single_speed_cycles * 2 + 8,
		"ダブルスピード中の1フレームのCPUサイクルは等速の約2倍のはず: single=%d double=%d",
		single_speed_cycles,
		double_speed_cycles,
	)
}
