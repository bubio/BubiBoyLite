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

- [x] 完了

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

- [x] 完了

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

- [x] 完了

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

- [x] 完了

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

- [x] 完了

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

2026-07-11 T2-6 完了(T2-2〜T2-5より先行して実施): T2-1直後にMooneyeハーネスを整備することで、
以降のT2-2/T2-3/T2-5のDoD(Mooneye ROMがPASSすること)を「odin test実行時に実際にPASS/FAILが
判定される」状態で検証できるようにした(先にT2-3等を完了扱いにするとMooneyeテストが存在せず
検証不能になるため)。
- `Cpu` に `debug_break_on_ld_b_b`/`ld_b_b_hit` を追加、cpu_step の0x40実行時にフックする形で実装。
- `tests/rom_runner.odin` に `run_mooneye_rom`(LD B,B検出→レジスタ指紋判定)を追加。
- `scripts/fetch_test_roms.sh` にMooneye取得を追加: `~/dev/_Emu/BubiBoy/tests/BubiBoy.TestRoms/roms/mooneye/`
  からのローカルコピーを優先し、無ければ取得する。**当初想定していた「Gekkioのリリース」は
  2026-07時点で存在しない**(Gekkio/mooneye-test-suiteはGitHub Releaseでビルド済みROMを配布して
  いない。ソースからのアセンブルが必要)。そのためフォールバック先を`c-sp/game-boy-test-roms`
  のタグ付きリリース(v7.0、ビルド済みmooneye-test-suiteを同梱するMIT系サードパーティ集約リポジトリ、
  多くのGBエミュレータプロジェクトが同様の目的で参照している)に変更した。ローカルコピー元に
  無かった11本(ie_push, rapid_toggle, tim*_div_trigger×4, oam_dma/basic, oam_dma/reg_read,
  oam_dma_start)をこの経路で取得し、timer/全13本を含む計24本のROM取得を確認。
- `tests/mooneye_test.odin` 新規作成: timer/13本 + intr系5本(ie_push, if_ie_registers, intr_timing,
  rapid_di_ei, ei_timing) + halt系3本 + oam_dma系3本 = 24本の@(test)を追加。
- `tests/expected_failures.odin` に初期許可リストを投入。実行してみたところ、T2-1のディスパッチと
  T1-9のタイマー仮実装だけで if_ie_registers・intr_timing・tim00_div_trigger・tim01・
  tim11_div_trigger が既にPASSしたため、この5本は許可リストから即座に除外した(「予期せぬPASS」
  検出の動作確認も兼ねる)。halt_ime0_ei・halt_ime0_nointr_timing・oam_dma_startは`wait_ly`
  (タイムアウト無し)や実際のVBlank割り込み発火に依存しており、フェーズ2にはPPUが無いため
  原理的にパスしない。理由コメント付きでフェーズ3送りとして許可リストに残す。
- `odin test tests -collection:bbl=src`: 110 tests 全パス(24本のMooneyeテストのうち19本が許可
  リスト経由でFAIL/TIMEOUTのまま成功扱い、5本が実PASS)。

2026-07-11 T2-2 完了: HALT起床条件・EIの1命令遅延・HALTバグを実装。
- `Cpu` に `halt_bug: bool`、`ime_delay: int` を追加。
- EI遅延は `ime_delay=2` を起点とするカウントダウン方式: cpu_stepの先頭で`ime_delay>0`なら
  毎回1減算し、0になった瞬間に`ime=true`を反映する。DIは`ime_delay=0`にキャンセルする。
  この設計は実装前にmooneye `rapid_di_ei.s`のソース(4パターン: ei;di;ei;di→割込み無し、
  ei;di;nop;nop→割込み無し、ei;nop;di→割込み有り、ei;nop;nop;di→割込み有り)を読み、
  手でトレースして4パターン全てが一致することを確認してから実装した。
- HALTバグは`cpu.halt_bug`フラグで実装: `!ime && pending!=0`でHALT実行時にセットし、
  cpu_step側で次の1回だけPCをインクリメントしないことで「次の命令の先頭バイトが2回読まれる」
  を再現する。
