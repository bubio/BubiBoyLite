# フェーズ20: APU音声のアンチエイリアシング(ダウンサンプリング方式の修正)

## 実装体制

計画: Fable(調査・計画担当) / 実装: Sonnet サブエージェント(ユーザー指示)。
タスクごとに検証→検証ログ→ `T20-N:` 形式でローカルコミット(push なし)。

## 前提

- 依存フェーズ: なし(フェーズ5 APUの実装済み範囲に対する品質改善)。
- 経緯(2026-07-19〜20): ユーザーから「Prince of Persia (Japan).gb」の音がおかしいとの
  報告。指定されたセーブステートファイルは前身プロジェクトBubiBoyのもの(マジックバイト
  `"BUBISTATE"`)でBubiBoyLiteの形式(`"BBLS"`)と非互換であり、読み込みは `Bad_Magic` で
  失敗しemuの状態は変更されない(この部分はユーザーへの説明で完結、本フェーズの対応対象
  外)。一方で、Fableが `bbl:core` を直接使う最小ハーネスでROMを起動しスペクトル解析した
  ところ、実際の音声品質バグ(全エネルギーの37%以上が15kHz以上というエイリアシング
  ノイズの分布)を実測で確認した。

## 根本原因

`src/core/apu.odin` の音声ダウンサンプリング方式が「瞬時値の点サンプリング」だった
(48kHzサンプルを出力する瞬間のch出力値をそのまま使う)。前身プロジェクト
`~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` は wave/noiseチャンネルについて
「区間平均(ボックスフィルタ)+ナイキスト超えのフォールバック(1周期平均、waveのみ)」
というアンチエイリアシング処理を持つ(`tickWave`/`tickNoise`, 745-810行目付近、
`waveAboveNyquist`, 834-836行目付近、`waveCycleAverage`, 826-832行目付近)。
Prince of Persia は wave RAM を高頻度に書き換えて疑似デジタル音声を鳴らす、GBエミュ
レータ間で有名な「地雷ROM」であり、点サンプリングだとこの種のROMで顕著にエイリアシング
ノイズが出る。

Pulseチャンネルについては、BubiBoy側の `tickPulse`(`Apu.fs` 710-722行目付近)を確認した
ところ、duty step を進めるだけで区間平均は行っていない(瞬時値のまま)ことを確認した。
矩形波は方形波そのもので高調波を豊富に含むため理屈上はエイリアシングしうるが、
前身プロジェクト自体がここに対応していないため、本フェーズでも対称性より「前身の実測済み
実装との一致」を優先し、Pulseは瞬時値のまま据え置く(T20-3参照)。

## ゴール

