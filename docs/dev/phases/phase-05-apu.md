# フェーズ 5: APU・オーディオ駆動同期

## 前提

- 依存フェーズ: 4（実ゲームでの確認に MBC が要る。APU 単体はフェーズ 2 完了時点でも着手可能）
- このフェーズで暫定の壁時計ペーシング（T3-6）を**オーディオ駆動ペーシング**に置き換える。architecture.md「タイミングモデル」参照。

## ゴール

4 チャンネルの APU を実装し、SDL2 オーディオで音を出し、音声消費速度でエミュレーション速度を制御する。
Blargg dmg_sound をパスし、実ゲームで音割れ・速度ドリフトなく動作する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # blargg dmg_sound 対象が PASS
./bbl <ゲーム>   # 音が正常、長時間プレイで音ズレなし（目視/耳視）
```

---

### T5-1: APU 骨格・フレームシーケンサ・制御レジスタ

- [x] 完了

**目的**: APU の駆動基盤と NR50/51/52 を作る。
**作るもの**: `src/core/apu.odin`:
- `apu_tick(apu, t_cycles)` を bus_tick から呼ぶ
- フレームシーケンサ: 512Hz（8192 T-cycle 毎）に step 0-7 を巡回。
  **length は step 0,2,4,6 / エンベロープは step 7 / スイープは step 2,6**
- NR52 (FF26): bit7=APU 電源（0 で全レジスタクリア・書き込み無視、NR52 自身と wave RAM は例外）、bit3-0=各 ch 動作中フラグ（読み取り専用）
- NR51 (FF25): ch毎の左右パンニング。NR50 (FF24): マスター音量
- 各 NR レジスタの**読み出しマスク**（未使用ビットは 1 で読める）を定数表で実装 — Blargg dmg_sound の 01-registers が最初に検査する
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs`（970 行。構造ごと移植推奨）、Pan Docs "Audio Registers"
**完了条件 (DoD)**: 単体テスト: 電源 off でレジスタクリア、読み出しマスク表の全レジスタ確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: NR52 電源 off 時も wave RAM は読み書き可能（DMG では length カウンタも保持）。読み出しマスク表: NR10=0x80, NR11=0x3F, NR12=0x00, NR13=0xFF, NR14=0xBF ... （Pan Docs の表を定数化）。
**依存**: なし

---

### T5-2: 矩形波チャンネル (ch1 / ch2)

- [x] 完了

**目的**: スイープ付き矩形波 (ch1) とスイープなし (ch2) を実装する。
**作るもの**: apu.odin:
- 周期タイマー: `(2048 - freq) * 4` T-cycle で 8 ステップのデューティ波形（12.5/25/50/75%）を進める
- length カウンタ（64-n、0 で ch 停止）、ボリュームエンベロープ（NRx2: 初期値/方向/周期）
- ch1 スイープ (NR10): 周期・方向・シフト。オーバーフロー (>2047) で ch 停止。**負方向スイープ後の正方向切替で停止**する仕様も
- トリガー (NRx4 bit7): length リロード、エンベロープ・スイープ初期化、DAC on なら ch 有効
- DAC: NRx2 上位 5bit が 0 なら DAC off = ch 無効
**参照**: 同上、Pan Docs "Sound Channel 1/2"
**完了条件 (DoD)**: 単体テスト: デューティパターン、length 満了で停止、エンベロープ増減、スイープオーバーフロー。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: トリガー時に length が 0 なら 64 にリロード。「次のフレームシーケンサ step が length を刻むタイミングか」で挙動が変わる obscure 挙動は dmg_sound 03-trigger が検査（BubiBoy の実装を忠実に移植するのが早い）。
**依存**: T5-1

---

### T5-3: 波形メモリチャンネル (ch3)

- [x] 完了