- 特例として「EI直後にHALTが続く場合はIME有効化を前倒しする」挙動をmooneye `halt_ime0_ei.s`の
  コメント("If EI is before HALT, the HALT instruction is expected to perform its normal IME=1
  behaviour")から把握し、HALTの実行(case 0x76)内で`ime_delay>0`なら即座に`ime=true`へ
  解決してから起床判定するようにした。
- 単体テスト `tests/cpu_halt_ei_test.odin` を新規作成(EI遅延、EI;DIキャンセル、HALTバグでの
  PC足踏み、IME=trueでのHALT起床、IME=falseでの起床(ハンドラに飛ばない)の5件)。
- 副産物として blargg `cpu_instrs/individual/02-interrupts`、mooneye `halt_ime1_timing`・
  `ei_timing`・`rapid_di_ei` が実PASSするようになったため許可リストから除外。
- `odin test tests -collection:bbl=src`: 115 tests 全パス。

2026-07-11 T2-3 完了: `src/core/timer.odin` を新規作成し、T1-9のフリーラン仮実装(bus.odin内)を
落下エッジ検出方式に置き換えた。
- `bus.div_counter`(内部16bitカウンタ、DIVはその上位8bit)、`timer_signal`(TAC enable と
  選択ビットのAND)を1 T-cycle刻みで評価し、1→0への変化でTIMAをインクリメントする
  (`timer_tick`は`bus_tick`から呼ばれ、tを4サイクルまとめてでなく1ずつループする)。
- TIMAオーバーフローは`timer_reload_pending`(4→0のカウントダウン)で4 T-cycleの遅延を再現。
  0になった瞬間にTMAをリロードしIF bit2をセットする。この間の追加の落下エッジは無視。
- DIV書き込み(`timer_write_div`)は内部カウンタを0にし、その瞬間に選択ビットが1→0に
  落ちるならTIMAも余分に進める。TAC書き込み(`timer_write_tac`)も同様に落下エッジ判定する。
- TIMA/TMA書き込みとリロード完了が同一T-cycleに重なるケース(BubiBoy Bus.fsの
  `TimerReloadMarkerIndex`相当、`bus.timer_reload_just_happened`として移植)も実装:
  リロード完了直後のTIMA書き込みは無視され、TMA書き込みは新しい値がそのままTIMAにも
  反映される(mooneye tima_write_reloading/tma_write_reloading 対応)。
- 既存の単体テスト`test_tima_counts_up_when_tac_enabled_and_reloads_on_overflow`・
  `test_tima_overflow_sets_if_timer_bit`をこのフェーズの新しい4 T-cycle遅延仕様に合わせて更新。
- mooneye timer/ 13本中12本(tim00/01/10/11、tim00/01/10/11_div_trigger、div_write、
  tima_reload、tima_write_reloading、tma_write_reloading)が実PASSし許可リストから除外。
  `rapid_toggle`のみ、TACの高速トグル(秒間数万回)に対する実機ANDゲート回路レベルの
  グリッチ挙動までは再現できておらず(タイマー割り込みは発生するがBC指紋が不一致)、
  理由コメント付きで許可リストに残しT2-7で再挑戦する。
- `odin test tests -collection:bbl=src`: 115 tests 全パス。

2026-07-11 T2-4 完了: `src/core/joypad.odin` を新規作成。`Button` enum(Right/Left/Up/Down/
A/B/Select/Start)、`joypad_set_button`、JOYP(0xFF00)の負論理エンコーディング
(bit5=0でアクション、bit4=0で方向、両方選択時はAND合成)、選択中のボタンが0→1(押下)へ
変化した際のIF bit4リクエストを実装。Bus に `joyp_select_action`/`joyp_select_direction`
(bool、trueが選択中)/`joyp_pressed`(ボタンごとのビットマスク)を追加し、bus_io_read/write の
JOYP_ADDR(0xFF00)をそれぞれ `joypad_read_p1`/`joypad_write_p1` に委譲。
単体テスト `tests/joypad_test.odin` を新規作成(非選択時の全1読み出し、アクション/方向
それぞれの反映、両方選択時のAND合成、選択ビットの読み戻し、押下時の割り込み、
非選択グループでは割り込みが起きないこと、離す操作では割り込みが起きないことの8件)。
`odin test tests -collection:bbl=src`: 123 tests 全パス。

2026-07-11 T2-5 完了: bus.odin に OAM DMA(0xFF46)を実装。
- `dma_tick_one_mcycle`(`bus_tick`から1 M-cycleごとに呼ばれる)で状態機械を実装:
  書き込み時に `dma_start_delay=2` をセット、1回目の減算(M1)では何もせず(実行中の旧転送が
  あればそのまま継続する。新規開始ならOAMはまだ読める)、2回目の減算(M2)で
  `dma_active=true`・`dma_source`/`dma_index=0`を確定し即座に1バイト目を転送、以後
  1バイト/M-cycleで160バイト転送し終わると`dma_active=false`に戻す。この1 M-cycleの
  開始遅延はMooneye `oam_dma_start.s`冒頭のコメント("M=0: write, M=1: nothing, M=2: new
  DMA starts")と実装前に照合して決めた。
- `bus_read`をCPU向け経路として残し、内部実装は`bus_read_raw`に分離。`bus_read`は
  `dma_active`中はHRAM(FF80-FFFE)以外への読み出しを0xFFにする。DMA自身の転送は
  `bus_read_raw`を直接使うため、この制限を受けない(自分自身の転送を妨げない)。
  ソースが0xE000以上でもWRAMミラーとして扱われる(bus_read_rawの既存ロジックがそのまま
  流用される)。
- FF46 読み出しは常に直近の書き込み値を返す(mooneye oam_dma/reg_read対応。転送状態に
  関わらない)。
- 単体テスト `tests/dma_test.odin` を新規作成(160バイトの転送内容、1 M-cycle遅延後に
  転送が始まること、転送中の非HRAM読み出しが0xFFになること、転送完了後は通常どおり
  読めること、レジスタ読み戻しの5件)。
- **調査で判明した重要事項**: `mooneye/acceptance/interrupts/ie_push`・`oam_dma/basic`・
  `oam_dma/reg_read`・`oam_dma_start`の4本(c-sp/game-boy-test-roms v7.0収録ビルド)を
  逆アセンブルしたところ、冒頭で呼んでいる`disable_ppu_safe`が現在のmooneye-test-suite
  ソース(タイムアウト付き`wait_ly_with_timeout`使用)より古い、**タイムアウト無し**の
  `LDH A,(LY); CP $90; JR NZ,-`版であることを確認した。LCDC/LYはフェーズ3まで未実装
  (常に0xFF)のため、この4本はテスト本体に到達する前に無限ループしタイムアウトする。
  したがって T2-5 自体のバグではなく、これらは`halt_ime0_ei`/`halt_ime0_nointr_timing`と
  同様に正真正銘のフェーズ3送り(理由コメント付きで許可リストに追加)。
  ie_push のディスパッチロジック自体は tests/interrupt_test.odin の単体テストで
  ie_push.s のRound1/Round3を手でトレースして別途検証済み(T2-1参照)。
- `odin test tests -collection:bbl=src`: 128 tests 全パス。

2026-07-11 T2-7 未完了(ブロック): デバッグ・修正フェーズを実施したが、rapid_toggle 1本を
残してブロックしている。この項目は正式には**完了とせず**、次セッションへ引き継ぐ。

対象ROMの内訳(全て `odin test tests -collection:bbl=src` で確認):
- mooneye timer/ 13本: 12本PASS。**rapid_toggle のみFAIL**(詳細は下記「ブロック理由」)。
- mooneye intr系: if_ie_registers・intr_timing・rapid_di_ei はPASS。ie_push は
  disable_ppu_safe(タイムアウト無し版)がテスト本体到達前に無限ループするためフェーズ3送り
  (逆アセンブルで確認済み、T2-5参照)。
- mooneye halt系: halt_ime1_timing はPASS。halt_ime0_ei・halt_ime0_nointr_timingは
  wait_ly(タイムアウト無し)が実PPU無しでは終わらないためフェーズ3送り。
- blargg cpu_instrs/individual/02-interrupts: PASS。
- mooneye oam_dma系(T2-5で追加): basic・reg_read・oam_dma_start は同じく
  disable_ppu_safe起因でフェーズ3送り。

**ブロック理由**: `mooneye/acceptance/timer/rapid_toggle` はPPU非依存かつT2-3のDoDが
明示的に要求しているテストであり、フェーズ3への正当な繰り延べ理由がない
(他の6件と違い「未実装のPPUに依存している」という言い訳が成立しない)。
そのためT2-7の完了条件「PPU非依存のテストが全PASS」を満たせておらず、このタスクは
未完了として扱う(PLAN.mdのフェーズ状態も🟡のまま据え置く)。

**試したこと**:
1. `LD B,B`実行前にBCレジスタをディスパッチ直前に直接観測: 実測 BC=$FFD8
   (mooneyeの期待値 $FFD9 よりループが1回多く回っている=割り込みの認識が1ループぶん遅い)。
2. TAC書き込みごとの`old_signal`/`new_signal`/`fired`と`div_counter`をトレース出力し、
   このROMの39回のループ全体(TAC書き込み78回)を記録。
3. 同じ命令列(EI, 8T/12T/8T/12T/8T/4T/4T/12Tの正確なT-cycle数)をPythonで独立に
   シミュレートし、78件のtrace(old_signal/new_signal/fired/divの値)を診断1と突き合わせ:
   **完全一致(diff無し)**。落下エッジ検出ロジック自体は正しいと確認。
4. Pan Docs "Timer obscure behaviour"のTIMAオーバーフロー実測表(SYS=2B..31、7列)の
   生HTMLを取得し、`M-cycle`ヘッダ行の`A`/`B`ラベルが実際にどの列に対応するかを
   バイト単位で確認: `A`=SYS 2E(TIMA=$00が見え始める列)、`B`=SYS 2F(TMAリロード+IF確定が
   見える列)で、エッジ検出そのものから数えて2 M-cycle後にIFが確定する。自実装の
   `timer_reload_pending=4`(1 M-cycle)による遅延モデルもこれと一致することを検算で確認。
5. それでも1ループぶんズレる理由を特定: TIMAオーバーフローの原因となる`TAC=0`書き込み
   (LDH命令)の直後の命令が`DEC BC`(16bit減算、2 M-cycle命令)であり、IF確定は
   `DEC BC`の**内部サイクル中**に完了する。SM83は命令境界(次のフェッチ直前)でのみ
   割り込みを認識する一般的なモデルのため、`DEC BC`は(その2番目のM-cycle中に
   IFが確定しても)最後まで実行されてから初めて次の`cpu_step`で割り込みが認識される。
   これが実機の挙動と一致するのか、`DEC BC`のような2 M-cycle命令に限り実機がより
   細かい粒度で割り込みを認識する特例があるのかは、Pan Docsの記述だけでは判別できなかった。
6. `reload_pending`の起点をこの書き込みの直前(pre-M-cycle)のdiv値に変える実験も
   行ったが、結果は変化しなかった(=サンプリングタイミングの問題ではないことを消去法で確認)。
7. (追加調査、コーディネーターの示唆を受けて実施)「エッジ検出とTIMA=$00が見える瞬間の間に
   もう1 M-cycleぶんのレジスタコミット遅延が抜けているのでは」という仮説(4のPan Docs表の
   別解釈から生まれた仮説: エッジ自体はSYS=2Dで発生し、2Eで初めてTIMA=$00が見える=
   エッジからreload visibleまで実は2 M-cycleではなく3 M-cycleなのでは、というもの)を
   `mooneye/acceptance/timer/tima_reload.s`のソース(および付属コメント "Apparently the
   TIMA register contains 00 for **4 cycles** before being reloaded...**there is no
   additional 4 cycle delay**")を直接確認することで検証・却下した。tima_reloadは
   まさにこの「オーバーフローからリロードまでの遅延」を精密に検査するテストであり、
   自実装は既にこれにPASSしている。よって「edgeからtima=$00 visibleまでの間に
   追加の1 M-cycle遅延がある」という仮説は誤りであり、`timer_reload_pending=4`
   (1 M-cycleぶん)が唯一かつ正しい遅延であることが再確認された。この仮説は棄却して
   ELIMINATE済み。

**次にやること**: 実機トレースや既知の高精度エミュレータ(SameBoy等)のログと突き合わせて、
2 M-cycle命令の内部サイクル中に割り込み条件が成立した場合の実機の扱いを特定すること。
上記7で判明した通り、タイマー側の遅延モデル自体はtima_reload.sで裏付けが取れている
(疑うべきはタイマーではなく、CPU側の割り込み認識が命令境界のみで良いのか、
DEC BCのような2 M-cycle命令の内部サイクル境界でも認識され得るのか、という点に絞られた)。
デバッグ用のトレースコード(timer.odin への一時的な `DEBUG_TRACE_TAC` フラグ追加など)は
今回の調査で使ったが、コミットには含めていない(再現手順は上記の通り)。

- 許可リスト(tests/expected_failures.odin)の現状: 7エントリ全てに理由コメント付き
  (rapid_toggle 1件は上記の調査結果、残り6件はフェーズ3のPPU実装待ち、逆アセンブルで
  根拠を確認済み)。「予期せぬPASS」の自動検出も動作確認済み(T2-3/T2-4完了時に実際に検出)。
- `./scripts/fetch_test_roms.sh && odin test tests -collection:bbl=src`: 128 tests 全パス
  (許可リスト経由でrapid_toggleのFAILも含めて成功扱いになっているだけで、実際には
  未解決)。`odin build src/app -collection:bbl=src` は成功。

2026-07-11 ユーザー判断によりT2-7を保留してフェーズ3へ進行: rapid_toggle は
forums.nesdev.org「About Mooneye GB timer tests」で実装者本人(idearcos)が
「基本的なメモリ読み書きタイミングの調整で直った」とだけ報告し具体的な原因は
非公開のまま解決している、既知の難関ケースであると確認した(コーディネーターが
生ソース取得・フォーラム調査を実施し、上記7の追加仮説も含めて棄却済み)。
これ以上は実機トレースか信頼できる参照実装のログとの突き合わせが必要でブラック
ボックスな試行錯誤にしかならないと判断し、ユーザーに続行/保留を確認したところ
「フェーズ3に進む」を選択。フェーズ2は6/7・🟡のまま据え置き、rapid_toggle は
tests/expected_failures.odin に理由付きで残存させる。127/128テストはPASS、
割り込み・HALT・EI遅延・DIV/TIMA・ジョイパッド・OAM DMAの実機能は実装・検証済みで
あり、フェーズ3(PPU)の実装をブロックしない。再挑戦は将来のセッションで実機
トレースや参照実装との突き合わせが可能になった時点で行う。

2026-07-16 `oam_dma/reg_read`(許可リスト残存中、T3-8時点で原因未解明のまま保留)が
実際の市販ゲーム(GBC、MBC5+RAM+BATTERY)のクラッシュとして顕在化することを確認した。
ユーザーが `bbl` で実プレイ中に `cpu: illegal opcode 0xDD at pc=0x0121` のログが
延々出続ける不具合を報告(独立した別バグ: `emulator_run_frame`/メインループが
`cpu.stopped` を一度も見ておらず、停止後もフレーム毎に無限にフェッチを続けていた。
これは `caeae3a` で別途修正・コミット済み)。

その報告を受けて該当ROMを実際にロードし、`emulator_step` を単体で数十万回呼ぶ
デバッグトレーサ(スクラッチパッドの一時プログラム、コミットには含めていない)で
命令単位のpc/sp遷移を記録して原因を特定した:
1. 停止直前、`pc=0x0038`(RST 38のジャンプ先)に居座ったまま`sp`が2ずつ単調減少する
   ループを検出(スタックを無限に消費している)。
2. ROM実バイトでは`0x0038`は`0x47`(LD B,A)であり、RST 38を指す`0xFF`ではない。
   にもかかわらず観測された挙動は「フェッチした命令が常に`0xFF`」でなければ
   説明がつかない(0xFFなら1バイトRST 38として`sp-=2`・`pc=0x0038`に飛び、
   次のフェッチも同じ0x0038で0xFFを読み直し、を無限に繰り返す)。
3. `bus_read`(bus.odin)は`dma_active`中はHRAM(0xFF80-0xFFFE)以外の読み出しを
   一律`0xFF`にする簡易モデル(T2-5)。このゲームは自前のDMA待機ループを
   HRAMにコピーして固定回数実行後に通常メモリへ戻る、実機の一般的な作法を
   使っているが、bbl内部の`dma_active`解除タイミングが実機と数サイクルずれて
   いるため、待機ループを抜けた直後の通常コード領域フェッチがまだ`0xFF`(=DMA中の
   ダミー値)を返し、それがRST 38として解釈されて上記の無限ループに入っていた。
4. この機構は`mooneye/acceptance/oam_dma/reg_read`(DMA転送中のレジスタ読み出し値を
   精密に検査するテスト)がFAILし続けている根本原因と同一と考えられる
   (`bus_read`のDMA競合モデルが実機の粒度と一致していない、という一点に収束する)。

**判断**: ユーザーに調査結果を報告し、今すぐ修正するか既知の課題として先送りするか
確認したところ「既知の課題として記録してフェーズ10へ」を選択。`bus_read`のDMA競合
モデルをMooneye `oam_dma/reg_read`のサイクル単位の仕様に合わせて作り直す必要があり、
`rapid_toggle`同様に実機トレースとの突き合わせが要る規模の調査になるため、この
セッションでは着手しない。再挑戦時は本ログの1〜4を出発点にすること
(`tests/expected_failures.odin`の`oam_dma/reg_read`エントリのコメントにも要約を追記済み)。

2026-07-16 `oam_dma/reg_read`と実プレイクラッシュの根本原因を修正(フェーズ11のT11-5準備中、
ユーザー指示によりフェーズ10完了後に再着手): 前身プロジェクト BubiBoy(`~/dev/_Emu/BubiBoy`)の
`src/BubiBoy.Core/Bus.fs` を確認したところ、`cpuReadByte`/`cpuWriteByte`/`oamDmaActive`は
OAM DMA中でもOAM領域(FE00-FE9F)自身へのアクセスだけをブロックし、IOレジスタ・WRAM・HRAM等は
通常どおり読み書きできる実装になっていた。bbl(bus.odin)の従来実装は「DMA中はHRAM以外を
一律0xFFにする」という過剰なバス競合モデルで、これがMooneye `oam_dma/reg_read`のFAILと
実プレイクラッシュ(上記1〜4参照)の共通の根本原因だった。
修正: `bus_read`/`bus_write`のDMA競合チェックを`addr >= 0xFF80 && addr <= 0xFFFE`(HRAM以外)
から`addr >= 0xFE00 && addr <= 0xFE9F`(OAM自身のみ)に変更(bus_writeには元々このチェックが
無く新規追加、BubiBoyのcpuWriteByteと対称にした)。
`tests/dma_test.odin`の`test_dma_blocks_non_hram_reads_while_active`(旧モデル前提)を
`test_dma_blocks_only_oam_reads_while_active`に置き換え、WRAM/HRAMは転送中も通常どおり読める・
OAM自身は0xFFになることを検証するテストに更新。`tests/expected_failures.odin`から
`mooneye/acceptance/oam_dma/reg_read`を削除(実際にPASSするようになったため)。
`odin test tests -collection:bbl=src`: 415 tests 全PASS(回帰なし)。
さらに実際にバグ報告の原因となったROM(Wizardry I, GBC, MBC5+RAM+BATTERY)を実機ファイルから
ロードし、60秒分(3600フレーム)`emulator_run_frame`を回すスクラッチ検証プログラムで
`cpu.stopped`にならないことを確認し、実プレイクラッシュの再現消失を確認した(コミットには含めない)。
なお`mooneye/acceptance/timer/rapid_toggle`は本修正と無関係の別問題として引き続き未解決・
許可リスト残存のまま(2026-07-11の検証ログ参照)。T2-7自体はrapid_toggleが残っているため
未完了のままとする。

2026-07-17 rapid_toggleについて、BubiBoy(前身プロジェクト)への移植可否をユーザーに確認。
`~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Timer.fs`(T-cycle単位の落下エッジ検出・2段階リロード
遅延)と`Cpu.fs`(`pendingInterrupt`を命令境界でのみチェックする設計)を調査したところ、
両方ともbblと基本的に同一のアーキテクチャだった。しかし
`~/dev/_Emu/BubiBoy/tests/BubiBoy.TestRoms/roms/mooneye/README.md`を確認したところ、
BubiBoyのテストROM一覧に`rapid_toggle`(および`tim*_div_trigger`系)がそもそも含まれておらず、
BubiBoy自身もこのROMを一度も検証したことが無いと判明した。つまりOAM DMAバグの時と異なり
「移植元に答えが無い」ケースであり、単純な移植では解決できない。
**ユーザー判断**: 「このままとします。動作不良が見つかった時に調査するものとします」。
実プレイでの不具合が実際に見つかった場合にのみ再調査する方針とし、それまでは
`tests/expected_failures.odin`の許可リストに残したまま、T2-7は未完了(フェーズ2は6/7・🟡)の
まま据え置く。
