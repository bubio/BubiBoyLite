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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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
