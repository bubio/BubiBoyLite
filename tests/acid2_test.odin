package tests

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:testing"
import core "bbl:core"

// dmg-acid2 のフレームバッファハッシュ判定(T3-8、testing.md「acid2 方式」)。
// ROM ファイルが無ければスキップ(./scripts/fetch_test_roms.sh 未取得のローカル環境を壊さない)。
//
// ハッシュの決め方(testing.md): 100フレーム実行後の framebuffer の FNV-1a 64bit ハッシュを
// 期待値と比較する。この期待値は、同じ手順(emulator_load_rom→emulator_run_frame x100→
// bus.ppu.framebuffer)で生成したフレームバッファをBMP化・PNG変換し、
// img/reference-dmg.png(mattcurrie/dmg-acid2 公式リポジトリ同梱)と目視比較して一致を
// 確認した上で固定した(顔の輪郭・目の三日月装飾・鼻・口・ロゴテキストすべて一致、崩れなし。
// 検証ログはphase-03-ppu.mdのT3-8参照)。

@(private = "file")
ACID2_ROM_PATH :: "tests/roms/acid2/dmg-acid2.gb"

// 2026-07-11 に目視確認のうえ固定(上記の手順で生成したBMPをPNG変換しReadツールで
// img/reference-dmg.pngと比較。以後はリグレッションガードとして機能する)。
@(private = "file")
ACID2_EXPECTED_HASH :: u64(0x17A0F9970AC4D084)

@(private = "file")
ACID2_FRAME_COUNT :: 100

@(test)
test_dmg_acid2_framebuffer_hash :: proc(t: ^testing.T) {
	if !os.exists(ACID2_ROM_PATH) {
		fmt.printfln(
			"acid2_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			ACID2_ROM_PATH,
		)
		return
	}

	data, err := os.read_entire_file(ACID2_ROM_PATH, context.allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("acid2_test: ROM を読み込めません: %v", err))
	}
	defer delete(data)

	emu: core.Emulator
	loaded := core.emulator_load_rom(&emu, data)
	testing.expectf(t, loaded, "acid2_test: ROM のロードに失敗しました: %s", ACID2_ROM_PATH)
	if !loaded {
		return
	}

	for _ in 0 ..< ACID2_FRAME_COUNT {
		core.emulator_run_frame(&emu)
	}

	framebuffer_bytes := mem.byte_slice(&emu.bus.ppu.framebuffer, size_of(emu.bus.ppu.framebuffer))
	got_hash := hash.fnv64a(framebuffer_bytes)

	testing.expectf(
		t,
		got_hash == ACID2_EXPECTED_HASH,
		"acid2_test: フレームバッファハッシュ不一致: got=0x%016X expected=0x%016X(PPU描画にリグレッションの可能性)",
		got_hash,
		ACID2_EXPECTED_HASH,
	)
}

// cgb-acid2(T6-8)のフレームバッファハッシュ判定。手順はdmg-acid2と同じ(testing.md「acid2 方式」)。
// 期待値の決め方: 一時ツール(scratchpad、リポジトリ非収録)でこのテストと全く同じ手順
// (emulator_load_rom→emulator_run_frame x100→bus.ppu.framebuffer)でBMPを生成し、
// mattcurrie/cgb-acid2 公式リポジトリ同梱の img/reference.png(reference-cgb.pngとして
// tests/roms/acid2/に取得済み)とPythonのPillowでピクセル単位比較(diff pixels: 0/23040、
// maxdiff: 0)、さらにReadツールで両画像を目視確認して完全一致を確認した
// (顔の輪郭・目のハイライト・眉のカーブ・鼻・口・"HELLO WORLD!"の文字色・ロゴテキストすべて
// 一致、崩れなし)。そのときのハッシュをここに固定する(以後はリグレッションガードとして機能する)。

@(private = "file")
CGB_ACID2_ROM_PATH :: "tests/roms/acid2/cgb-acid2.gbc"

// 2026-07-12 に目視確認のうえ固定(上記の手順で生成したBMPをPillowでピクセル差分0を確認、
// さらにReadツールでreference-cgb.pngと目視比較。以後はリグレッションガードとして機能する)。
@(private = "file")
CGB_ACID2_EXPECTED_HASH :: u64(0x8C0A422078D38470)

@(private = "file")
CGB_ACID2_FRAME_COUNT :: 100

@(test)
test_cgb_acid2_framebuffer_hash :: proc(t: ^testing.T) {
	if !os.exists(CGB_ACID2_ROM_PATH) {
		fmt.printfln(
			"acid2_test: ROM 未取得のためスキップ: %s (./scripts/fetch_test_roms.sh を実行してください)",
			CGB_ACID2_ROM_PATH,
		)
		return
	}

	data, err := os.read_entire_file(CGB_ACID2_ROM_PATH, context.allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("acid2_test: ROM を読み込めません: %v", err))
	}
	defer delete(data)

	emu := new(core.Emulator)
	defer free(emu)
	defer core.bus_destroy(&emu.bus)
	loaded := core.emulator_load_rom(emu, data)
	testing.expectf(t, loaded, "acid2_test: ROM のロードに失敗しました: %s", CGB_ACID2_ROM_PATH)
	if !loaded {
		return
	}
	testing.expectf(t, emu.bus.mode == .Cgb, "acid2_test: cgb-acid2.gbc は Cgb モードで起動するはず(ヘッダ0xC0)")

	for _ in 0 ..< CGB_ACID2_FRAME_COUNT {
		core.emulator_run_frame(emu)
	}

	framebuffer_bytes := mem.byte_slice(&emu.bus.ppu.framebuffer, size_of(emu.bus.ppu.framebuffer))
	got_hash := hash.fnv64a(framebuffer_bytes)

	testing.expectf(
		t,
		got_hash == CGB_ACID2_EXPECTED_HASH,
		"acid2_test: cgb-acid2 フレームバッファハッシュ不一致: got=0x%016X expected=0x%016X(CGB PPU描画にリグレッションの可能性)",
		got_hash,
		CGB_ACID2_EXPECTED_HASH,
	)
}
