# フェーズ 1: CPU (SM83)・バス

## 前提

- 依存フェーズ: 0（ビルド・テスト・CI の土台）
- [architecture.md](../architecture.md) の「タイミングモデル」を必読。**M-cycle 粒度**は後から直すのが最も高くつく設計判断。

## ゴール

SM83 CPU の全命令と M-cycle 粒度のバスを実装し、Blargg cpu_instrs（個別 11 本）と instr_timing をパスする。
画面はまだ不要。テスト結果はシリアル出力キャプチャで判定する。

## フェーズ完了の検証コマンド

```sh
./scripts/fetch_test_roms.sh
odin test tests -collection:bbl=src
# => blargg_cpu_instrs_01 〜 11 と blargg_instr_timing が全 PASS
```

---

### T1-1: CPU 構造体・レジスタ・フラグ

- [x] 完了

**目的**: SM83 のレジスタセットとフラグ操作の基盤を作る。
**作るもの**: `src/core/cpu.odin`:
- `Cpu :: struct { a, f, b, c, d, e, h, l: u8, sp, pc: u16, ime: bool, halted: bool, ... }`
- 16bit ペアアクセス: `cpu_af/bc/de/hl` の get/set（F の下位 4bit は常に 0）
- フラグ: Z=bit7, N=bit6, H=bit5, C=bit4。`cpu_set_flags` ヘルパー
- ブート後初期値の設定 `cpu_reset(cpu, mode)`: DMG は AF=0x01B0, BC=0x0013, DE=0x00D8, HL=0x014D, SP=0xFFFE, PC=0x0100（references.md の表参照。CGB はフェーズ 6）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cpu.fs`（冒頭のレジスタ定義部）、Pan Docs "CPU registers and flags"
**完了条件 (DoD)**: `tests/cpu_test.odin` にフラグ操作・ペアアクセス・reset 値のテストを書き全パス。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: F レジスタへのいかなる書き込みでも下位 4bit を 0 にマスクすること（POP AF で Blargg が検出する）。
**依存**: なし

---

### T1-2: バス骨格と M-cycle tick

- [x] 完了

**目的**: メモリマップと「アクセスごとに周辺機器を tick する」構造を最初から作る。
**作るもの**: `src/core/bus.odin`:
- `Bus :: struct { rom: []u8, vram: [8192]u8, wram: [8192]u8, oam: [160]u8, hram: [127]u8, io: [128]u8, ie: u8, cycles: u64, ... }`
  （VRAM/WRAM のバンク化はフェーズ 6 で拡張。今は 1 バンク分）
- `bus_read(bus, addr) -> u8` / `bus_write(bus, addr, value)`: メモリマップ分岐
  （0000-7FFF ROM, 8000-9FFF VRAM, A000-BFFF 外部RAM(未実装は 0xFF), C000-DFFF WRAM, E000-FDFF エコー, FE00-FE9F OAM, FF00-FF7F IO, FF80-FFFE HRAM, FFFF IE）
- `bus_tick(bus, t_cycles)`: `cycles` を進める。**この関数が今後 Timer/PPU/APU/DMA を駆動する唯一の場所**。今はカウンタ加算のみ
- CPU 側: `cpu_read8(cpu, bus, addr)` = `bus_tick(bus, 4)` + `bus_read`。書き込みも同様。**CPU からの全メモリアクセスは必ずこの経路を通す**
- ROM-only カートリッジのロード: `bus_load_rom(bus, data) -> bool`（32KiB をそのまま map。MBC はフェーズ 4）
- 未実装 IO レジスタの read は 0xFF を返す
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs`（メモリマップ分岐と advanceCpuClockedDevices の構造）、Pan Docs "Memory Map"
**完了条件 (DoD)**: `tests/bus_test.odin` で WRAM/HRAM/エコー領域の読み書き、tick カウントのテストが全パス。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: エコー RAM (E000-FDFF) は WRAM (C000-DDFF) のミラー。命令実行後にまとめて tick する設計は**禁止**（フェーズ 2 のテストで確実に落ちる）。
**依存**: T1-1

---

### T1-3: 8bit ロード・算術・論理命令

- [x] 完了