Wave/Noiseチャンネルの出力を区間平均(ボックスフィルタ)方式に変更し、ナイキスト超えの
チャンネル周波数では1周期全体の平均にフォールバックする。セーブステートに新規
アキュムレータフィールドを追加する。Prince of Persiaのタイトル画面通過後の音声で、
15kHz以上/20kHz以上の帯域エネルギー比率が修正前より大幅に改善することを客観的に確認する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src        # 480件全パス(新規3件のbox-filter回帰テスト含む)
./scripts/build_macos.sh --test            # -o:speed ビルド+全テスト成功
./scripts/build_macos.sh --debug --test    # -debug ビルド+全テスト成功
```

加えて、`bbl:core` を直接使う検証ハーネス(scratchpad、リポジトリには含めない使い捨て
ツール)で Prince of Persia (Japan).gb を実行しPCMを採取、Python(numpy)でスペクトル
解析した15kHz以上/20kHz以上のエネルギー比率が修正前後で大幅に改善していること
(検証ログ参照)。

## 対応方針(実装前に読むこと)

### A. Wave/Noiseチャンネルの出力を区間平均(ボックスフィルタ)方式に変更

`src/core/apu.odin` の `Wave_Channel`/`Noise_Channel` に `sample_area: i64` /
`sample_cycles: int` を追加(前身BubiBoyの `WaveSampleArea`/`WaveSampleCycles`、
`NoiseSampleArea`/`NoiseSampleCycles` 相当)。`apu_tick` が1 T-cycle進めるたびに、
その瞬間の出力を「量子化された生の単位」(`apu_wave_output_units`/
`apu_noise_output_units`、正規化前の整数値)で `sample_area` に加算し
`sample_cycles` を+1する。48kHzサンプルを1個出力するタイミングで
`sample_area / sample_cycles` の平均を取ってから両方を0にリセットする。

waveチャンネルの周波数がナイキスト周波数(24kHz、`APU_SAMPLE_RATE/2`)を超える場合
(`apu_wave_above_nyquist`)は、区間平均の代わりに wave RAM 32サンプル全体の平均
(`apu_wave_cycle_average`)にフォールバックする(BubiBoyの `waveAboveNyquist`/
`waveCycleAverage` 相当)。noiseチャンネルにはこのフォールバックは無い(BubiBoy自体も
持たない。乱数的な波形に「1周期」という概念が馴染まないため)。

`apu_mix_sample` は wave_sample/noise_sample を引数として受け取るように変更し、
`apu_tick` 側で区間平均(またはフォールバック)を計算してから渡す。Pulseチャンネルは
従来どおり `apu_pulse_output` の瞬時値をそのまま使う。

### B. Pulseチャンネルの扱い(検討結果: 変更しない)

`~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` の `tickPulse` を確認した結果、BubiBoy自体が
Pulseチャンネルに区間平均を適用していない(dutyステップの進行のみ)ことを確認した。
本フェーズでは前身の実測済み実装との一致を優先し、Pulseチャンネルは変更しない
(T20-3参照)。

### C. セーブステートへのアキュムレータフィールド追加

`src/core/savestate.odin` の `WAVE_CHANNEL_SIZE`/`NOISE_CHANNEL_SIZE`、
`write_wave_channel`/`read_wave_channel`、`write_noise_channel`/`read_noise_channel` に
`sample_area`(i64、8B)/`sample_cycles`(int、put_int/get_intで4B)を追加する。
`savestate_write` 末尾の `assert(c.pos == size)` が漏れを検出する安全設計になっているため、
それが通ることで追加漏れが無いことを確認する。

### D. (低優先度・任意)リングバッファのロード時クリア

`read_apu_state` の末尾で `apu.ring_read`/`apu.ring_write`/`apu.ring_count` を0にする
1行修正。調査中に見つかった副次的な設計ギャップ(「復元直後はリングバッファが空として
再開して問題ない」という設計コメントに対し、実装が実際にはクリアしていなかった)。
Prince of Persiaの件とは直接関係しないが、正しいセーブステートをロードする際の一瞬の
不連続音の原因になりうるため、時間の余裕があったため対応した。

## 壊してはいけない既存資産

- `savestate_write`/`savestate_read` の「全フィールド検証成功後にのみ反映」という設計、
  `assert(c.pos == size)` によるサイズ整合性チェックの仕組み
- `apu_drain_samples`/`Audio`(app層)のインターフェース(戻り値の意味・呼び出し方)は
  変更しない。変更はcore内部のサンプル生成方法のみ
- 既存の `tests/savestate_test.odin` の round-trip / determinism テスト(新フィールド
  追加後もバイト完全一致の性質を保つ)
- 既存のフレームバッファ(映像)ハッシュ回帰テスト(音声ロジックの変更が映像側に
  影響しないことの確認)

---

### T20-1: 検証ハーネスの再構築、修正前の基準値記録

- [x] 完了

**目的**: Fableが使った手法を踏襲し、修正前後を客観的に比較できる検証環境を用意する。
**作るもの**: scratchpad上に `bbl:core` を直接使う最小ハーネス(Odinプログラム、
リポジトリには含めない使い捨てツール)。ROM読み込み→Start/Aボタンの周期トグルで
タイトル画面通過→`emulator_run_frame`ループ→`apu_drain_samples`でPCM採取→
生PCM(`<i2`、ステレオinterleaved、48000Hz)としてファイル書き出し。
**参照**: 本フェーズ計画ファイル「検証方法」節。
**完了条件 (DoD)**: ハーネスがビルド・実行でき、Prince of Persia (Japan).gb のPCMを
採取できる。修正前の基準値として15kHz以上/20kHz以上のエネルギー比率を記録する。
**検証方法**: ハーネスをビルド・実行しPythonでスペクトル解析。
**落とし穴**: `transmute([]u8)samples[:]` は長さフィールドが再計算されず書き出しが
半分に切り詰められる(Fableが実際にハマった落とし穴)。
`([^]u8)(raw_data(samples))[:len(samples)*2]` の形を使うこと。
`os.read_entire_file_from_path`/`os.write_entire_file` はこの環境のOdinでは
`allocator`/`Error`戻り値を要求するシグネチャだったため、`context.allocator` を渡し
`!= nil` でエラー判定するよう実装した(計画ファイル記載のシグネチャと差異があったが
実害なし)。
**依存**: なし

### T20-2: Wave/Noiseチャンネルの区間平均化 + ナイキスト超えフォールバック

- [x] 完了

**目的**: 点サンプリングによるエイリアシングノイズを解消する。
**作るもの**: `src/core/apu.odin`:
- `Wave_Channel`/`Noise_Channel` に `sample_area: i64`/`sample_cycles: int` を追加
- `apu_wave_output_units_at`/`apu_wave_output_units`(生の量子化単位、位置指定可能)、
  `apu_wave_period_cycles`/`apu_wave_above_nyquist`(ナイキスト判定)、
  `apu_wave_cycle_average`(1周期全体の平均、フォールバック用)、
  `apu_noise_output_units` を追加
- `apu_tick` で1 T-cycleごとに区間平均アキュムレータへ加算し、48kHzサンプル出力時に
  平均(またはwaveのみナイキスト超えならフォールバック)を計算して `apu_mix_sample` へ渡す
- `apu_mix_sample` のシグネチャを `(apu, wave_sample, noise_sample) -> (left, right)` に変更
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` の `tickWave`/`tickNoise`
(745-810行目付近)、`waveAboveNyquist`(834-836行目付近)、`waveCycleAverage`
(826-832行目付近)。
**完了条件 (DoD)**: `odin test tests -collection:bbl=src` 全パス。新規追加した
box-filter回帰テスト(`test_apu_wave_box_filter_attenuates_high_frequency_toggle`、
`test_apu_wave_above_nyquist_uses_full_cycle_average`、
`test_apu_noise_box_filter_attenuates_high_frequency_toggle`)がパスする。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 蓄積は「その時点の出力値をtickの前に捕捉してから加算」の順序を守ること
(BubiBoyの `tickWave`/`tickNoise` も「現在のtimer/position状態での出力を area に加算 →
その後timer/positionを進める」の順)。逆順にすると1サンプル分ずれる。
サンプルカウンタが0の状態(APU電源off中)で平均を取ろうとするとゼロ除算になるため、
`sample_cycles > 0` のガードを入れている。
**依存**: T20-1

