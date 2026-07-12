package tests

import "core:testing"
import core "bbl:core"

// T6-3: WRAM バンク切替(SVBK)の単体テスト。
// DoD: バンク切替、0→1読み替え、エコー追従。

@(test)
test_svbk_switches_wram_bank_for_cpu_access :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.SVBK_ADDR, 2)
	core.bus_write(&bus, 0xD000, 0xAA)
	core.bus_write(&bus, core.SVBK_ADDR, 3)
	core.bus_write(&bus, 0xD000, 0x55)

	core.bus_write(&bus, core.SVBK_ADDR, 2)
	testing.expectf(t, core.bus_read(&bus, 0xD000) == 0xAA, "バンク2の値が読めるはず")
	core.bus_write(&bus, core.SVBK_ADDR, 3)
	testing.expectf(t, core.bus_read(&bus, 0xD000) == 0x55, "バンク3の値が読めるはず")

	// C000-CFFFはバンク切替の影響を受けない(常にバンク0)。
	core.bus_write(&bus, 0xC000, 0x11)
	core.bus_write(&bus, core.SVBK_ADDR, 5)
	testing.expectf(t, core.bus_read(&bus, 0xC000) == 0x11, "C000-CFFFはバンク0固定のはず")
}

@(test)
test_svbk_zero_reads_back_as_bank_one :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.SVBK_ADDR, 0) // 0指定は1扱い(落とし穴)
	got := core.bus_read(&bus, core.SVBK_ADDR)
	testing.expectf(t, got == 0xF9, "SVBK=0書き込み後の読み出しはバンク1扱いで0xF9のはず, got=%02X", got)

	// バンク1に書いた値がSVBK=0選択時と同じ場所に見えることも確認する。
	core.bus_write(&bus, 0xD000, 0x77)
	core.bus_write(&bus, core.SVBK_ADDR, 1)
	testing.expectf(t, core.bus_read(&bus, 0xD000) == 0x77, "SVBK=0とSVBK=1は同じバンク1を指すはず")
}

@(test)
test_svbk_default_bank_is_one_without_power_on :: proc(t: ^testing.T) {
	// bus_power_on を呼ばない生の Bus{}(既存テストの慣習)でも、SVBK未書き込みの
	// デフォルトはバンク1として振る舞うはず(wram_active_bankの解決による)。
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, 0xD000, 0x99)
	core.bus_write(&bus, core.SVBK_ADDR, 1)
	testing.expectf(t, core.bus_read(&bus, 0xD000) == 0x99, "デフォルトはバンク1のはず")
}

@(test)
test_echo_ram_follows_wram_bank :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Cgb

	core.bus_write(&bus, core.SVBK_ADDR, 4)
	core.bus_write(&bus, 0xD123, 0x42)
	testing.expectf(t, core.bus_read(&bus, 0xF123) == 0x42, "エコーRAM(E000-FDFF)はD000-DFFFの現在バンクを追従するはず")

	core.bus_write(&bus, 0xF123, 0x24) // エコー経由の書き込みも実バンクに反映される
	testing.expectf(t, core.bus_read(&bus, 0xD123) == 0x24, "エコー経由の書き込みが実アドレスに反映されるはず")

	// C000-CFFFのエコー(E000-EDFF相当)もバンク0固定で追従する。
	core.bus_write(&bus, 0xC050, 0x10)
	testing.expectf(t, core.bus_read(&bus, 0xE050) == 0x10, "C000側のエコーはバンク0固定のはず")
}

@(test)
test_svbk_ignored_in_dmg_mode :: proc(t: ^testing.T) {
	bus: core.Bus
	bus.mode = .Dmg

	core.bus_write(&bus, 0xD000, 0xAB)
	core.bus_write(&bus, core.SVBK_ADDR, 5) // DMGモードでは無視されるはず
	got := core.bus_read(&bus, 0xD000)
	testing.expectf(t, got == 0xAB, "DMGモードではSVBK書き込みが無視されるはず, got=%02X", got)
	testing.expectf(t, core.bus_read(&bus, core.SVBK_ADDR) == 0xFF, "DMGモードのSVBK読み出しは未実装レジスタ扱いで0xFFのはず")
}
