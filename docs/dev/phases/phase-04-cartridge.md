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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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

- [ ] 完了

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
