# フェーズ 2: 割り込み・タイマー・OAM DMA

## 前提

- 依存フェーズ: 1（CPU 全命令、M-cycle バス、テスト ROM ランナー）
- ここからサイクル精度が本格的に問われる。Mooneye テストは「命令実行後まとめて tick」の実装を確実に検出する。

## ゴール

割り込みシステム・タイマー・ジョイパッドレジスタ・OAM DMA を実装し、
Mooneye acceptance の timer/ と割り込み系テスト、Blargg 02-interrupts をパスする。

## フェーズ完了の検証コマンド

```sh
./scripts/fetch_test_roms.sh && odin test tests -collection:bbl=src
# => mooneye timer/* と intr 系、blargg 02-interrupts が PASS
```

---

### T2-1: IF / IE / IME と割り込みディスパッチ

- [x] 完了

**目的**: 割り込みの検出・優先度・ディスパッチを実装する。
**作るもの**: `src/core/interrupt.odin` + cpu.odin 変更:
- IF (0xFF0F) / IE (0xFFFF)。IF の上位 3bit は読むと 1
- `Interrupt :: enum { VBlank, Stat, Timer, Serial, Joypad }`、ベクタ 0x40/0x48/0x50/0x58/0x60、IF の bit0〜4
- cpu_step の先頭で `ime && (IF & IE & 0x1F) != 0` なら割り込み処理:
  IME クリア → 該当 IF bit クリア → PC を PUSH → ベクタへジャンプ。**合計 20 T-cycle**（内部 2 M + PUSH 2 M + ジャンプ 1 M）
- 優先度は bit 番号の小さい順（VBlank 最優先）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Interrupt.fs` と Cpu.fs のディスパッチ部、Pan Docs "Interrupts"
**完了条件 (DoD)**: 単体テスト: IF/IE を直接立てて割り込みハンドラに飛ぶこと、優先度、IF bit クリアを確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: PC を PUSH する**途中**で IE が書き換わるケース（PUSH の上位バイト書き込みが IE を潰す）は Mooneye ie_push が検査する。PUSH を 2 回の cpu_write8 で実装していれば自然に正しくなる。
**依存**: なし

---

### T2-2: HALT・EI 遅延・HALT バグ

- [ ] 完了

**目的**: HALT の起床条件と有名なエッジケース 2 つを正確にする。
**作るもの**: cpu.odin 変更:
- HALT 中は cpu_step が `bus_tick(bus, 4)` だけ行う。`(IF & IE & 0x1F) != 0` になったら起床（**IME が false でも起床する**。その場合ハンドラには飛ばず次の命令へ）
- **EI の 1 命令遅延**: EI 直後の 1 命令は IME 有効化前に実行される（`ime_pending` フラグで実装）。EI → DI 連続なら割り込みは入らない
- **HALT バグ**: `!ime && (IF & IE & 0x1F) != 0` の状態で HALT を実行すると、次の命令の最初のバイトが 2 回読まれる（PC がインクリメントされない）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cpu.fs`（HALT 処理）、Pan Docs "halt bug"
**完了条件 (DoD)**: 単体テストで EI 遅延と HALT バグ（PC 非インクリメント）を確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: Blargg 02-interrupts と Mooneye halt_ime0/halt_ime1 系がこのタスクの検査官。
**依存**: T2-1

---

### T2-3: DIV / TIMA タイマー

- [ ] 完了

**目的**: 0xFF04-0xFF07 を落下エッジ方式で実装し、タイマー割り込み (IF bit2) を正確に出す。
**作るもの**: `src/core/timer.odin`:
- **DIV は独立した 8bit レジスタではなく、内部 16bit カウンタの上位 8bit**。カウンタは毎 T-cycle +1
- TIMA は「TAC で選んだカウンタビットの**落下エッジ (1→0)**」でインクリメント。
  選択ビット: TAC 下位 2bit = 00→bit9, 01→bit3, 10→bit5, 11→bit7。TAC bit2 (enable) との AND を取った信号のエッジを見る
- DIV への書き込みは値に関係なく**内部カウンタ全体を 0** にする（このとき選択ビットが 1→0 になると TIMA が余分に進む — 仕様どおりの挙動）
- TIMA オーバーフロー: **4 T-cycle の間 TIMA=0x00 のまま**、その後 TMA をリロードして IF bit2 をセット。この 4 cycle 間の TIMA 書き込みはリロードをキャンセルする
- `timer_tick(timer, bus_if, t_cycles)` を bus_tick から呼ぶ
- T1-9 で入れた DIV 仮実装を置き換える
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Timer.fs`（全 136 行、エッジ検出ロジックをそのまま移植してよい）、Pan Docs "Timer obscure behaviour"
**完了条件 (DoD)**: Mooneye `acceptance/timer/` の tim00〜tim11、div_write、rapid_toggle が PASS（tima_reload / tima_write_reloading / tma_write_reloading も目標。落ちる場合は許可リストに理由付きで残し T2-7 で再挑戦）。
**検証方法**:
```sh
odin test tests -collection:bbl=src
```
**落とし穴**: このタスクの全仕様が「落とし穴」。1 T-cycle 単位で timer_tick を回すのが最も安全（4 単位でも正しく書けるがエッジ検出を跨がないよう注意）。
**依存**: T2-1（IF 接続）

---

### T2-4: ジョイパッドレジスタ

- [ ] 完了

**目的**: 0xFF00 (JOYP) と入力状態の保持、ジョイパッド割り込みを実装する。
**作るもの**: `src/core/joypad.odin`:
- `Button :: enum { Right, Left, Up, Down, A, B, Select, Start }`、`joypad_set_button(bus, button, pressed)`
- JOYP: bit5=0 でアクション（A/B/Select/Start）、bit4=0 で方向キーを bit3-0 に反映。**0 = 押下**。上位 2bit は 1
- ボタンが 1→0（押下）に変化し選択中なら IF bit4
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Joypad.fs`、Pan Docs "Joypad Input"
**完了条件 (DoD)**: 単体テスト: 選択ビット切替と押下反映、両方選択時の AND 合成。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: すべて負論理。方向とアクション両方選択（bit5=bit4=0）のときは両グループの AND。
**依存**: なし