**目的**: LD r,r' / LD r,n / LD r,(HL) 系、ADD/ADC/SUB/SBC/AND/OR/XOR/CP/INC/DEC を実装する。
**作るもの**: `src/core/cpu.odin` に `cpu_step(cpu, bus) -> int`（実行 T-cycle 数を返す）とオペコードディスパッチ（`switch opcode`）。
- フェッチ: `opcode := cpu_read8(cpu, bus, cpu.pc); cpu.pc += 1`
- ADC/SBC のハーフキャリーは 4bit 目、キャリーは 8bit 目の桁上がり。CP は減算してフラグのみ
- INC/DEC (HL) はメモリ read-modify-write（3 M-cycle）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cpu.fs`、SM83 命令表（references.md の gb-opcodes。**各命令のサイクル数はこの表に従う**）
**完了条件 (DoD)**: `tests/cpu_test.odin` に ADC/SBC のフラグ境界（キャリー跨ぎ）テストを追加し全パス。実装済み命令のサイクル数が命令表と一致（テストで数命令サンプル確認）。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: ハーフキャリーの計算は `(a & 0xF) + (b & 0xF) + carry > 0xF`。SBC は借りの向きに注意。
**依存**: T1-2

---

### T1-4: 16bit 命令・スタック・分岐

- [x] 完了

**目的**: LD rr,nn / ADD HL,rr / INC/DEC rr / PUSH/POP / JP/JR/CALL/RET/RST / LD SP 系を実装する。
**作るもの**: `src/core/cpu.odin` に追加。
- 条件分岐（JP cc / JR cc / CALL cc / RET cc）は**成立時と不成立時でサイクル数が違う**（命令表の 2 値を正確に）
- ADD SP,e8 / LD HL,SP+e8 のフラグは**下位バイトの 4bit/8bit 桁上がり**（Z=0, N=0）
- 内部処理サイクル（例: ADD HL,rr の +4、PUSH の SP 調整 +4）は `bus_tick(bus, 4)` を明示的に呼んで表現する
**参照**: 同上
**完了条件 (DoD)**: 単体テストで PUSH→POP ラウンドトリップ、条件分岐の両パスのサイクル数を確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: ADD SP,e8 のフラグ計算は Blargg 03-op sp,hl が集中的に検査する。e8 は符号付き。
**依存**: T1-3

---

### T1-5: CB プレフィックス命令

- [x] 完了

**目的**: RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL/BIT/RES/SET の 256 命令を実装する。
**作るもの**: `src/core/cpu.odin` に `cpu_step_cb`。CB 命令は下位 3bit がオペランド（B,C,D,E,H,L,(HL),A）、上位でオペレーション、という規則的な構造なのでテーブル/計算でデコードできる。
- BIT n,(HL) は 12 T-cycle、他の (HL) 系は 16 T-cycle
**参照**: 同上、Pan Docs "CPU instruction set" の CB 表
**完了条件 (DoD)**: 単体テストで SWAP/BIT/RES/SET の代表ケースが全パス。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 非 CB の RLCA/RLA/RRCA/RRA は **Z フラグを常に 0** にする（CB 版 RLC A などは Z を普通に設定）。混同すると Blargg 09/10 で落ちる。
**依存**: T1-3

---

### T1-6: 残り命令（DAA・制御系）

- [ ] 完了

**目的**: DAA/CPL/SCF/CCF/NOP/STOP/HALT/DI/EI と未定義オペコードの処理を実装し、命令セットを完成させる。
**作るもの**:
- DAA: N フラグで加算/減算後を区別する標準アルゴリズム（BubiBoy Cpu.fs の DAA 実装を移植するのが確実）
- HALT: `cpu.halted = true`（起床ロジックはフェーズ 2。今は割り込みがないので単純化で可）
- EI/DI: `ime` フラグ操作（EI の 1 命令遅延はフェーズ 2 で正確化）
- STOP: 今は NOP 扱い + ログ（正式対応はフェーズ 6 のダブルスピード）
- 未定義オペコード（0xD3 等 11 個）: エラーログを出して停止フラグを立てる
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cpu.fs`（DAA）、Pan Docs "DAA"
**完了条件 (DoD)**: 全 245 + CB 256 オペコードが switch で網羅されている（default に到達したら panic ではなくエラーフラグ）。DAA の単体テスト（0x15+0x27→DAA=0x42 など BCD 加算 5 ケース）が全パス。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: DAA は最頻出のハマりどころ。C フラグの扱い（減算時はセット済み C を保持）に注意。Blargg 01-special が検出する。
**依存**: T1-4, T1-5

---

### T1-7: シリアル出力キャプチャ

- [ ] 完了

