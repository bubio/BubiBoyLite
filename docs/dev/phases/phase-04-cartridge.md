# フェーズ 4: カートリッジ・MBC・バッテリーセーブ

## 前提

- 依存フェーズ: 3（実ゲームで動作確認するため。テスト ROM だけならフェーズ 2 完了でも着手可能）

## ゴール

MBC1/2/3(RTC)/5 と外部 RAM・バッテリーセーブ (.sav) を実装し、市販ゲームの大半が起動・セーブできる状態にする。
Blargg cpu_instrs 統合版と Mooneye MBC 系テストをパスする。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # cpu_instrs 統合版 + mooneye emulator-only/mbc* が PASS
# MBC1/MBC5 ゲームでセーブ → 終了 → 再起動 → セーブが残っている（目視）
```

---

### T4-1: カートリッジヘッダ解析

- [x] 完了

**目的**: ROM ヘッダから MBC 種別・ROM/RAM サイズ・バッテリー有無・CGB フラグを判定する。
**作るもの**: `src/core/cartridge.odin`:
- `Cartridge_Info :: struct { mbc_kind, rom_banks, ram_size, has_battery, has_rtc, cgb_flag, title }`
- 0x0147 の種別表（references.md）から分類。未対応種別（MBC6/7, HuC 系）は明示的なエラーを返し、app 側で「未対応カートリッジ (type=0xNN)」と表示
- ROM サイズ: `32KiB << rom_size_code`、RAM サイズ: コード 0/2/3/4/5 → 0/8/32/128/64 KiB
- ファイルサイズとヘッダの整合チェック
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cartridge.fs`（154 行、ほぼそのまま移植可）、Pan Docs "The Cartridge Header"
**完了条件 (DoD)**: 単体テスト: 合成ヘッダで各 MBC 種別・サイズの判定、未対応種別のエラー。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: MBC2 は RAM サイズコード 0 だが内蔵 RAM を持つ。0x0149 に頼らず種別で判定。
**依存**: なし

---

### T4-2: MBC1

- [x] 完了

**目的**: 最も普及した MBC1 のバンク切替を実装する。
**作るもの**: `src/core/mbc.odin`:
- `Mbc_State :: union { Mbc_None, Mbc1_State, ... }`（architecture.md の決定どおり tagged union）
- `Mbc1_State :: struct { ram_enabled: bool, rom_bank_low5: u8, bank_high2: u8, mode: enum { Rom, Ram } }`
- 書き込み: 0000-1FFF: 下位 4bit=0x0A で RAM 有効 / 2000-3FFF: ROM バンク下位 5bit（**0 は 1 に読み替え**）/ 4000-5FFF: 上位 2bit / 6000-7FFF: モード
- 読み出し: 0000-3FFF はモード 1 なら `high2 << 5` を掛けたバンク、4000-7FFF は `(high2 << 5) | low5`。バンク番号は ROM バンク数でマスク
- `mbc_read(cart, addr) -> u8` / `mbc_write(cart, addr, value)` を bus.odin の 0000-7FFF / A000-BFFF から呼ぶ形に置換
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/CartridgeMemory.fs`（Mbc1 部）、Pan Docs "MBC1"
**完了条件 (DoD)**: **Blargg cpu_instrs 統合版 (cpu_instrs.gb) が PASS**（許可リストから外す）。単体テスト: バンク 0 読み替え、モード切替。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 「5bit レジスタが 0 なら 1」の判定は **5bit マスク後**に行う（0x20/0x40/0x60 → 0x21/0x41/0x61 になる仕様）。Mooneye mbc1/rom_512kb 系が検査。
**依存**: T4-1

---

### T4-3: MBC2

- [x] 完了

**目的**: 内蔵 512×4bit RAM を持つ MBC2 を実装する。
**作るもの**: mbc.odin:
- `Mbc2_State :: struct { ram_enabled: bool, rom_bank: u8, ram: [512]u8 }`
- 0000-3FFF への書き込み: **アドレス bit8 が 0 なら RAM 有効化 (0x0A)、1 なら ROM バンク**（下位 4bit、0→1）
- RAM は A000-A1FF に 512 ニブル（上位 4bit は読むと 1）、A200-BFFF はエコー
**参照**: 同上（Mbc2 部）、Pan Docs "MBC2"
**完了条件 (DoD)**: 単体テスト: bit8 デコード、ニブルマスク、エコー領域。Mooneye mbc2 系（あれば）PASS。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: RAM 有効化と ROM バンク選択が**同じアドレス帯**で bit8 により区別される点が MBC1 と違う。
**依存**: T4-2

---

### T4-4: MBC3 + RTC

- [x] 完了

**目的**: MBC3 とリアルタイムクロックを実装する（ポケモン金銀等が必要とする）。
**作るもの**: mbc.odin:
- `Mbc3_State :: struct { ram_enabled: bool, rom_bank: u8, ram_or_rtc_select: u8, rtc: [5]u8, latched_rtc: [5]u8, latch_prepared: bool, rtc_base_unix: i64 }`
- 2000-3FFF: ROM バンク 7bit（0→1）/ 4000-5FFF: 0x00-0x03=RAM バンク、0x08-0x0C=RTC レジスタ選択（S/M/H/DL/DH）/ 6000-7FFF: 0x00→0x01 の順で書くとラッチ
- RTC の時刻進行は「基準 UNIX 時刻 + 経過秒」から計算する方式（BubiBoy と同じ。エミュ内サイクルで刻むより永続化が単純）。core は現在時刻を直接取らず、`emulator_set_wall_clock(emu, unix_seconds)` で app から供給する（テスト容易性のため）
- DH レジスタ: bit0=日カウンタ bit8、bit6=停止、bit7=日カウンタ桁あふれ
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/CartridgeMemory.fs`（Mbc3State、RTC 部）、Pan Docs "MBC3"
**完了条件 (DoD)**: 単体テスト: ラッチ手順（0→1 のみ有効）、RTC 選択読み書き、時刻供給による進行。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: ラッチは「0 を書いてから 1」の遷移のみ。時刻の永続化（.rtc）はフェーズ 7 T7-3 で行う — ここではインメモリのみでよい。
**依存**: T4-2

