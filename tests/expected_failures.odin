package tests

// まだ安定して PASS しないことが分かっているテスト ROM(Blargg/Mooneye 共用)の許可リスト
// (T1-8/T1-9/T2-6)。testing.md「許可リスト方式」: ここに載っている ROM は FAIL/TIMEOUT でも
// テスト全体は成功扱いになる。フェーズが進んで通るようになったらエントリを削除すること
// (削除を忘れると blargg_test.odin/mooneye_test.odin が「予期せぬ PASS」として検出し FAIL する)。
//
// T2-2(IME 1命令遅延・HALT起床・HALTバグ)完了時点で cpu_instrs/02-interrupts、
// mooneye halt_ime1_timing・ei_timing・rapid_di_ei が PASS するようになったため除外済み。
// cpu_instrs 統合版(cpu_instrs.gb)は MBC1 が必要なためフェーズ4まで別途許可リストに残す
// (現時点では @(test) 化していないためここには含めない)。
//
// T2-3(DIV/TIMA落下エッジ実装)完了時点で timer/ 13本中 div_write・tim00・tim01_div_trigger・
// tim10・tim10_div_trigger・tim11・tima_reload・tima_write_reloading・tma_write_reloadingが
// PASSするようになったため除外済み。rapid_toggle はまだ通らないため残す(要デバッグ、T2-7で再挑戦)。
//
// T2-5(OAM DMA実装)完了時点で以下がフェーズ3送りと確定した。バイナリを逆アセンブルして
// 原因を特定済み: 該当ROM(2024-02リリースのc-sp/game-boy-test-romsに同梱のビルド)は
// 冒頭で `disable_ppu_safe`(LCDC bit7=1ならLYが$90になるまで**タイムアウト無しで**ポーリング
// し続ける版)を呼んでいる。LCDC/LYはフェーズ3までどちらも未実装の固定0xFFのため、
// この時点で無限ループしテスト本体(ie_push本来のIE破壊ロジックや、DMA転送内容の検証)へ
// 到達すらできない。ie_push のディスパッチ本体は tests/interrupt_test.odin の単体テストで
// 別途 mooneye ie_push.s のRound1/Round3を手でトレースして検証済み。
//
// T3-1(LCDレジスタ群実装)完了時点で timer/tim00_div_trigger・tim01_div_trigger・
// tim10_div_trigger・tim11_div_trigger の4本が新たにここへ加わった。原因は上記と同根:
// これらのROMも起動直後に`disable_ppu_safe`(LYが$90になるまでポーリング)を呼んでいる。
// T3-1以前はLCDC/STAT/LYが未実装で固定0xFFを返していたため、たまたま「画面はもう無効」
// 「LYはもう$90以上」に見えるビット列でポーリングを素通りしていた(偶然の誤PASS)。
// T3-1でレジスタを正式実装した結果、LCDC=0x91(画面ON)・LY=0(PPU未稼働で変化しない)という
// 正しい初期値が読めるようになったため、本来の仕様どおりLY到達を待って無限ループするように
// なった(トレースで確認済み: PC が 0x4A4F-0x4A53 のポーリングループで停止し続ける)。
// T3-2(モードタイミング・STAT blocking実装)完了時点で ppu_tick を bus_tick に接続し LY が
// 実際に進むようになったため、上記の disable_ppu_safe 待ちが解消し以下が PASS するようになった
// (許可リストから除外済み): mooneye/acceptance/interrupts/ie_push、
// mooneye/acceptance/oam_dma/basic、mooneye/acceptance/oam_dma_start、
// timer/tim00_div_trigger、timer/tim01_div_trigger、timer/tim10_div_trigger、
// timer/tim11_div_trigger。一方 halt_ime0_ei・halt_ime0_nointr_timing・oam_dma/reg_read は
// T3-2後もまだ通らない(前者2つはTIMEOUT、reg_readはFAIL)。個別の原因はT3-8等で再調査する。
//
// T3-8で halt_ime0_ei・halt_ime0_nointr_timing の原因を特定し解消した(許可リストから除外済み)。
// 原因: これらのROMはLCDをROM側で明示的に有効化せず、DMGブートROM完了直後の既定状態で
// 既にLCDC=0x91(画面ON)であることを前提にVBlank割り込みを待っていた。本プロジェクトは実BIOSを
// 読み込まない方針(CLAUDE.md)のため起動直後のレジスタ状態を直接セットする必要があるが、
// T3-1時点ではCPUレジスタのみ実装しIOレジスタは全てゼロ初期化のままだった(LCDC=0x00=画面OFF)。
// そのためLYが一度も進まずVBlank割り込みが永遠に来ずHALTしたまま止まっていた
// (トレースで確認: pc=0x0160でhalted=true, LCDC=0x00のまま12M T-cycle経過)。
// `ppu_power_on`(ppu.odin)を追加しDMG post-boot register state(Pan Docs "Power Up Sequence"、
// BubiBoy Bus.fs postBootIoの実測値: LCDC=0x91, STAT=0x80, BGP=0xFC, OBP0=OBP1=0xFF)を
// `bus_power_on`経由でemulator_load_rom/rom_runnerの両方から呼ぶようにした結果、両ROMともPASSに
// 転じた。dmg-acid2は自ROM内でLCDC等を明示的に再設定するため、この変更でacid2のハッシュは
// 変化しないことを確認済み(同一の期待値のまま再テストしてPASS)。
// oam_dma/reg_read はこの変更後も引き続きFAIL(disable_ppu_safe待ちは解消したが、DMA転送中の
// レジスタ読み出し値が期待と異なる。フェーズ4以降で再調査)。