**目的**: Blargg テストの結果判定経路（シリアルポート）を作る。
**作るもの**: `src/core/serial.odin`:
- `0xFF01 (SB)` 書き込みで値を保持、`0xFF02 (SC)` に 0x81 が書かれたら SB の値を `serial_log: [dynamic]u8` に追記し、SC の bit7 をクリア
- bus.odin の IO 分岐から接続
- `serial_get_log(bus) -> string` を公開
**参照**: testing.md「Blargg 方式」、Pan Docs "Serial Data Transfer"
**完了条件 (DoD)**: 単体テストで「SB に 'H' → SC に 0x81 → ログに 'H'」を確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 転送完了割り込みは未実装でよい（Blargg は使わない）。フェーズ 2 で IF bit3 を接続。
**依存**: T1-2

---

### T1-8: テスト ROM ランナー

- [ ] 完了

**目的**: ヘッドレスでテスト ROM を実行し PASS/FAIL 判定する仕組みを tests/ に作る。
**作るもの**:
- `scripts/fetch_test_roms.sh` の中身: testing.md の表どおり Blargg（retrio/gb-test-roms をコミット固定で取得）を `tests/roms/blargg/` に配置。取得済みならスキップ
- `tests/rom_runner.odin`: `run_blargg_rom(path) -> Rom_Result`。emulator を作り ROM をロードし、
  タイムアウト 120,000,000 T-cycle まで step し、serial ログに "Passed"/"Failed" が出たら判定
- `tests/blargg_test.odin`: cpu_instrs 個別 11 本 + instr_timing の `@(test)` を列挙。**ROM ファイルが無ければ skip**（testing.md）
- `tests/expected_failures.odin`: まだ通らない ROM の許可リスト（当初は 12 本全部入れておき、通ったら外す）
**参照**: testing.md 全体
**完了条件 (DoD)**: `odin test tests -collection:bbl=src` が ROM あり/なし両方の環境で正常終了する。
**検証方法**:
```sh
odin test tests -collection:bbl=src                    # ROM なし → skip 扱いで成功
./scripts/fetch_test_roms.sh && odin test tests -collection:bbl=src   # ROM あり → 実行
```
**落とし穴**: cpu_instrs の**統合版 (cpu_instrs.gb) は MBC1 が必要**なのでフェーズ 4 まで許可リストに入れたままにする。個別 ROM（`individual/01-special.gb` など）は ROM-only なので今動く。
**依存**: T1-7

---

### T1-9: Blargg cpu_instrs 個別 11 本 + instr_timing 全パス

- [ ] 完了

**目的**: フェーズ 1 のマイルストーン。CPU 実装のバグを潰し切る。
**作るもの**: 新規コードではなく、テスト失敗を 1 本ずつデバッグして修正する。
- デバッグ手順: 失敗する ROM のシリアル出力全文をログに出す（どの命令グループが失敗か表示される）→ 該当命令のフラグ/サイクルを命令表と突き合わせ
- 通った ROM を `tests/expected_failures.odin` から外す
**参照**: 各 ROM の名前が検査対象を示す（01-special=DAA 等, 02-interrupts=**フェーズ 2 まで許可リスト残留可**, 03-op sp,hl, 04-op r,imm, 05-op rp, 06-ld r,r, 07-jr,jp,call,ret,rst, 08-misc, 09-op r,r, 10-bit ops, 11-op a,(hl)）
**完了条件 (DoD)**: 02-interrupts を除く個別 10 本 + instr_timing が PASS（02 は割り込み実装後のフェーズ 2 完了時に PASS させる）。許可リストは 02 と統合版のみ残る。
**検証方法**:
```sh
./scripts/fetch_test_roms.sh && odin test tests -collection:bbl=src
```
**落とし穴**: instr_timing はタイマー(DIV)を使うため、DIV の仮実装（16384Hz でフリーラン、bus_tick 内で加算）が必要になったらこのタスクで最小実装してよい（正確化はフェーズ 2 T2-3）。
**依存**: T1-6, T1-8

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-11 T1-1 完了: odin test tests -collection:bbl=src 全パス(13 tests)
2026-07-11 T1-2 完了: odin test tests -collection:bbl=src 全パス(21 tests)
2026-07-11 T1-3 完了: odin test tests -collection:bbl=src 全パス(31 tests)
2026-07-11 T1-4 完了: odin test tests -collection:bbl=src 全パス(43 tests)、./scripts/build_macos.sh --test も成功
2026-07-11 T1-5 完了: odin test tests -collection:bbl=src 全パス(52 tests)