---

### T2-5: OAM DMA

- [ ] 完了

**目的**: 0xFF46 への書き込みで OAM へ 160 バイト転送する DMA を実装する。
**作るもの**: bus.odin 変更:
- 0xFF46 に値 v を書くと、`v * 0x100` から 0xFE00-0xFE9F へ 160 バイトの転送を開始
- 転送は**即時ではなく 160 M-cycle かけて 1 バイト/M-cycle**（bus_tick 内で進める）
- DMA 中の CPU は HRAM (FF80-FFFE) 以外を読むと 0xFF（バス競合の簡易モデル）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs`（DMA 処理）、Pan Docs "OAM DMA Transfer"
**完了条件 (DoD)**: Mooneye `acceptance/oam_dma/basic` 系が PASS。単体テストで転送内容と所要サイクルを確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: DMA 開始には 1 M-cycle の遅延がある（Mooneye oam_dma_start が検査）。ソースが 0xE000 以上の場合は WRAM ミラーとして扱う。
**依存**: なし

---

### T2-6: Mooneye 判定の rom_runner 対応

- [ ] 完了

**目的**: Mooneye 方式（LD B,B + レジスタ指紋）の判定を rom_runner に追加する。
**作るもの**:
- `tests/rom_runner.odin` に `run_mooneye_rom(path) -> Rom_Result`: オペコード 0x40 (LD B,B) 実行を検出して停止し、
  B=3,C=5,D=8,E=13,H=21,L=34 なら PASS、全 0x42 なら FAIL、他は INCONCLUSIVE（FAIL 扱い）
- `scripts/fetch_test_roms.sh` に Mooneye 取得を追加（`~/dev/_Emu/BubiBoy/tests/BubiBoy.TestRoms/roms/mooneye/` が存在すればコピー、無ければ Gekkio リリースからダウンロード）
- `tests/mooneye_test.odin`: timer/・intr 系・oam_dma 系の `@(test)` 一覧 + 許可リスト初期投入
**参照**: testing.md「Mooneye 方式」
**完了条件 (DoD)**: `odin test tests` で mooneye 系テストが実行される（PASS/許可リスト管理下の FAIL のみ）。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: core 側に「LD B,B で停止」のデバッグフックが要る。`cpu.debug_break_on_ld_b_b: bool` を Cpu に持たせ、通常実行では無効にする。
**依存**: T2-1

---

### T2-7: Mooneye timer / intr 系 + Blargg 02 全パス

- [ ] 完了

**目的**: フェーズ 2 のマイルストーン。タイミング系のバグを潰し切る。
**作るもの**: デバッグと修正のみ。対象:
- `mooneye/acceptance/timer/` 全 13 本
- `mooneye/acceptance/` の intr 系（ie_push, if_ie_registers, intr_timing, rapid_di_ei）と halt 系（halt_ime0_ei, halt_ime0_nointr_timing, halt_ime1_timing）
- `blargg/cpu_instrs/individual/02-interrupts.gb`
- 通ったものを許可リストから外す。どうしても通らないものは理由を許可リストのコメントと検証ログに記録（di_timing/ei_timing など PPU 依存のものはフェーズ 3 送りを許容）
**参照**: 各テスト名が仕様を示す。references.md の Mooneye リポジトリに各テストの説明あり
**完了条件 (DoD)**: 上記のうち PPU 非依存のテストが全 PASS。許可リスト残留はコメントで理由必須。
**検証方法**:
```sh
odin test tests -collection:bbl=src
```
**落とし穴**: intr_timing は割り込みディスパッチの 20 T-cycle が正確でないと落ちる。rapid_toggle はタイマー有効ビットのエッジ扱い。
**依存**: T2-2, T2-3, T2-5, T2-6

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-11 T2-1 完了: interrupt.odin 新規作成(IF/IE/IME、Interrupt enum、優先度付き20T-cycleディスパッチ)。
cpu_step 先頭で `ime && pending!=0` を判定するよう変更。ie_push(mooneye acceptance/interrupts/ie_push.s)の
実機挙動を事前に確認し、ベクタ決定を「PC上位バイトPUSH直後・下位バイトPUSH前」に行うよう実装
(上位バイト書き込みがIEを潰すとキャンセルされPC=0x0000、下位バイト書き込みでの書き換えは手遅れで
通常どおり進む)。`odin test tests -collection:bbl=src`: 86 tests 全パス(新規 tests/interrupt_test.odin 6件含む)。
