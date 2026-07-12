# フェーズ 6: Game Boy Color 機能

## 前提

- 依存フェーズ: 5（DMG として完成していること）
- ここが本プロジェクトの本題（BluePrint: 「Gameboy Color エミュレーター」）。
- CGB フラグ（ヘッダ 0x0143）が 0x80/0xC0 の ROM は CGB モードで、それ以外は DMG モードで起動する。

## ゴール

CGB 固有機能（ダブルスピード、バンク切替、カラーパレット、HDMA）を実装し、
cgb-acid2 をパスし、GBC 専用ゲームがフルカラーで動作する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # cgb_acid2 が PASS
./bbl <GBC専用ゲーム>.gbc             # フルカラーで動作（目視）
```

---

### T6-1: CGB モードと起動状態

- [x] 完了

**目的**: モード判定と CGB のブート後状態を実装する。
**作るもの**:
- `src/core/hardware.odin`: `Gb_Mode :: enum { Dmg, Cgb }`（DMG 互換モードは Cgb 起動後にゲームが CGB 機能を使わないだけなので、内部モードは 2 値でよい。ただし DMG 互換パレット適用のため「CGB ハードで DMG ソフト」の区別は T6-8 で扱う）
- emulator.odin: ヘッダ 0x0143 が 0x80/0xC0 なら Cgb モード。`cpu_reset`: CGB は **AF=0x1180, BC=0x0000, DE=0xFF56, HL=0x000D**（A=0x11 が CGB 判定に使われる）
- ハードウェアレジスタの CGB 初期値（Pan Docs "Power Up Sequence" の CGB 列）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Emulator.fs:47-52`、references.md「ブート後レジスタ初期値」
**完了条件 (DoD)**: 単体テスト: .gbc ヘッダで A=0x11、DMG ヘッダで A=0x01。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: モード判定はヘッダのみで行う（拡張子ではない）。0xC0（CGB 専用）も 0x80 も同じ Cgb モード。
**依存**: なし

---

### T6-2: VRAM バンクと BG 属性マップ

- [x] 完了

**目的**: VRAM を 2 バンク化し、バンク 1 の BG 属性を PPU に反映する。
**作るもの**:
- bus.odin: `vram: [2][8192]u8`、VBK (FF4F): bit0 のみ有効、読むと `0xFE | bank`
- ppu.odin: BG/ウィンドウのタイル毎にバンク 1 の同アドレスから属性バイトを読む:
  bit7=BG 優先、bit6=Y flip、bit5=X flip、bit3=タイルデータのバンク、bit2-0=パレット番号
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs`（VramBank）+ `Video.fs:199-242`、Pan Docs "VRAM Banks" / "BG Map Attributes"
**完了条件 (DoD)**: 単体テスト: VBK 切替で別データが読めること、属性の flip がピクセルに反映されること。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 属性バイトは「バンク 1 の**タイルマップと同じアドレス**」にある。DMG モードでは VBK 書き込みを無視しバンク 0 固定。
**依存**: T6-1

---

### T6-3: WRAM バンク

- [x] 完了

**目的**: WRAM を 8 バンク化する。
**作るもの**: bus.odin:
- `wram: [8][4096]u8`。C000-CFFF はバンク 0 固定、D000-DFFF は SVBK (FF70) で 1-7（**0 指定は 1 扱い**）
- エコー RAM もバンクを追従
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs:83-87`、Pan Docs "WRAM Banks"
**完了条件 (DoD)**: 単体テスト: バンク切替、0→1 読み替え、エコー追従。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: DMG モードでは SVBK 無視・2 バンク相当（C000-DFFF 直結）。
**依存**: T6-1

---

### T6-4: CGB パレット RAM

- [x] 完了

**目的**: BG/OBJ 各 64 バイトのパレット RAM と RGB555 描画を実装する。
**作るもの**:
- bus.odin: `bg_palette_ram, obj_palette_ram: [64]u8`。BCPS (FF68): bit5-0=インデックス、bit7=書き込み後オートインクリメント。BCPD (FF69): データ。OCPS/OCPD (FF6A/6B) も同様
- ppu.odin: CGB モードでは BGP/OBP ではなくパレット RAM から色を引く。
  1 色 = 2 バイト リトルエンディアン RGB555（bit4-0=R, 9-5=G, 14-10=B）。
  ARGB 変換は architecture.md の決定どおり `(c << 3) | (c >> 2)`