---

### T4-5: MBC5

- [x] 完了

**目的**: GBC 世代の標準 MBC5 を実装する。
**作るもの**: mbc.odin:
- `Mbc5_State :: struct { ram_enabled: bool, rom_bank_low8: u8, rom_bank_high1: u8, ram_bank: u8 }`
- 2000-2FFF: ROM バンク下位 8bit / 3000-3FFF: bit8 / 4000-5FFF: RAM バンク (0-15)
- **MBC5 はバンク 0 を指定できる**（0→1 読み替えをしない）
**参照**: 同上（Mbc5 部）、Pan Docs "MBC5"
**完了条件 (DoD)**: 単体テスト: バンク 0 指定、bit8 で 256 以上のバンク。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: MBC1 の癖（0→1）を持ち込まないこと。
**依存**: T4-2

---

### T4-6: バッテリーセーブ (.sav)

- [x] 完了

**目的**: 外部 RAM をファイルに永続化する。BluePrint: 保存先は ROM と同じ場所がデフォルト、設定で変更可能（設定はフェーズ 8）。
**作るもの**:
- core: `mbc_export_ram(cart) -> []u8` / `mbc_import_ram(cart, data)`（MBC2 は 512 バイト、MBC3 は RAM のみ — RTC は .rtc に分離）
- `src/app/saveram.odin`: `<ROM名>.sav` の読み書き。**アトミック書き込み**: 一時ファイルに書く → 既存 .sav を .sav.bak にリネーム → 一時ファイルを .sav にリネーム（BubiBoy `SaveRam.fs` の方式）
- 保存タイミング: 終了時 + RAM 書き込みから 1 秒間書き込みがなかったら（ダーティフラグ + フレームカウンタ）
- ロード: 起動時に .sav があれば import。サイズ不一致は警告してロードしない
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.IO/SaveRam.fs`（writeBytesWithBackup）
**完了条件 (DoD)**: 単体テスト: export/import ラウンドトリップ。結合確認: セーブ機能のあるゲームでセーブ → 終了 → 再起動 → ロードできる（目視）。
**検証方法**:
```sh
odin test tests -collection:bbl=src
./bbl <セーブ対応ゲーム>   # セーブ → 再起動 → 確認
```
**落とし穴**: RAM 無効時 (ram_enabled=false) の書き込みは無視されるので、ダーティ判定は mbc_write 内の実書き込みで立てる。
**依存**: T4-2〜T4-5

---

### T4-7: MBC テスト全パス

- [ ] 完了

**目的**: フェーズ 4 のマイルストーン確認。
**作るもの**: デバッグと修正のみ。
- `mooneye/emulator-only/mbc1/`, `mbc2/`, `mbc5/` 系を fetch スクリプトとテスト一覧に追加し、全 PASS させて許可リストから外す
**参照**: testing.md
**完了条件 (DoD)**: `odin test tests` で mbc 系 + cpu_instrs 統合版が PASS。MBC1 と MBC5 の市販ゲーム各 1 本が起動しプレイ可能（検証ログにゲーム名を記録）。
**検証方法**:
```sh
odin test tests -collection:bbl=src
```
**落とし穴**: mbc1/multicart 系テストは MBC1M（マルチカート）用で**スコープ外**。許可リストに「スコープ外」と明記して残してよい（architecture.md「スコープ外」参照）。
**依存**: T4-2〜T4-6

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-11 T4-1 完了: src/core/cartridge.odin 新規作成(Cartridge_Info/cartridge_parse_header)。
tests/cartridge_test.odin に16件の単体テストを追加(ROM only/MBC1/MBC2/MBC3+RTC/MBC5の分類、
ROM/RAMサイズコード変換、MBC2内蔵RAMの0x0149非依存、未対応種別(MBC6/HuC1)・未対応サイズ
コード・ファイルサイズ不整合・ヘッダ短小のエラー、タイトル文字列、CGBフラグ)。
`odin test tests -collection:bbl=src` 164 tests 全パス(既存148 + 新規16)。
`odin build src/app -collection:bbl=src` もクリーン。bus.odin へのMBC配線はT4-2で行う
(このタスクはヘッダ解析のみで、既存のbus_load_rom(ROM-onlyそのままmap)は未変更)。

2026-07-11 T4-2 完了: src/core/mbc.odin 新規作成(Mbc_State :: union { Mbc_None, Mbc1_State }、
mbc_read/mbc_write)。src/core/cartridge.odin に Cartridge struct(info/rom借用/ram所有/mbc/
ram_dirty)と cartridge_init/cartridge_destroy/cartridge_error_message を追加。
bus.odin を大幅refactor: Bus.rom フィールドを Bus.cart(Cartridge)に置換し、0000-7FFF・
A000-BFFFの読み書きをmbc_read/mbc_write経由に配線(既存のROM-onlyそのままmapは
Mbc_Noneとして挙動保存)。bus_load_rom はカートリッジヘッダ解析込みになり、失敗理由は
bus.cart_load_errorに残る(app側はcartridge_error_messageで整形、src/app/main.odinを更新)。
既存テスト(cpu_*_test.odin/interrupt_test.odin/bus_test.odin/rom_runner.odin)の
`bus.rom`参照は機械的に`bus.cart.rom`へ置換(意味は不変、借用スライスの所有権は従来どおり
呼び出し側)。tests/mbc1_test.odin新規作成(8件: バンク0→1読み替え、5bitマスク後の0→1判定
(0x20書き込みでも0x21が選ばれる)、ROM/RAMモード切替、RAM有効化/無効化、RAMバンク独立性)。
tests/blargg_test.odin に cpu_instrs.gb 統合版(MBC1、64KiB)の@(test)を追加(許可リストには
入れていなかったので除外作業は不要)。実測224,317,844 T-cycleかかることが判明したため、
共通タイムアウト(120M)とは別にCPU_INSTRS_INTEGRATED_TIMEOUT_TCYCLES=240Mを
rom_runner.odinに追加しrun_blargg_romにtimeout引数を持たせた(T-cycle数はホスト速度非依存の
決定的な値なのでマージンを乗せて固定)。開発時の追加検証として mooneye emulator-only/mbc1/
の bits_bank1・bits_bank2・bits_mode・bits_ramg・ram_64kb・ram_256kb・rom_512kb・rom_1Mb・
rom_2Mb・rom_4Mb・rom_8Mb・rom_16Mb 全12本を手元で個別実行しPASSを確認済み(正式な@(test)化と
fetch_test_roms.shへの追加はT4-7で行う。tests/roms/は.gitignore対象のためこの時点では
未コミット)。`odin test tests -collection:bbl=src` 172 tests 全パス(既存164 + 新規8)、
15.9秒(cpu_instrs.gb統合版の実行時間を含む)。`odin build src/app -collection:bbl=src`も
クリーン。

2026-07-11 T4-3 完了: mbc.odin に Mbc2_State(ram_enabled/rom_bank/内蔵ram:[512]u8)を追加し
Mbc_State unionに組み込んだ(mbc2_read/mbc2_write)。0000-3FFFはアドレスbit8で
RAM有効化(bit8=0)とROMバンク選択(bit8=1、下位4bit、0→1)を区別(MBC1と異なる落とし穴)。
RAMはA000-A1FFの512ニブル、上位4bitは読むと1、A200-BFFFは0x200バイト境界でのエコー
((addr-0xA000)&0x01FFで畳み込み)。実書き込み時のみcart.ram_dirtyを立てる(T4-6向け)。
cartridge_init の .Mbc2 ケースを Mbc2_State{rom_bank=1} の初期化に置き換え。
tests/mbc2_test.odin新規作成(6件: bit8判定、バンク0→1読み替え、ニブルマスクと上位4bit、
RAM無効時の読み書き無視、0x200境界エコーの本体/エコー双方向反映)。開発時の追加検証として
mooneye emulator-only/mbc2/ の bits_ramg・bits_romb・bits_unused・ram・rom_512kb・rom_1Mb・
rom_2Mb 全7本を手元で個別実行しPASSを確認済み(正式な@(test)化とfetch_test_roms.shへの追加は
T4-7で行う。tests/roms/は.gitignore対象のためこの時点では未コミット)。
`odin test tests -collection:bbl=src` 178 tests 全パス(既存172 + 新規6)、16.0秒。
`odin build src/app -collection:bbl=src`もクリーン。

2026-07-11 T4-4 完了: mbc.odinにMbc3_State(ram_enabled/rom_bank/ram_or_rtc_select/
rtc:[5]u8/latched_rtc:[5]u8/latch_prepared/rtc_base_unix:i64)を追加しMbc_State unionに
組み込んだ(mbc3_read/mbc3_write)。2000-3FFF ROMバンク7bit(0→1)、4000-5FFF
0x00-0x03=RAMバンク/0x08-0x0C=RTCレジスタ選択(S/M/H/DL/DH)、6000-7FFFはBubiBoy
latchMbc3Rtcと同じ状態機械で「0x00書き込み後にprepared=trueな状態で0x01」の遷移のみ
ラッチが発生する。CPUからのRTC読み出しは常にlatched_rtc(ラッチ済みスナップショット)を見る
設計とし、ライブレジスタ(rtc)は emulator_set_wall_clock(emulator.odinに新規追加、
mbc_sync_wall_clock経由でMbc3_Stateへディスパッチ)で供給されるUNIX秒により進行する
「基準UNIX時刻+経過秒」方式(rtc_base_unix、0は未同期センチネル、初回供給は基準点を打つ
だけで加算しない)。DH bit6(停止)中はrtc_base_unixだけ更新しレジスタを進めない(復帰時の
一気読み進み防止)。RTC永続化(.rtc)はフェーズ7送り(このタスクではインメモリのみ)。
tests/mbc3_test.odin新規作成(6件: ROMバンク0→1読み替え、RAMバンク独立性、
ラッチの0→1遷移限定、RTCレジスタ選択の読み書きラウンドトリップ、wall_clock供給での
時刻進行(1時間1分1秒境界)、停止ビットでの進行停止)。Mooneye emulator-only にはMBC3の
自動テストROMが存在しない(mbc3-tester/mealybug-tearoom mbc3_rtcは目視確認用ROMのため
対象外、phase-04記載のT4-7対象にもmbc3は含まれない)ため、単体テストのみで検証した。
`odin test tests -collection:bbl=src` 184 tests 全パス(既存178 + 新規6)、17.2秒。
`odin build src/app -collection:bbl=src`もクリーン。

2026-07-11 T4-5 完了: mbc.odinにMbc5_State(ram_enabled/rom_bank_low8/rom_bank_high1/
ram_bank)を追加しMbc_State unionに組み込んだ(mbc5_read/mbc5_write)。2000-2FFF ROMバンク
下位8bit、3000-3FFF bit8(9bit全体で最大512バンク=8MiBまで対応)、4000-5FFF RAMバンク
(0-15)。落とし穴どおりMBC1/2/3の「0→1読み替え」を持ち込まず、バンク0をそのまま
4000-7FFFに指定できる(cartridge_initでの電源投入直後の既定値のみ1、他MBCと揃えるため)。
tests/mbc5_test.odin新規作成(5件: 電源投入直後バンク1、バンク0を読み替え無しで選択、
bit8による256以上のバンク選択、low8/high1の組み合わせ、RAM有効化とバンク独立性)。
mooneye emulator-only/mbc5/ の rom_512kb・rom_1Mb・rom_2Mb・rom_4Mb・rom_8Mb・rom_16Mb・
rom_32Mb・rom_64Mb 全8本(64Mbit=8MiB、rom_size_code上限0x08=512バンクを含む)を手元で
個別実行しPASSを確認済み(正式な@(test)化とfetch_test_roms.shへの追加はT4-7で行う)。
`odin test tests -collection:bbl=src` 189 tests 全パス(既存184 + 新規5)、16.2秒。
`odin build src/app -collection:bbl=src`もクリーン。

2026-07-11 T4-6 完了: mbc.odinに mbc_export_ram(cart)->([]u8, ok)/mbc_import_ram(cart, data)->ok
を追加。バッテリー無しカートリッジはok=false。MBC2は内蔵512バイト(union内のMbc2_State.ram)、
MBC1/3/5はCartridge.ramをエクスポート/インポート対象にする。MBC3はRAMのみが対象で
RTCレジスタ(rtc/latched_rtc)は含まない(.rtcへの永続化はフェーズ7 T7-3、落とし穴どおり)。
サイズ不一致時はimportがfalseを返し、既存RAMは変更しない。
src/app/saveram.odin新規作成: save_ram_path_for_rom(ROM拡張子を.savに置換)、
save_ram_write_atomic(BubiBoy SaveRam.fs writeBytesWithBackup方式: 一時ファイル書き込み→
既存.savを.sav.bakへリネーム→一時ファイルを.savへリネーム。os.rename/os.write_entire_file/
os.removeを使用)、save_ram_load(存在しなければok=falseを返すのみでエラー扱いしない)。
src/app/main.odinのrun_rom_windowに統合: 起動時に.savがあればロード(mbc_import_ramがサイズ
不一致でfalseを返したら警告を出してロードしない、DoDどおり)、フレームループ内で
emu.bus.cart.ram_dirtyを毎フレーム消費(検査後false化)し、書き込みから60フレーム
(約1秒)アイドルしたら保存、ウィンドウ終了時にも最終セーブを実行(バッテリー無し
カートリッジではmbc_export_ramがok=falseを返し何もしない)。
tests/mbc_saveram_test.odin新規作成(5件、core.mbc_export_ram/mbc_import_ram): MBC1
ラウンドトリップ、バッテリー無しでのexport失敗、サイズ不一致インポートの拒否と既存RAM
保持、MBC2内蔵RAMラウンドトリップ、MBC3のRTC除外確認。tests/saveram_test.odin新規作成
(4件、cli_test.odinと同様にbbl:appを直接importする既存の慣習に従う): パス導出
(拡張子置換・ディレクトリ名のドット非依存・拡張子無し)、アトミック書き込み→読み込みの
ラウンドトリップと.bak生成確認、存在しないファイルのロード失敗。

結合確認(市販ROM代替、CLAUDE.mdの指示どおりRGBDSで自作したホームブリューROMを使用):
RGBDS(rgbasm/rgblink/rgbfix v1.0.1)でMBC1+RAM+BATTERY(type=0x03)とMBC5+RAM+BATTERY
(type=0x1B)、いずれもRAM 32KiB(4バンク)・ROM 32KiB のミニマルROM(RAM有効化→ROM/RAM
バンク切替レジスタへの書き込み→RAMバンク0に0x42、バンク1に0x99を書き込む)をアセンブルし、
実際にCPU実行(emulator_step)させてバンク切替コード経由でRAMへ書かせた。その後
mbc_export_ram→save_ram_write_atomicで一時ディレクトリへ保存、新しいEmulatorインスタンスへ
同じROMを再ロードして「終了→再起動」を模擬し、save_ram_load→mbc_import_ramでロード、
両バンクの値が一致することを確認した(MBC1・MBC5とも一時テストで全項目PASS。テストコードは
検証専用のためコミットしていない)。市販ゲームでの確認は著作権上できないため未実施 ——
Mooneye自動テスト(mbc1/mbc2/mbc5、T4-7で正式導入)とこの自作ホームブリューROMでの
確認のみで、実際の市販タイトルでの動作確認はしていないことをここに明記する。
`odin test tests -collection:bbl=src` 198 tests 全パス(既存189 + 新規9)、15.9秒。
`odin build src/app -collection:bbl=src`もクリーン。