**目的**: wave RAM を再生する ch3 を実装する。
**作るもの**: apu.odin:
- FF30-FF3F の 16 バイト = 32 サンプル（上位ニブル先）。周期 `(2048 - freq) * 2` T-cycle
- 音量 (NR32): 0%/100%/50%/25%（シフト 4/0/1/2）
- length は 256-n（他 ch と長さが違う）
- DAC は NR30 bit7
**参照**: 同上、Pan Docs "Sound Channel 3"
**完了条件 (DoD)**: 単体テスト: ニブル順、音量シフト、length 256。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: ch3 動作中の wave RAM アクセス制限（DMG）は dmg_sound 09/10/12 が検査するが厳密実装は難しい。まず基本動作を固め、これらのテストは許可リスト残留可（理由コメント必須）。
**依存**: T5-1

---

### T5-4: ノイズチャンネル (ch4)

- [x] 完了

**目的**: LFSR ノイズの ch4 を実装する。
**作るもの**: apu.odin:
- 15bit LFSR: XOR(bit0, bit1) を bit14 に挿入して右シフト。NR43 bit3=1 なら bit6 にも挿入（7bit モード）
- 周期: `divisor(NR43 下位3bit) << shift(NR43 上位4bit)`。divisor 表: 0→8, 1→16, 2→32, ... n→n*16
- length・エンベロープは ch1/2 と同じ
**参照**: 同上、Pan Docs "Sound Channel 4"
**完了条件 (DoD)**: 単体テスト: LFSR 系列の先頭数値、7bit モード、divisor 表。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 出力は LFSR の **bit0 の反転**。
**依存**: T5-1

---

### T5-5: ミキサーと 48kHz サンプル生成

- [ ] 完了

**目的**: 4ch を混合して 48kHz ステレオ i16 サンプルを core 内リングバッファに蓄積する。
**作るもの**: apu.odin:
- ダウンサンプリング: 4194304 / 48000 ≈ 87.38 T-cycle 毎に 1 サンプル生成（固定小数点で誤差蓄積を防ぐ: `counter += 48000` して `>= 4194304` で採取・減算）
- 各 ch の DAC 出力 (0-15 → -1.0〜+1.0 相当) → NR51 パンニング → NR50 音量 → i16 へスケール（クリッピング付き）
- `apu_drain_samples(apu, dst: []i16) -> int`（architecture.md の公開 API）とリングバッファ（容量 8192 サンプル程度、あふれたら古い方を捨てる）
**参照**: 同上（Apu.fs のサンプル生成部）
**完了条件 (DoD)**: 単体テスト: 1 フレーム分 tick 後のサンプル数が 800 前後（70224/4194304*48000 ≈ 803.6）、無音時の DC オフセットが 0 近傍。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: DAC off (無効 ch) の出力は 0 ではなく「DAC 入力 0 の電位」。簡易実装では 0 でよいがポップノイズが気になったらハイパスフィルタを足す（BubiBoy 参照）。
**依存**: T5-2〜T5-4

---

### T5-6: SDL2 オーディオ出力とオーディオ駆動ペーシング

- [ ] 完了