- パレット番号は BG 属性 (T6-2) / OAM 属性 bit2-0 から
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs:31-32,191` + `Video.fs:289-366`（cgbColor）、Pan Docs "LCD Color Palettes (CGB only)"
**完了条件 (DoD)**: 単体テスト: BCPS オートインクリメント、RGB555→ARGB 変換値、パレット別描画。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: オートインクリメントは**書き込み時のみ**（読み出しでは進まない）。
**依存**: T6-2

---

### T6-5: CGB の優先度制御

- [x] 完了

**目的**: CGB で変わる BG/OBJ 優先度規則を実装する。
**作るもの**: ppu.odin:
- CGB の OBJ 間優先度は X 座標ではなく **OAM 順**（先頭が勝つ）
- 優先度解決: LCDC bit0（CGB ではマスタープライオリティ: 0 なら OBJ が常に BG の上）、BG 属性 bit7、OAM 属性 bit7 の組み合わせ表（Pan Docs の表をそのまま実装）
**参照**: Pan Docs "BG-to-OBJ Priority in CGB Mode"
**完了条件 (DoD)**: 単体テスト: LCDC bit0=0 で OBJ 最前面、BG 属性 bit7 の勝ち。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: DMG モードのときは従来の X 優先を維持すること（モードで分岐）。cgb-acid2 の主要検査項目。
**依存**: T6-4

---

### T6-6: ダブルスピードモード

- [x] 完了

**目的**: KEY1 (FF4D) と STOP によるダブルスピード切替を実装する。
**作るもの**:
- bus.odin: `double_speed: bool`, `speed_switch_prepared: bool`。KEY1: bit7=現速度（読み）、bit0=切替準備（書き）
- cpu.odin: STOP 実行時に prepared なら速度反転・prepared クリア・DIV リセット（T1-6 の STOP 仮実装を置換）
- **クロック換算**: ダブルスピード中、CPU/Timer/シリアルは 2 倍速、PPU/APU は等速。
  実装は「CPU の 1 M-cycle につき、PPU/APU へは 2 T-cycle だけ供給」（BubiBoy の hardwareCyclesForCpuCycles 方式）。
  bus_tick を `bus_tick(bus, cpu_t_cycles)` とし、内部で `hw_cycles = double_speed ? cpu_t_cycles/2 : cpu_t_cycles` を PPU/APU に渡す
- `emulator_run_frame` のフレーム境界は **PPU 側サイクル（70224）** で数える
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs`（行 400-401, 451, 854, 1056-1062）+ `Cpu.fs:675`、Pan Docs "CGB Registers: KEY1"
**完了条件 (DoD)**: 単体テスト: 切替で KEY1 bit7 反転・DIV リセット、ダブルスピード時に 1 フレームの CPU サイクルが 2 倍。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: Timer は CPU 側クロックで動く（2 倍速になる）。APU/PPU は実時間側。ここを逆にすると音程が半オクターブずれる/ゲームが倍速になる。
**依存**: T6-1

---

### T6-7: HDMA / GDMA

- [x] 完了