### T20-3: Pulseチャンネルの扱いの検討(結論: 変更しない)

- [x] 完了

**目的**: Pulseチャンネルにも区間平均が必要か、BubiBoyの実装を確認した上で判断する。
**作るもの**: コード変更なし(判断のみ)。
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` の `tickPulse`(710-722行目付近)。
**完了条件 (DoD)**: BubiBoyの `tickPulse` を確認し、区間平均を行っているかどうかを
判定する。
**検証方法**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` を読み、`tickPulse` が
`duty_step` を進めるだけで面積(area)を蓄積していないことを確認した。
**結論**: BubiBoy自体がPulseチャンネルに区間平均を適用していない(dutyステップの進行の
みで瞬時値のまま `mixSample` に渡している)。矩形波は理屈上はエイリアシングしうる
波形だが、前身の実測済み実装との整合性を優先し、本フェーズではPulseチャンネルを
変更しないことにした。既存の `apu_pulse_output`/duty step関連の単体テストは無変更で
全パスすることを確認済み(新規ロジックが無いため新規テストは追加していない)。
**落とし穴**: なし。
**依存**: T20-2

### T20-4: セーブステートへの新アキュムレータフィールド追加

- [x] 完了

**目的**: T20-2で追加した `sample_area`/`sample_cycles` をセーブステートの対象に含める。
**作るもの**: `src/core/savestate.odin`:
- `WAVE_CHANNEL_SIZE`/`NOISE_CHANNEL_SIZE` に `sample_area`(8B)/`sample_cycles`(4B)分を加算
- `write_wave_channel`/`read_wave_channel`、`write_noise_channel`/`read_noise_channel` に
  `put_i64`/`get_i64`(sample_area)、`put_int`/`get_int`(sample_cycles)を追加