**目的**: 音を出し、**T3-6 の壁時計ペーシングをオーディオ駆動に置き換える**。本エミュレータの速度制御の本体。
**作るもの**: `src/app/audio.odin` + main.odin 変更:
- `SDL_OpenAudioDevice`: 48000Hz, AUDIO_S16SYS, 2ch, samples=1024。コールバック方式で `apu_drain_samples` から供給。足りない分は無音で埋める（アンダーラン記録）
- メインループを置換: **「オーディオバッファ残量 < 目標（例: 3 フレーム分 ≈ 2400 サンプル）の間だけ `emulator_run_frame` を回し、満杯なら 1ms 待つ」**（BubiBoy RuntimePacing.fs の方式）。SDL_Delay(16) 方式のコードは削除
- 表示は最新フレームのみ（生成した中間フレームの描画はスキップしてよい）
- `--headless` では従来どおり全速実行
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.App/RuntimePacing.fs` + `EmulationRunner.fs`（audio-clocked 設計の実証実装）、architecture.md「タイミングモデル」
**完了条件 (DoD)**: 実ゲーム 5 分プレイで音の連続性が保たれ、映像速度が実機相当（60fps 近傍）。アンダーラン発生数をログで確認し定常状態で 0。
**検証方法**:
```sh
./bbl <ゲーム>   # 5 分プレイ、ログのアンダーラン数 0 を確認
```
**落とし穴**: コールバックとメインループの間はロック（SDL_LockAudioDevice）か SPSC リング。リングバッファの読み書きを雑にすると定期的なプチノイズになる。
**依存**: T5-5

---

### T5-7: Blargg dmg_sound パス

- [ ] 完了

**目的**: フェーズ 5 のマイルストーン。
**作るもの**: デバッグと修正のみ。
- fetch スクリプトに dmg_sound を追加。個別 ROM (01-registers, 02-len ctr, 03-trigger, 04-sweep, 05-sweep details, 06-overflow on trigger, 07-len sweep period sync, 08-len ctr during power, 11-regs after power) を目標に修正
- 09/10/12（wave RAM アクセス系）は許可リスト残留可（T5-3 の判断を踏襲、コメント必須）
- dmg_sound は結果をシリアルではなく**メモリ 0xA000 に書く**変種があるため、rom_runner に「0xA000 判定」（0xA001-3 = 0xDE,0xB0,0x61 のシグネチャ確認 → 0xA000 が 0x00 で PASS）を追加
**参照**: testing.md、Blargg ROM 同梱の readme
**完了条件 (DoD)**: 上記対象の dmg_sound が PASS し許可リストから外れている。
**検証方法**:
```sh
odin test tests -collection:bbl=src
```
**落とし穴**: dmg_sound は CGB では挙動が違う（cgb_sound が別にある）。DMG モードで実行すること。
**依存**: T5-1〜T5-5

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-12 T5-1 完了: `src/core/apu.odin` 新規作成(構造体・NR52電源セマンティクス・
読み出しマスク表・wave RAM・フレームシーケンサの巡回機構)。bus_tick から apu_tick を、
bus_io_read/write から apu_read_register/apu_write_register を呼ぶよう bus.odin に配線。
timer_write_div から apu_notify_div_write を呼ぶよう timer.odin に配線(DIV書き込み時の
フレームシーケンサへの影響、dmg_sound 07 用の土台)。ch1-4 の実挙動(トリガー・duty・
sweep・envelope・LFSR・ミキサー)はまだプレースホルダで常時無効(T5-2〜T5-5で追加、
T3-1がLYを固定0のままにしたのと同じ方針)。tests/apu_test.odin 6件追加(読み出しマスク、
NR52電源off/onでのステータス、電源offでのレジスタクリア/wave RAM保持/DMGのlengthデータ
書き込み例外、length_counterのoff/on跨ぎ保持、フレームシーケンサの8step巡回、FF15/FF1Fが
0xFFで読める)。既存 tests/bus_test.odin の「未実装IOレジスタ」テストが 0xFF10 を使っていて
T5-1実装と衝突したため、真に未使用な 0xFF08 に差し替え。
`odin build src/app -collection:bbl=src -out:bbl` 成功、
`odin test tests -collection:bbl=src` 231件全パス(新規6件含む)。

2026-07-12 T5-2 完了: apu.odin に ch1(スイープ付き)/ch2(スイープなし)矩形波の実挙動を
実装(デューティ8ステップ・length・エンベロープ・トリガー・DAC・スイープ)。obscure仕様は
Pan Docs "Audio details" を直接確認して実装: (1) NRx4書き込みでlength_enableを無効→有効に
切り替える際、次のフレームシーケンサstepがlengthを刻まないタイミングなら即座に1減算、
0になったらトリガーでない限り即ch停止。(2) トリガー時length=0のリロード(64)も同条件なら
63にする。(3) スイープのnegate計算後に正方向へ切替でch即停止(negate_calculated_since_trigger
で追跡)。(4) トリガー時のオーバーフロー即時判定(dmg_sound "06-overflow on trigger")。
実装中に見つけた誤り: 当初F#移植の記憶を頼りにshift=0でもスイープの周波数計算
(delta=shadow>>0=shadow自体)とオーバーフロー判定を無条件に行っていたが、これだと
NR10=0x00(スイープ完全オフ、shift=0)でトリガーするだけでch1が常にオーバーフロー扱いで
即停止してしまうバグがあった(duty_stepテストで実測して発覚、正規のGB挙動ではshift=0は
計算自体を行わない)。トリガー時・周期クロック時とも shift!=0 のときのみ計算する形に修正。
tests/apu_pulse_test.odin 新規10件(トリガーでのDAC有効/無効、DAC offでの即停止、length満了
での停止、duty_step前進、エンベロープ増加、ch2にスイープが効かないこと、トリガー時
オーバーフロー、周期スイープでの周波数更新、negate→positive切替での即停止)。
`odin build src/app -collection:bbl=src -out:bbl` 成功、
`odin test tests -collection:bbl=src` 241件全パス(新規10件含む)。

2026-07-12 T5-3 完了: apu.odin に ch3(波形メモリ)を実装。周期 `(2048-freq)*2` T-cycleで
position(0-31)を進める。`apu_wave_current_nibble(apu)`(公開関数)でFF30-FF3Fの16バイトを
32サンプル・上位ニブル先で読む。音量(NR32 bit6-5)は output_level(0-3)として保持し実際の
シフト適用はミキサー(T5-5)に委ねる。length は256-n(他chと異なる)。DACはNR30 bit7。
トリガーはNRx4共通のapu_apply_length_and_trigger(T5-2で実装済み)をそのまま流用し、
周期タイマー・positionのリセットのみch3固有。tests/apu_wave_test.odin 新規6件(ニブル順、
音量デコード、length=256-n、DAC有無でのトリガー、トリガーでのposition初期化、DAC offでの
即停止)。ch3再生中のwave RAMアクセス制限(DMG)はT5-3では未実装(T5-7で09/10/12を許可
リスト残留、理由コメント付きで対応予定、フェーズドキュメントの「落とし穴」どおり)。
`odin build src/app -collection:bbl=src -out:bbl` 成功、
`odin test tests -collection:bbl=src` 247件全パス(新規6件含む)。

2026-07-12 T5-4 完了: apu.odin に ch4(ノイズ)を実装。15bit LFSR: XOR(bit0,bit1)を
bit14に挿入して右シフト、NR43 bit3=1(7bitモード)ならbit6にも同じ値を書き込む。周期は
divisor(NR43下位3bit、表: 0→8,1→16,2→32,...n→n*16) << shift(NR43上位4bit)。length/
エンベロープ/トリガーはT5-2の共通ヘルパ(apu_apply_length_and_trigger)をそのまま流用。
LFSR系列の期待値はPythonで実装と同一アルゴリズムを独立に再現して求めた(検証目的の
セカンドオピニオン、tests/apu_noise_test.odin冒頭コメント参照)。出力(LFSR bit0の反転)の
実際の音量スケーリングはT5-5のミキサーで扱う(wave chのニブル読み出しと同様、生データへの
アクセス=LFSR状態は既にpublicフィールドなので追加ヘルパは不要)。
tests/apu_noise_test.odin 新規6件(トリガーでのLFSR初期化とDACゲート、15bit LFSR系列4ステップ、
7bit LFSR系列3ステップ、divisor表に基づく周期タイミング、length満了での停止、DAC offでの
即停止)。
`odin build src/app -collection:bbl=src -out:bbl` 成功、
`odin test tests -collection:bbl=src` 253件全パス(新規6件含む)。
