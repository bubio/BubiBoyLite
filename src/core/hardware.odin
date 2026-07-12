package core

// ハードウェア定数。BubiBoyLite の全モジュールが参照する唯一の定義源。

SCREEN_WIDTH :: 160
SCREEN_HEIGHT :: 144

CPU_HZ :: 4194304
CYCLES_PER_FRAME :: 70224

// Gb_Mode はエミュレート対象のハードウェアモード(T6-1)。ヘッダのCGBフラグが0x80/0xC0の
// ROMはCgb、それ以外(Dmg_Only)はDmgで起動する。内部モードはこの2値で足りる。
//
// T6-8の方針(DMG互換パレット): 実 BIOS(ブートROM)を読み込まない方針(BluePrint/CLAUDE.md)
// のため、本物のCGBがブートROM内でタイトルハッシュを見て互換パレットを選ぶ処理は実装しない。
// 代わりに、DMGソフト(cgb_flag=Dmg_Only)は「CGBハードでDMGソフトを互換パレットで動かす」
// 特別なモードを持たず、単純にDmgモードのまま起動し続ける設計にした
// (gb_mode_from_cgb_flagがDmg_Onlyのときに .Dmg を返すことがそのまま実装であり、
// これ以上の分岐は存在しない)。つまりDMGソフトは実質フェーズ3までのDMGモード
// (BGP/OBP0/OBP1によるグレー4階調、ppu.odinのdmg_shade)で動き続け、CGBパレットRAM
// (T6-4、bg_palette_ram/obj_palette_ram)には一切触れない。「グレー4階調を固定パレットとして
// 設定する」という要件は、この経路がそもそもBGP/OBPのグレー4階調(dmg_shade)を使い続けることで
// 自動的に満たされる(architecture.md「core と app の分離」・「スコープ外」節の実BIOS非対応方針に
// 準拠した最小実装)。
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