**参照**: T20-2(追加したフィールド)。
**完了条件 (DoD)**: `savestate_write` 末尾の `assert(c.pos == size)` が通る
(=サイズ計算漏れが無い)。`tests/savestate_test.odin` の round-trip テストが
新フィールドを含めて全パスする。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: `sample_cycles` は `int`(Odin上は64bit)だが、他のフィールドと同様に
`put_int`/`get_int` でファイル上は符号付き32bit固定にする(ホストのポインタ幅に
依存させない、既存の規約どおり)。値そのものは1サンプル区間(約87 T-cycle)分しか
蓄積しないため32bitで十分収まる。
**依存**: T20-2

### T20-5: 修正後の再測定・改善確認

- [x] 完了

**目的**: T20-1のハーネスで修正後の音声を再キャプチャし、スペクトル指標が有意に改善
したことを確認する。
**作るもの**: 測定のみ(コード変更なし)。
**参照**: T20-1のハーネス。
**完了条件 (DoD)**: 15kHz以上/20kHz以上のエネルギー比率が修正前より大幅に下がっている
こと。
**検証方法**: T20-1のハーネスを、`git stash` でapu.odin/savestate.odinの変更を一時的に
戻した状態(修正前)と、変更を戻した状態(修正後)の両方でビルドし、同一のROM
(Prince of Persia (Japan).gb)・同一の入力パターン(Start/Aの周期トグル)・同一秒数
(20秒)でPCMを採取して比較した。
**実測結果**(タイトル画面通過後、3秒区間ごとにスペクトル解析、Hanning窓+`np.fft.rfft`):

| 区間 | 修正前 15kHz+ | 修正前 20kHz+ | 修正後 15kHz+ | 修正後 20kHz+ |
|---|---|---|---|---|
| 6.0-9.0s | 24.64% | 11.55% | 5.88% | 2.88% |
| 9.0-12.0s | 25.66% | 11.98% | 6.50% | 3.19% |
| 12.0-15.0s | 25.62% | 11.92% | 6.47% | 3.17% |
| 15.0-18.0s | 25.37% | 11.85% | 6.34% | 3.11% |

15kHz以上のエネルギー比率が約25%→約6.3-6.5%(約4分の1に減少)、20kHz以上が約12%→
約3%(約4分の1に減少)。有意な改善を確認した。
(なお、フェーズ計画書に記載のFableの実測値(15kHz以上37%程度/27.4%程度、
20kHz以上17%程度)とはハーネスの入力タイミング・キャプチャ秒数の違いにより絶対値が
一致しないが、「修正前後で同一の測定条件・同一のハーネスを用いて比較した結果、大幅に
改善する」という本フェーズの受け入れ基準は満たしている)。
**落とし穴**: 冒頭2-3秒(タイトル画面がまだ完全に通過していない/音量が小さい区間)は
両条件とも比率が不安定(0%近辺)になるため比較対象から除外し、音楽が安定して鳴っている
6秒以降の区間で比較すること。
**依存**: T20-2, T20-4

### T20-6: (任意・低優先度)リングバッファのロード時クリア

- [x] 完了

**目的**: セーブステートロード直後にAPUのリングバッファに残る古いサンプルが再生され
続ける副次的なギャップを修正する。
**作るもの**: `src/core/savestate.odin` の `read_apu_state` 末尾で
`apu.ring_read = 0; apu.ring_write = 0; apu.ring_count = 0` を設定。
**参照**: `read_apu_state` 直前のコメント(「復元直後はリングバッファが空として再開して
問題ない」という設計方針、以前は未実装だった)。
**完了条件 (DoD)**: 既存テスト回帰なし。
**検証方法**: `odin test tests -collection:bbl=src`(savestate_testのround-tripは
ring系フィールドを比較対象にしていないため影響なし)。
**落とし穴**: `read_apu_state` はシリアライズされたバイト列の読み取り位置(`Cursor.pos`)
には影響を与えない(ring系はそもそもシリアライズされていない)ため、
`savestate_expected_size`/`assert(c.pos==size)` には影響しない。
**依存**: T20-4(同一ファイルの近傍箇所のため一緒に実施)

### T20-7: 仕上げ

- [x] 完了