expected_failures := [?]string {
	// 未解決(T2-7で深く調査したが解決できず。PPU非依存でありフェーズ3送りにできる
	// 正当な理由がないため、この1件が原因でフェーズ2のマイルストーンは🟢にできていない):
	// TACへの書き込みでの落下エッジ検出(Pan Docs "Timer Obscure Behaviour")は実装済みで
	// timer/ 13本中12本はこれでPASSする。rapid_toggleは実測でB=C=D=E=H=L=0x42(FAIL)。
	// 調査結果: タイマー割り込み自体は発生している。ディスパッチ直前にBCを直接観測すると
	// BC=$FFD8(期待値$FFD9より1少ない=ループが1回多く回ってから割り込みが認識されている)。
	// 独立に書いたT-cycle精度のPythonシミュレータ(命令ごとの正確なサイクル数からdiv/edge
	// を再現)でこのROMの39回のループ全て(TAC書き込み78回ぶんのold_signal/new_signal/fired
	// を1件ずつ)を突き合わせたところ、Odin実装と完全一致(diff無し)。オーバーフロー自体は
	// Pan Docsの実測サンプル表(TIMA overflow worked example、SYS=2B..31)の列アラインメントを
	// 再確認し、「エッジ検出→TIMA=$00が見えるまで1 M-cycle→IF確定まで更に1 M-cycle」という
	// 2段階の遅延も自実装と一致することを確認済み。それでもBCが1ずれる原因は、割り込み確定
	// (IF bit2 セット)が DEC BC の内部サイクル中に完了するため、DEC BC自体は(命令境界でしか
	// 割り込みを認識しない通常のSM83モデルでは)最後まで実行されてしまう点にある。これが
	// 実機の挙動と一致するのか、DEC BCのような2 M-cycle命令に限り実機がM-cycle粒度で割り込みを
	// 認識する特例があるのかを、Pan Docsの記述だけでは判別できなかった(要: 実機トレース or
	// 既知の高精度エミュレータとの突き合わせ)。追加調査で「エッジ→TIMA=$00可視化にもう1
	// M-cycleコミット遅延が抜けているのでは」という仮説も検討したが、
	// mooneye/acceptance/timer/tima_reload.s のコメント("no additional 4 cycle delay")と
	// 同ROMが実際にPASSしていることから棄却済み。詳細な調査ログは
	// docs/dev/phases/phase-02-timing.md の T2-7 検証ログを参照。次セッションでの
	// 再挑戦時はそこから始めること。
	"mooneye/acceptance/timer/rapid_toggle",
	// oam_dma/reg_read はdisable_ppu_safe待ちは解消したが、DMA転送中のレジスタ読み出し値が
	// 期待と異なりFAILのまま(T3-2完了時点で判明、T3-8でも未解決。フェーズ4以降で再調査)。
	// 2026-07-16: この根本原因(bus_readのdma_active競合モデルが実機の粒度と不一致)が
	// 市販GBCゲームの実プレイでクラッシュ(無限RST 38ループ→スタック破壊)として実際に
	// 顕在化することを確認した。詳細はdocs/dev/phases/phase-02-timing.md T2-7検証ログ
	// (2026-07-16追記分)を参照。
	"mooneye/acceptance/oam_dma/reg_read",
	// T5-7: dmg_sound 09/10/12(ch3動作中のwave RAMアクセス制限)は、T5-3の時点では
	// 未実装なので許可リスト入りを想定していたが、実際にT5-7でROMを取得して実行したところ
	// 3本ともPASSした(wave RAMアクセスを常時無制限に許可する簡易実装のままで、この3本の
	// 検査内容には抵触しなかった)。よってここには載せない(削除済み)。
}

is_expected_failure :: proc(name: string) -> bool {
	for entry in expected_failures {
		if entry == name {
			return true
		}
	}
	return false
}
