package core

// ハードウェア定数。BubiBoyLite の全モジュールが参照する唯一の定義源。

SCREEN_WIDTH :: 160
SCREEN_HEIGHT :: 144

CPU_HZ :: 4194304
CYCLES_PER_FRAME :: 70224

// Gb_Mode はエミュレート対象のハードウェアモード(T6-1)。DMG 互換モード(ヘッダ0x0143=0x80の
// ROMがCGB機能を使わない場合)は内部的には単に Cgb のまま(実行時にゲームが CGB 機能を
// 使わないだけ)なので、内部モードは2値で足りる。ただし「CGBハードでDMGソフト」を動かす際の
// 互換パレット適用はT6-8で別途扱う(cgb_flag が Dmg_Only のときに固定グレーパレットを
// パレットRAMへ書く、という形でPpuの色決定ロジック自体は変えない)。
Gb_Mode :: enum {
	Dmg,
	Cgb,
}

// gb_mode_from_cgb_flag はカートリッジヘッダのCGBフラグ(0x0143、cartridge.odin)から
// 実行モードを決める。0x80(Cgb_Enhanced)・0xC0(Cgb_Only)はどちらもCgbモードで起動する
// (拡張子ではなくヘッダのみで判定する。落とし穴として phase-06-cgb.md に明記)。
gb_mode_from_cgb_flag :: proc(flag: Cgb_Flag) -> Gb_Mode {
	return .Dmg if flag == .Dmg_Only else .Cgb
}