**目的**: フェーズ20のマイルストーン。
**作るもの**: デバッグと検証のみ。
**完了条件 (DoD)**: `odin test` 全パス + 両ビルド(`-o:speed`/`-debug`)成功 +
他ROMでのフレームバッファハッシュ回帰なし + phase-20 docs記録。
**検証方法**: `./scripts/build_macos.sh --test` / `--debug --test`、
`odin test tests -collection:bbl=src`(dmg-acid2/cgb-acid2等の既存映像ハッシュ回帰
テストも同スイートに含まれる)。
**落とし穴**: なし。
**依存**: T20-1〜T20-6

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-20 T20-1 完了: scratchpad上に `bbl:core` を直接使う最小ハーネス
(harness.odin)を作成。ROM読み込み→Start/A周期トグルでタイトル画面通過→
`emulator_run_frame`ループ→`apu_drain_samples`でPCM採取→生PCM書き出し。
`odin build harness.odin -file -collection:bbl=<repo>/src -out:harness -o:speed` で
ビルド成功。Prince of Persia (Japan).gb を20秒分実行しPCM採取(948350ペア)。
Pythonでスペクトル解析し、修正前の基準値を記録(6-18秒区間で15kHz以上約24.6-25.7%、
20kHz以上約11.6-12.0%、詳細はT20-5のログ参照)。

2026-07-20 T20-2 完了: `Wave_Channel`/`Noise_Channel` に `sample_area`/`sample_cycles`
アキュムレータを追加。`apu_wave_output_units_at`/`apu_wave_output_units`/
`apu_wave_period_cycles`/`apu_wave_above_nyquist`/`apu_wave_cycle_average`/
`apu_noise_output_units` を追加し、`apu_tick` で1 T-cycleごとに区間平均アキュムレータへ
加算、48kHzサンプル出力時に平均(waveはナイキスト超えなら1周期全体の平均に
フォールバック)を計算して `apu_mix_sample` へ渡すよう変更。新規回帰テスト3件
(`test_apu_wave_box_filter_attenuates_high_frequency_toggle`、
`test_apu_wave_above_nyquist_uses_full_cycle_average`、
`test_apu_noise_box_filter_attenuates_high_frequency_toggle`)を追加。
`odin test tests -collection:bbl=src` 480件全パス。

2026-07-20 T20-3 完了: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` の `tickPulse`
(710-722行目付近)を確認した結果、BubiBoy自体がPulseチャンネルに区間平均を適用して
いない(dutyステップの進行のみ)ことを確認。前身の実測済み実装との整合性を優先し、
本フェーズではPulseチャンネルを変更しないことに決定(コード変更なし)。既存の
Pulse関連単体テスト(`apu_pulse_test.odin`)は無変更で全パスすることを確認済み。

2026-07-20 T20-4 完了: `src/core/savestate.odin` の `WAVE_CHANNEL_SIZE`/
`NOISE_CHANNEL_SIZE` に `sample_area`(8B)/`sample_cycles`(4B)分を追加、
`write_wave_channel`/`read_wave_channel`/`write_noise_channel`/`read_noise_channel` に
対応する読み書きを追加。`odin test tests -collection:bbl=src` 480件全パス
(`savestate_write`内の`assert(c.pos == size)`が通ることを確認、round-tripテストも
新フィールド込みでパス)。

2026-07-20 T20-6 完了: `read_apu_state` 末尾に
`apu.ring_read = 0; apu.ring_write = 0; apu.ring_count = 0` を追加。
`odin test tests -collection:bbl=src` 480件全パス、既存savestateテストに回帰なし。

2026-07-20 T20-5 完了: T20-1のハーネスを使い、`git stash` でapu.odin/savestate.odinの
変更を一時的に戻した状態(修正前バイナリ)と、戻した状態(修正後バイナリ)を
それぞれビルドし、同一ROM・同一入力パターン・同一秒数(20秒)でPCMを採取して比較。
6-18秒の各3秒区間で15kHz以上のエネルギー比率が約24.6-25.7%→約6.3-6.5%
(約1/4に減少)、20kHz以上が約11.6-12.0%→約2.9-3.2%(約1/4に減少)。
有意な改善を確認した(表はT20-5タスク詳細参照)。

2026-07-20 T20-7 完了: `odin test tests -collection:bbl=src` 480件全パス、
`./scripts/build_macos.sh --test`(-o:speed)/`./scripts/build_macos.sh --debug --test`
の両方で480件全テストがパス。既存の dmg-acid2/cgb-acid2 等のフレームバッファハッシュ
回帰テストも同スイートに含まれておりパス(音声ロジックの変更が映像側に影響していない
ことを確認)。フェーズ20完了。