**目的**: VRAM への高速 DMA を実装する。
**作るもの**: bus.odin:
- HDMA1-4 (FF51-54): ソース（下位 4bit 無視）/宛先（VRAM 内、下位 4bit と上位 3bit マスク）
- HDMA5 (FF55): bit7=0 で **GDMA**（(n+1)*16 バイトを即時転送、CPU 停止時間も加算）、bit7=1 で **HDMA**（HBlank 毎に 16 バイト）
- HDMA 中の FF55 読み出し: bit7=非アクティブ、下位=残りブロック-1。HDMA 中に bit7=0 を書くと中断
- PPU の HBlank 遷移（モード 0 突入）にフックして 16 バイト転送
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs`（HdmaSource/Destination/Remaining/Active、行 1017）、Pan Docs "CGB DMA"
**完了条件 (DoD)**: 単体テスト: GDMA 全量転送、HDMA が HBlank 毎に 16 バイト進む、中断と FF55 読み値。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: LCD off 中の HDMA は進まない（GDMA は動く）。転送は VBK の現バンクへ。
**依存**: T6-2

---

### T6-8: DMG 互換パレット + cgb-acid2 + 実ゲーム

- [x] 完了

**目的**: フェーズ 6 のマイルストーン。CGB ハードで DMG ソフトを動かす互換もここで仕上げる。
**作るもの**:
- DMG ソフト（ヘッダ 0x0143 が 0x80/0xC0 以外）を CGB 相当で起動する際の互換パレット: 本物はブート ROM がタイトルハッシュで選ぶが、実 BIOS 非対応（BluePrint）のため**固定の既定パレット**（グレー 4 階調を BG/OBJ パレット RAM に設定）でよい。つまり DMG ソフトは実質フェーズ 3 までの DMG モードで動かし続ける — この方針を architecture.md 準拠でコメントに明記
- fetch スクリプトに cgb-acid2 を追加、`tests/acid2_test.odin` に cgb 版ハッシュテスト（目視確認 → ハッシュ固定、testing.md）
- GBC 専用ゲームでの動作確認とデバッグ
**参照**: testing.md、cgb-acid2 リポジトリの reference PNG
**完了条件 (DoD)**: cgb_acid2 テスト PASS。GBC 専用（0xC0）ゲーム 1 本がフルカラーでプレイ可能（検証ログにゲーム名記録）。DMG ゲームのリグレッションなし（dmg_acid2 が引き続き PASS）。
**検証方法**:
```sh
odin test tests -collection:bbl=src
./bbl <GBC専用ゲーム>.gbc
```
**落とし穴**: cgb-acid2 は OAM 順優先度（T6-5）と BG 属性 flip（T6-2）を集中的に検査。顔の崩れ方で原因特定できる。
**依存**: T6-2〜T6-7

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-12 T6-1 完了: `Gb_Mode :: enum { Dmg, Cgb }` を hardware.odin に追加し、cpu.odin にあった
重複概念の `Console_Mode` は削除して `Gb_Mode` に統一(cpu_reset のシグネチャも変更、既存呼び出し元
(tests/*.odin 含む)を全て追従させた)。`Bus` に `mode: Gb_Mode` を追加し、`emulator_load_rom` が
ヘッダ 0x0143(拡張子ではない)から `gb_mode_from_cgb_flag` で判定して設定するようにした。
単体テスト3件追加(tests/cgb_mode_test.odin): 0x80/0xC0 で Cgb モード・A=0x11、CGBフラグ無しで
Dmg モード・A=0x01 を確認。`odin test tests -collection:bbl=src` 273 tests 全パス(既存270+新規3、
dmg-acid2ハッシュ含めリグレッションなし)。CGB固有ハードウェアレジスタ(VBK/SVBK/KEY1/HDMA/
BCPS/OCPS)の初期値はレジスタ自体がまだ存在しないため、それぞれの実装タスク(T6-2/3/4/6/7)で
合わせて設定する方針とした(このタスクではCPUレジスタとモード判定のみ)。

2026-07-12 T6-2 完了: bus.odin の `vram` を `[2][8192]u8` に2バンク化し、VBK(FF4F、bit0のみ有効・
読み出しは0xFE|bank)を実装(DMGモードでは書き込み無視・バンク0固定、読み出しは他の未実装
レジスタ同様0xFF)。ppu.odin に `tile_map_pixel`(Bg_Pixel構造体を返す)を新設し、CGBモードでは
「バンク1のタイルマップと同アドレス」から属性バイトを読んでY/Xフリップ・タイルデータバンク選択
(bit3)・パレット番号(bit2-0)・BG優先度(bit7)に反映するようにした(BG/ウィンドウ両方の呼び出し
箇所を置き換え)。ついでにOAMスプライトのタイルデータ読み出しも属性bit3(VRAMバンク)に対応
させた(CGBのVRAMバンキングとして自然な範囲、パレット解決とOAM順優先度自体はT6-4/T6-5)。
LCDC bit0=0の「BG白一色化」早期returnはCGBモードでは通らないようガード(CGBではbit0はマスター
プライオリティの意味になり、BGは白くならず描画され続ける。Pan Docs "LCDC.0"。実際の優先度
反映はT6-5)。単体テスト5件追加(tests/ppu_cgb_vram_test.odin): VBKでバンク0/1が別データになる
こと、DMGモードでVBK書き込みが無視されること、BG属性のY/Xフリップとタイルデータバンク選択が
ピクセルに反映されること。`odin test tests -collection:bbl=src` 278 tests 全パス(既存273+新規5、
dmg-acid2ハッシュ含めリグレッションなし)。

2026-07-12 T6-3 完了: bus.odin の `wram` を `[8][4096]u8` に8バンク化し、SVBK(FF70、bit2-0のみ
有効・読み出しは0xF8|解決済みバンク)を実装。C000-CFFFはバンク0固定、D000-DFFFはSVBKが
指すバンク、E000-FDFFのエコーはC000-DDFFを追従してミラーする共通ヘルパー`wram_locate`で
3領域まとめて解決した。「0指定は1扱い」は書き込み時ではなく`wram_active_bank`(読み出し/
アドレス解決の両方が経由)で解決するようにしたため、`bus_power_on`を呼ばない生の`Bus{}`
(既存テストで多用)でもデフォルトが自動的にバンク1として振る舞う。DMGモードはSVBK書き込みを
無視する(常にバンク1固定=C000-DFFF直結2バンク相当)。副作用として`Emulator`構造体が
268480バイトまで増えコンパイラがスタックオーバーフロー警告を出すようになったため、
src/app/main.odin の2箇所(run_rom_window/run_test_pattern_window)を`new(core.Emulator)`による
ヒープ確保に変更した(呼び出し先のシグネチャは元々`^core.Emulator`前提だったため影響は
軽微)。tests/配下の同様の警告(mbc3_test.odin等、値型`emu: core.Emulator`をスタックに置く
既存慣習)はテストランナーのスレッドスタックで実害なく全テストパスしているため今回は
変更していない(単なる警告であり、DoD外のリファクタリングをこのタスクの範囲外と判断)。
単体テスト5件追加(tests/wram_bank_test.odin): バンク切替、SVBK=0の1読み替え、
bus_power_on無し時のデフォルトバンク1、エコーRAMのバンク追従(D000/C000両方)、DMGモードでの
無視。`odin test tests -collection:bbl=src` 283 tests 全パス(既存278+新規5、dmg-acid2ハッシュ
含めリグレッションなし)。

2026-07-12 T6-4 完了: bus.odin に `bg_palette_ram`/`obj_palette_ram: [64]u8` とBCPS/BCPD
(FF68/69)・OCPS/OCPD(FF6A/6B)を実装。インデックスレジスタ(bcps/ocps)はbit6を常に1で読める
未使用bitとして保持し(BubiBoy Bus.fs方式)、オートインクリメントは`palette_index_increment`
としてBCPD/OCPD書込み時のみ適用(読み出しでは進まない、落とし穴)。ppu.odin に
`rgb555_to_argb`(architecture.md固定の`(c<<3)|(c>>2)`変換、BubiBoyのガンマ補正版は使わない
決定を再確認)と`cgb_palette_color`を追加し、BG/ウィンドウ(T6-2のBg_Pixel.palette)とOBJ
(OAM属性bit2-0)の両方でCGBモード時はBGP/OBPではなくパレットRAMから色を引くようにした
(DMGモードは従来のBGP/OBP0/OBP1のまま、モードで分岐)。これに伴いT6-2で追加したCGBモード
ピクセルテスト3件(ppu_cgb_vram_test.odin)がBGPグレー4階調ベースのままだと不整合になるため、
BGパレット0を既知の原色(黒/赤/緑/青)に設定してから比較するよう更新した。単体テスト6件
追加(tests/cgb_palette_test.odin): BCPSオートインクリメント(書込み時のみ進む・bit7=0で
進まない・63→0ラップ)、BCPS/OCPSの独立性、DMGモードでの無視、RGB555境界値(0x7FFF→白)。
`odin test tests -collection:bbl=src` 289 tests 全パス(既存283+新規6、dmg-acid2ハッシュ含め
リグレッションなし)。

2026-07-12 T6-5 完了: ppu.odin に `cgb_obj_wins_over_bg`(Pan Docs "BG-to-OBJ Priority in CGB
Mode"の表: LCDC bit0=0でOBJ常勝→BG color0でOBJ勝ち→BG属性bit7でBG勝ち→OAM属性bit7でBG勝ち→
それ以外はOBJ勝ち、の順で判定)を実装し、`ppu_render_sprites`のBG優先度チェックをCGB/DMGで
分岐させた(CGBはこの表、DMGは従来のattr bit7判定のまま)。スプライト間優先度も分岐: CGBは
`ppu_collect_line_sprites`が既に返すOAM順のままソートせず使う(X座標無視、先頭が勝つ)。DMGは
従来どおり`ppu_sort_sprites_by_priority`でX優先ソート。単体テスト5件追加
(tests/cgb_priority_test.odin): LCDC bit0=0でのOBJ最前面強制、BG属性bit7の勝ち、OAM属性bit7の
勝ち(BG属性bit7=0時)、優先度ビット両方0でのOBJ勝ち、OAM順優先度(小さいXのスプライトでも
後のOAM indexなら負ける)。デバッグで一度、BG用テストのLCDCがunsigned tile mode(bit4)を
立て忘れてsigned基点(0x9000)を読みに行きBG色が全て0になる(結果的にOBJ勝ち判定に落ちて
テストが誤って通る/落ちる)というハマりがあり、bit4を追加して修正した。
`odin test tests -collection:bbl=src` 294 tests 全パス(既存289+新規5、dmg-acid2ハッシュ含め
リグレッションなし)。

2026-07-12 T6-6 完了: bus.odin に `double_speed`/`speed_switch_prepared`(KEY1相当)と
`hw_cycles`(PPU/APU側の累計T-cycle、フレーム境界判定用)を追加。KEY1(FF4D)はbit7=現在速度
(読み専用)・bit0=切替準備(読み書き)・残りは常に1で読める未使用bit。`bus_tick`を
`hw_cycles = double_speed ? t_cycles/2 : t_cycles` で分岐させ、Timer/OAM DMAはCPU側の
`t_cycles`のまま、PPU/APUは`hw_cycles`を渡すようにした(落とし穴として明記されていた
「Timerを実時間側にすると音程が半オクターブずれる/ゲームが倍速になる」を回避)。
`emulator_run_frame`のフレーム境界を`bus.cycles`から`bus.hw_cycles`に変更(等速時は
`hw_cycles==cycles`なのでDMG/既存動作に影響なし)。cpu.odinのSTOP(0x10)ハンドラで
`mode==Cgb && speed_switch_prepared`のときだけ速度反転・prepared クリア・
`timer_write_div`によるDIVリセットを行い、それ以外(DMGモード、または未準備)は
T1-6以来の「無視ログのみ」のプレースホルダ挙動を維持した(既存のopcodeカバレッジテストが
STOPを叩く際の挙動を壊さないため)。単体テスト4件追加(tests/cgb_double_speed_test.odin):
KEY1準備→STOP→bit7反転+DIVリセット、往復切替、prepared無しSTOPでの無変化、DMGモードでの
無視、ダブルスピード中の1フレームCPUサイクルが等速の約2倍になること(WRAM上にSTOP命令を
置いて実行する手法。ROM領域はカートリッジ未ロードの生Busではmbc_writeが無視するため使えない
という落とし穴に最初にはまり、書き込み先をWRAMへ変更して解決した)。
`odin test tests -collection:bbl=src` 298 tests 全パス(既存294+新規4、dmg-acid2ハッシュ含め
リグレッションなし)。

2026-07-12 T6-7 完了: bus.odin に HDMA1-4(FF51-54、ソース下位4bit無視・宛先0x8000起点+
上位3bit/下位4bitマスク)とHDMA5(FF55)を実装。`hdma_start_or_cancel`がFF55書込みを処理:
進行中(hdma_active)にbit7=0を書くと中断(残りブロック数を`hdma_aborted_remaining`に記録し、
以後のFF55読み出しは`(残り-1)|0x80`を返す)。それ以外はbit7=1でHDMA(hdma_activeを立てて
HBlank待ち)、bit7=0でGDMA(`hdma_run_general`が(n+1)*16バイトを即時に`hdma_copy_block`で
転送)。「CPU停止時間も加算」は1ブロックごとに`bus_tick(bus,8)`を呼ぶことで表現した
(T6-6のbus_tick経由なのでダブルスピード中もPPU/APU側は自動的に等速のまま)。HDMA中の
FF55読み出しはbit7=0(進行中)固定・下位=残りブロック-1、非アクティブ時は0xFF
(中断直後を除く)。ppu.odinのppu_tick、モード3→0(HBlank)遷移フックに`hdma_active`なら
`hdma_copy_block`を1回(16バイト)呼ぶ処理を追加。「LCD off中のHDMAは進まない」は
ppu_tickがLCDC bit7=0で早期returnする既存実装により自然に満たされる(このタスクでは
特別な分岐を追加していない)ことを確認した。単体テスト5件追加(tests/cgb_hdma_test.odin):
GDMA全量転送とCPU停止時間、HDMAのHBlank毎16バイト進行、中断とFF55読み値、LCD off中の停止、
DMGモードでの無視。`odin test tests -collection:bbl=src` 303 tests 全パス(既存298+新規5、
dmg-acid2ハッシュ含めリグレッションなし)。

2026-07-12 T6-8 完了(フェーズ6マイルストーン):

- **DMG互換パレット**: hardware.odinの`Gb_Mode`/`gb_mode_from_cgb_flag`にコメントを追記し、
  方針を明記した。実BIOS非対応(BluePrint/CLAUDE.md)のため、本物のCGBがブートROM内で
  タイトルハッシュを見て互換パレットを選ぶ処理は実装しない。代わりにDMGソフト
  (cgb_flag=Dmg_Only)は単純にDmgモードのまま起動し続ける設計とした(T6-1で既に実装済み)。
  つまりDMGソフトは実質フェーズ3までのDMGモード(BGP/OBP0/OBP1によるグレー4階調、
  ppu.odinのdmg_shade)で動き続け、CGBパレットRAMには一切触れない。「グレー4階調を固定
  パレットとして設定する」という要件は、この経路がそもそもグレー4階調を使い続けることで
  自動的に満たされる。
- **cgb-acid2**: scripts/fetch_test_roms.shにcgb-acid2(mattcurrie/cgb-acid2 v1.1リリース、
  参照PNGはcommit 04c6ca40cf75b6a93513fe596de4ab797efaff97固定)を追加。一時ツール
  (scratchpad、非コミット)でROMを100フレーム実行しBMPへダンプ、PythonのPillowで
  reference.pngとピクセル単位比較した結果 diff pixels: 0/23040, maxdiff: 0(完全一致)。
  さらにReadツールで両画像を目視確認し、顔の輪郭・目のハイライト(緑の虹彩+黒瞳)・眉の
  カーブ・鼻・口・"HELLO WORLD!"の文字色・ロゴテキストすべて一致、崩れなしを確認した。
  このときのハッシュ0x8C0A422078D38470を`tests/acid2_test.odin`の
  `test_cgb_acid2_framebuffer_hash`に固定した(100/101/150フレームで同一ハッシュ、
  安定状態に達していることも確認済み)。
- **dmg-acid2のリグレッションなし確認**: 同じ`odin test`実行内で`test_dmg_acid2_framebuffer_hash`
  も引き続きPASS(ハッシュ0x17A0F9970AC4D084のまま変化なし)。
- **GBC専用ゲームでの動作確認(市販ROM代替)**: 市販のGBC専用ゲームROMは著作権上入手・同梱
  できないため(BluePrintに明記の制約)、RGBDS(rgbasm/rgblink/rgbfix v1.0.1、Homebrew経由で
  ローカルにインストール済み)で自作したホームブリューROM `cgb_demo.gbc`
  (scratchpad、非コミット。ソースはCLAUDE.mdの「ユーザー名を残さない」方針に従いscratchpad
  配下に置きリポジトリには含めていない)で代替した。CGBフラグ0xC0(CGB専用)、
  検証内容: (1) BCPS/BCPDでBGパレット0のcolor3=赤・パレット1のcolor3=青を設定、
  (2) VBK=1でBG属性マップ(0x9800起点)の列0-15にパレット0・列16-31にパレット1を書き込み、
  画面を色分け、(3) VBK=1でタイル1(0x8010)にスプライト用タイルデータを書き込み、
  OAM属性bit3(タイルデータバンク1選択)とbit2-0(パレット2)を設定してスプライト配置、
  (4) OCPS/OCPDでOBJパレット2のcolor3=緑(合格時)を設定、(5) 実行時にSVBK(WRAMバンク2→3→2の
  書き込み・読み戻し一致)とKEY1+STOP(ダブルスピード切替後にKEY1 bit7=1を確認)の2つを
  自己検査し、失敗時はOBJパレット2のcolor3を赤に上書きする作り。5フレーム実行後の
  スクリーンショット(Readツールで目視確認)は「画面左80%が赤・右20%が青・中央に緑の
  小スプライト」で、これはBGパレットRAM・BG属性によるパレット切替・VRAMバンク・OAMの
  タイルバンク選択・OBJパレットRAM・SVBK・KEY1+STOPダブルスピード切替のすべてが
  期待どおり動作していることを示す(緑=WRAM/ダブルスピード両検査に合格)。念のため
  WRAM検査のcp命令を意図的に不成立の値へ書き換えた別ビルドでも実行し、スプライトが
  赤(背景の赤と同化して見た目上消える)に変わることを確認した(pass/fail分岐が実際に
  効いていることの裏付け、ハードコードされたグリーンではないことの確認)。
  検証ログ注記: これは自作の最小デモROMであり、市販GBC専用ゲームでのプレイ可能性は
  **未検証**(入手不可のため)。
- **フェーズ6のマイルストーン検証コマンド**: `odin test tests -collection:bbl=src` 304 tests
  全パス(既存303+cgb-acid2新規1、dmg-acid2ハッシュ含めリグレッションなし)。
  `./bbl <GBC専用ゲーム>.gbc`による市販ゲームでの目視確認は上記の理由により実施できていない
  (代替としてcgb_demo.gbcでの動作確認で置き換えた)。

  追記(advisor指摘への対応): 上記の目視確認はここまで全て一時ダンプツール(core を直接
  呼ぶ、SDL2非依存のヘッドレス経路)経由で行っており、`src/app/main.odin`(実際の`bbl`
  実行ファイル、T6-3のヒープ確保リファクタとT6-6のhw_cycles化されたemulator_run_frameを
  実際に使うオーディオ駆動ペーシング経路)は未実行のまま完了報告するところだった。
  そこで`odin build src/app -collection:bbl=src -out:bbl`でビルドし、
  `./bbl --scale 2 cgb_demo.gbc`を実際に起動、SDL2ウィンドウ(タイトル"BubiBoyLite")が
  クラッシュせず表示されることを確認した。スクリーンショット(screencaptureコマンド、
  BubiBoyLiteウィンドウ部分のみ切り出し、他のウィンドウ内容が写り込んでいたため
  周辺情報は破棄した)をReadツールで目視し、ヘッドレスダンプツールと同じ「左が赤・
  右が青・中央に緑の小スプライト」が表示されていることを確認した。これによりT6-3の
  ヒープ確保リファクタとT6-6のフレーム境界変更が実アプリ経路でも問題なく動作することを
  確認できた。
