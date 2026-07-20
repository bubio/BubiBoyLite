# フェーズ21: APUスイープのオーバーフロー判定バグ修正(音声の実質的な原因)

## 実装体制

計画: Fable(調査・計画担当) / 実装: Sonnet サブエージェント(ユーザー指示)。
タスクごとに検証→検証ログ→ `T21-N:` 形式でローカルコミット(push なし)。

## 前提

- 依存フェーズ: なし(フェーズ5 APUの実装済み範囲に対するバグ修正)。
- 経緯(2026-07-20): フェーズ20(APUダウンサンプリングのアンチエイリアシング化)を実装・
  完了したが、ユーザーから「音は治っていない」との指摘があった。advisorに相談した結果、
  **フェーズ20の修正(点サンプリング→区間平均)は実在する改善だが、ユーザーが聴いている
  異常の実際の原因ではなかった**と判断した。スペクトルの高域エネルギー比率という指標は
  「滑らかにする」フィルタなら何であれ改善するため、根本的な信号生成(音程・チャンネルの
  有効/無効・エンベロープ等)が誤っている場合でも数値上は"改善"して見えてしまう、
  というのがadvisorの指摘。

### 調査のやり直し

`~/dev/_Emu/BubiBoy` の git log を apu/audio/sound/wave/noise 等でgrepし直したところ、
これまで見ていなかった重要なコミットが見つかった:

- **`8910dd5 Fix APU sweep overflow and length reloads`**(2026-06-07)。
  `docs/reference-provenance.md` への追記に「SameBoy `Core/apu.c` を、APUの長さレジスタ
  ロード・トリガー時のリロード仕様・**shift=0のときのCH1スイープオーバーフロー挙動**の
  参照に使った」と明記されている。

このコミットのdiffを精読し、BubiBoyLiteの `src/core/apu.odin` の `apu_sweep_clock`
(修正前341-376行目付近)と突き合わせた結果、**BubiBoyLiteの `apu_sweep_clock` は、
`sweep.period == 0` または `sweep.shift == 0` のとき、オーバーフロー判定の計算自体を
丸ごとスキップして early return していた**ことが判明した。しかし実機(SameBoy参照)・
BubiBoyの修正後実装は、**スイープタイマーが満了するたび、period・shiftの値に関わらず
必ずオーバーフロー計算を行う**。周波数を実際に適用する(`pulse1.frequency = new_freq` 等)
のは `shift != 0` のときだけだが、**オーバーフロー判定自体は shift==0 でも period==0 でも
常に走り、オーバーフローすればチャンネルを無効化する**、というのが正しい仕様。
BubiBoyLiteはこの「判定だけは常に走る」という部分を、period==0とshift==0の両方の
ケースで丸ごと落としていた。

### 実機相当での再現・検証

1. **最小レジスタレベル再現**(`bbl:core` を直接使うOdinプログラム、BubiBoyの回帰テスト
   `zero shift sweep still disables pulse channel on overflow` と同一のレジスタ値:
   NR10=0x20(period=2,shift=0) NR11=0x40 NR12=0xF0 NR13=0x00 NR14=0x84(trigger,
   freq=1024))で確認: トリガー直後は `enabled=true`、`apu_tick` でフレームシーケンサを
   7ステップ分進めても(sweepが発火する期間)**チャンネルが無効化されないまま**
   (`enabled=true` のまま)だった。BubiBoyの修正後ロジックならオーバーフロー
   (1024→2048)で無効化されるはずの場面。**BUGを直接再現・確定した**(T21-1で
   回帰テストとして`tests/apu_pulse_test.odin`に追加、修正前コードで実際に
   fail することを確認済み)。
2. **実ROMでの比較**: BubiBoyの `tools/BubiBoy.AudioCapture`(dotnet、既存)をビルドし、
   Prince of Persia (Japan).gb を実際に鳴らして音声をWAVキャプチャした
   (タイトル画面通過用にStartボタンを周期的に押すよう一時的にパッチ)。BubiBoyLite側も
   `bbl:core` 直叩きハーネスで同様に音声をキャプチャした。**BubiBoyLite側は
   post-intro(8秒目以降)のRMS音量がBubiBoy参照実装の約3〜4倍**(BubiBoyLite:
   RMS 3000〜6000台、BubiBoy参照: RMS 900〜1300台)で、ピーク振幅もBubiBoyLiteは
   高いまま張り付き、BubiBoyは途中で下がる、という明確な乖離を確認した。
   **本来ミュートされるべきチャンネルが鳴り続けている**という仮説と整合する結果
   (T21-3で修正後の再測定を実施、詳細は検証ログ参照)。

## 対応方針

### A. `apu_sweep_clock`(src/core/apu.odin)の修正

`sweep.period == 0` と `sweep.shift == 0` の2つの early return を削除し、タイマー満了
ごとに必ずオーバーフロー計算を行うようにする。周波数の実適用は従来どおり
`shift != 0` のときだけに限定する。

**`apu_trigger_pulse` は変更しない**。トリガー時のオーバーフロー判定を `shift != 0`
のときだけ行う現在の実装は、Pan Docsの"Trigger Event"仕様・dmg_sound
"06-overflow on trigger" テストの要求どおりで正しい(周期的な`apu_sweep_clock`とは
適用対象が異なる、混同しないこと)。修正対象は `apu_sweep_clock` のみ。

### B. 回帰テストの追加

`tests/apu_pulse_test.odin` に、Fableが確認した最小再現と同じ内容のテストを追加する:
NR10=0x20(period=2,shift=0,negate=0)・NR11=0x40・NR12=0xF0・NR13=0x00・NR14=0x84で
CH1をトリガー、フレームシーケンサを7ステップ(`bus_tick(FRAME_SEQUENCER_PERIOD)` を
7回)進め、`pulse1.enabled == false` になることを確認する(BubiBoyの
`~/dev/_Emu/BubiBoy/tests/BubiBoy.Core.Tests/ApuTests.fs` の
`zero shift sweep still disables pulse channel on overflow` に相当)。

「period==0かつshift==0(NR10=0x00、スイープ完全オフ)」のケースは、`apu_trigger_pulse`
で `sweep.enabled = period != 0 || shift != 0` によりトリガー時点でfalseになり、
`apu_sweep_clock` の先頭ガードで即returnするため、今回の修正の影響を受けないことを
確認するテストも追加する。

### C. 実測での効果確認(最重要、advisor指摘の「参照実装と比較」を実施すること)

Fableが使った検証手法を踏襲・再実行し、修正前後でBubiBoyの参照実装とのRMS/ピーク振幅の
乖離が縮まることを確認する。BubiBoyの `tools/BubiBoy.AudioCapture` をビルドし、
Prince of Persia (Japan).gb を Start/A の周期トグルでタイトル画面通過させながら30秒
キャプチャ。BubiBoyLite側も `bbl:core` 直叩きの最小ハーネス(scratchpad、リポジトリには
含めない)で同様にキャプチャ。両者のRMS/ピーク振幅を1秒ごとに比較し、修正前後で
乖離がどう変化したかを具体的な数値で記録する。参照実装と一致するかどうかが判断基準
(BubiBoyLite単体のスペクトル指標だけで判断しない)。

## 壊してはいけない既存資産

- `apu_trigger_pulse` のトリガー時オーバーフロー判定(shift!=0限定)は変更しない
- `apu_sweep_calculate` 自体の計算式は変更しない(呼び出しタイミング・ガード条件のみ修正)
- フェーズ20で追加した区間平均(アンチエイリアシング)ロジック・セーブステートの
  アキュムレータフィールドは無変更(有効な改善として残す)
- 既存の `odin test tests -collection:bbl=src` を全て通す
- `tests/savestate_test.odin` のround-trip/determinismテストを全て通す
  (sweep関連フィールドのバイト配置は変更しない)

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src        # 482件全パス(新規2件のsweep回帰テスト含む)
./scripts/build_macos.sh --test            # -o:speed ビルド+全テスト成功
./scripts/build_macos.sh --debug --test    # -debug ビルド+全テスト成功
```

加えて、BubiBoy参照実装(`tools/BubiBoy.AudioCapture`)とBubiBoyLite側の最小ハーネスで
Prince of Persia (Japan).gb をキャプチャし、修正前後でRMS/ピーク振幅の乖離が縮まる
ことをPython(numpy/wave)で確認する計画だった(検証ログ参照)。**実際にはT21-3で
確認したとおり、今回のキャプチャ条件(自動入力によるタイトル画面通過)ではCH1
スイープが一度もトリガーされず、この客観比較では改善を確認できなかった**
(T21-2のレジスタレベル回帰テストでは修正の効果を直接確認済み)。フェーズ21の
コード修正・単体回帰テスト・両ビルドは完了しているが、実ROM上での改善実測は
未達成のまま記録する(下記「未検証項目・残課題」参照)。

---

### T21-1: `apu_sweep_clock` の修正(A節)

- [x] 完了

**目的**: shift==0/period==0でもスイープタイマー満了ごとのオーバーフロー判定を必ず
行うようにする。
**作るもの**: `src/core/apu.odin` の `apu_sweep_clock`(341-376行目付近)から
`sweep.period == 0` / `sweep.shift == 0` の2つの early return を削除し、
`apu_sweep_calculate` を必ず呼び出す。周波数の実適用(`shadow_frequency`/
`frequency`/`timer`の更新、2回目のオーバーフロー判定)は `sweep.shift != 0` の
ブロック内に限定する。`apu_trigger_pulse`は変更しない。
**参照**: `~/dev/_Emu/BubiBoy` commit `8910dd5`(`src/BubiBoy.Core/Apu.fs` の
`clockSweep`、520行目付近)。Pan Docs "Sweep" の章。
**完了条件 (DoD)**: `odin test tests -collection:bbl=src` 既存480件全パス(回帰なし)。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: `apu_sweep_calculate` はshift==0のとき `delta = shadow_frequency >> 0 =
shadow_frequency` となり、負方向でなければ2倍加算になる(意図どおり、Pan Docsの
記述に基づく既存コメントのとおり)。
**依存**: なし

### T21-2: 回帰テスト追加(B節、shift=0オーバーフローの最小再現)

- [x] 完了

**目的**: T21-1で修正したバグが再発しないことを保証する回帰テストを追加する。
**作るもの**: `tests/apu_pulse_test.odin` に2件追加:
- `test_apu_sweep_zero_shift_periodic_clock_still_disables_on_overflow`:
  NR10=0x20・NR11=0x40・NR12=0xF0・NR13=0x00・NR14=0x84でCH1トリガー、
  `bus_tick(FRAME_SEQUENCER_PERIOD)` を7回実行後 `pulse1.enabled == false` を確認。
- `test_apu_sweep_fully_off_is_unaffected_by_overflow_fix`: NR10=0x00
  (period=0,shift=0)でトリガー後、`sweep.enabled == false`(トリガー時点で無効化)
  であることと、7ステップ後も `pulse1.enabled == true` かつ周波数不変であることを確認
  (今回の修正が影響しないことの確認)。
**参照**: `~/dev/_Emu/BubiBoy/tests/BubiBoy.Core.Tests/ApuTests.fs` の
`zero shift sweep still disables pulse channel on overflow`。
**完了条件 (DoD)**: 新規2件がパスすること。既存の `test_apu_sweep_overflow_on_trigger_disables_channel`/
`test_apu_sweep_periodic_clock_updates_frequency`/
`test_apu_sweep_negate_then_positive_disables_channel` が回帰しないこと。
**検証方法**: `odin test tests -collection:bbl=src`(482件)。加えて
`git stash push -- src/core/apu.odin` で修正前コードに戻した状態で新規テストのみを
`-define:ODIN_TEST_NAMES=...` で実行し、`test_apu_sweep_zero_shift_periodic_clock_still_disables_on_overflow`
が実際にfailすることを確認してから `git stash pop` で修正を復元した(テストが
バグを検出できることの直接確認)。
**落とし穴**: `sweep.enabled` はトリガー時の `period != 0 || shift != 0` で決まるため、
「period==0かつshift==0」の組み合わせのみが本修正の影響を受けない安全なケース。
period!=0かつshift==0(今回のバグの対象)は `sweep.enabled=true` になる点に注意。
**依存**: T21-1

### T21-3: 実測での効果確認(C節、BubiBoy参照実装とのRMS/ピーク比較)

- [x] 完了(ただし結論は計画時の想定と異なる。詳細は検証ログ・下記「結果」参照)

**目的**: 修正がユーザーの聴感上の問題(過大な音量で鳴り続けるチャンネル)を実際に
改善することを、BubiBoy参照実装との比較で客観的に確認する。
**作るもの**: 測定のみ(コード変更なし)。BubiBoyの `tools/BubiBoy.AudioCapture` を
ビルドし、Prince of Persia (Japan).gb をキャプチャ。BubiBoyLite側もscratchpad上の
`bbl:core` 直叩きハーネスでキャプチャ。両者を1秒ごとのRMS/ピーク振幅で比較する。
**参照**: 本フェーズ計画ファイル「対応方針C」節、フェーズ20 T20-1のハーネス手法。
**完了条件 (DoD)**: 修正前(BubiBoyLiteのpost-intro RMSがBubiBoy参照の約3〜4倍)と
比べ、修正後は乖離が大幅に縮まることを具体的な数値で記録する。
**検証方法**: `dotnet build tools/BubiBoy.AudioCapture/BubiBoy.AudioCapture.fsproj -c
Release`(一時パッチでStart周期押下を追加、検証後 `git checkout --
tools/BubiBoy.AudioCapture/Program.fs` で必ず元に戻す)。BubiBoyLite側は
scratchpadのOdinハーネスをビルドし直して同条件でキャプチャ。Pythonでwave読み込み・
1秒ごとRMS/ピーク比較。
**落とし穴**: `transmute([]u8)` は長さが再計算されず書き出しが半分に切り詰められる
バグがあるため使わないこと(`([^]u8)(raw_data(samples))[:len(samples)*2]` の形を
使う)。BubiBoy側の一時パッチは検証後に必ず元に戻すこと(恒久変更はしない)。

**結果(重要、計画時の想定と異なる。advisorに相談の上、正直に記録する)**:

BubiBoyの `tools/BubiBoy.AudioCapture` に一時パッチ(Program.fs、`capture` 関数内で
`phase = samples.Count % (Apu.SampleRate * 3 / 2); shouldPressStart = phase <
(Apu.SampleRate / 6)` としてStartボタンを周期押下、検証後 `git checkout --` で復元済み)
を当ててビルドし、Prince of Persia (Japan).gb を30秒キャプチャした
(`reference.wav`)。BubiBoyLite側はフェーズ20のscratchpadハーネス
(`core.joypad_set_button` でStart/Aを `phase := frame % 60; press := phase < 30`
で周期トグル)を再利用し、(a) 修正前コード(commit `bc983e7` の `apu.odin` に差し替えた
コピー、`harness_before`)と (b) 修正後コード(T21-1適用済み、`harness_after`)の
両方でビルド・30秒キャプチャした。

1秒ごとのRMSをPython(numpy/wave)で比較した結果、**`harness_before` と
`harness_after` のPCM出力はバイト完全一致だった**(`cmp -l` で差分0バイト)。
post-intro(8-30秒)平均RMSはref=2516.6、before=after=2538.2で、比率は
before/ref=after/ref=1.01(ほぼ一致、計画時に想定していた「修正前3〜4倍」は
このキャプチャ条件では確認できなかった)。

**原因の切り分け**: `apu_sweep_clock`/`apu_trigger_pulse`(修正前コード)に一時的な
`fmt.eprintln` トレースを仕込み、同じ30秒/60秒キャプチャを再実行したところ、
**この入力パターン(Start/Aの周期トグルでタイトル画面通過)による30〜60秒間、
CH1(スイープ付きパルス)は一度も `apu_trigger_pulse` でトリガーされていなかった**
(`apu_sweep_clock` は frame sequencer step2/6 のたびに7585回(60秒分)呼ばれていたが、
全て `pulse1.enabled=false && sweep.enabled=false` で先頭ガードにより即return、
`apu_trigger_pulse` のトリガーログは0件)。つまり、このキャプチャ条件では
**T21-1で修正した分岐(period==0/shift==0でのオーバーフロー判定スキップ)自体が
一度も実行されていない**ため、修正前後で出力が完全一致するのは論理的に整合している
(バグ修正が無効なのではなく、この検証シナリオがバグの発生条件に到達していない)。

**結論**: T21-1の修正はBubiBoyのcommit `8910dd5`(SameBoy `Core/apu.c` 参照)と
一致する形でオーバーフロー判定ロジックを正しくしており、T21-2のレジスタレベル
回帰テスト(shift=0でのオーバーフロー)で修正の効果を直接確認済み(バグを実際に
検出・修正できることは確定している)。しかし、**今回使った「Start/A周期トグルで
タイトル画面通過」という自動入力シナリオでは、Prince of Persia (Japan).gbの
最初30〜60秒間にCH1(スイープ付き矩形波)が一度もトリガーされず、実ROM比較では
修正の効果を観測できなかった**。計画ファイルに記載されている「BubiBoyLiteの
post-intro RMSがBubiBoy参照実装の約3〜4倍」という当初の観測(Fableによる)は、
本検証(同一のハーネス手法を再現)では再現されなかった。両ツールの入力パターンが
完全には一致していない(BubiBoyLite側はStart/Aを0.5秒周期、BubiBoy側はStartのみを
1.5秒周期で1/6秒間)という方法論上の差異もあり、実ROM上でのクロスエミュレータ比較
(ref比 1.01倍)自体の精度にも留保が必要(この差異はbefore/after比較には影響しない、
同一ハーネス・同一入力での比較のため)。

**結論として、実ROMでのRMS比較による「乖離が縮まったことの実測確認」という当初の
受け入れ基準は、このキャプチャ条件下では確認できなかった(該当コードパスが
実行されていないため)**。ユーザーが実際に聴いている音の異常が今回の修正で解消
されるかどうかは、実際のゲームプレイ(タイトル画面通過だけでなく、ゲーム内で
キャラクターのジャンプ/剣戟等、CH1スイープを使うと思われる効果音が発生する場面)
での検証が必要であり、本フェーズでは未実施(残課題、下記「未検証項目」参照)。
**依存**: T21-1, T21-2

### T21-4: 仕上げ

- [x] 完了

**目的**: フェーズ21のマイルストーン。
**作るもの**: デバッグと検証のみ。
**完了条件 (DoD)**: `odin test` 全パス + 両ビルド(`-o:speed`/`-debug`)成功 +
`tests/savestate_test.odin` round-trip/determinism回帰なし + phase-21 docs記録 +
PLAN.md更新。
**検証方法**: `./scripts/build_macos.sh --test` / `--debug --test`、
`odin test tests -collection:bbl=src`。
**落とし穴**: なし。
**依存**: T21-1〜T21-3

---

## 検証ログ

(タスク完了ごとに1行追記)

2026-07-20 T21-1 完了: `src/core/apu.odin` の `apu_sweep_clock` から
`sweep.period == 0` / `sweep.shift == 0` の2つのearly returnを削除。タイマー満了ごとに
必ず `apu_sweep_calculate` を呼び出し、オーバーフロー時は即 `pulse1.enabled = false`。
周波数の実適用(`shadow_frequency`/`frequency`/`timer`更新、2回目のオーバーフロー
判定)は `sweep.shift != 0` のブロックに限定。`apu_trigger_pulse`は無変更。
`odin test tests -collection:bbl=src` 既存480件全パス(回帰なし)。

2026-07-20 T21-2 完了: `tests/apu_pulse_test.odin` に
`test_apu_sweep_zero_shift_periodic_clock_still_disables_on_overflow`(shift=0でも
周期的なapu_sweep_clockのオーバーフロー判定が必ず行われることの確認)と
`test_apu_sweep_fully_off_is_unaffected_by_overflow_fix`(period=0かつshift=0は
今回の修正の影響を受けないことの確認)を追加。`odin test tests -collection:bbl=src`
482件全パス。加えて `git stash push -- src/core/apu.odin` で修正前コードに戻し、
新規テストのみ実行したところ `test_apu_sweep_zero_shift_periodic_clock_still_disables_on_overflow`
が実際に「shift=0でも周期的なapu_sweep_clockのオーバーフロー判定は必ず行われ
チャンネルが無効化される」というメッセージでfailすることを確認(`test_apu_sweep_fully_off_is_unaffected_by_overflow_fix`
はfailしなかった、想定どおり)。`git stash pop` で修正を復元し、482件全パスに戻る
ことを再確認した。

2026-07-20 T21-3 完了(結論は計画時の想定と異なる、詳細はT21-3タスク詳細「結果」節・
下記「未検証項目」参照): `~/dev/_Emu/BubiBoy` の `tools/BubiBoy.AudioCapture` に
Start周期押下の一時パッチを当ててビルドし(`dotnet build ... -c Release`)、
Prince of Persia (Japan).gb を30秒キャプチャ(`reference.wav`)。検証後
`git checkout -- tools/BubiBoy.AudioCapture/Program.fs` でBubiBoy側リポジトリを
元に戻したことを `git status --short` で確認済み。BubiBoyLite側はフェーズ20の
scratchpadハーネスを使い、修正前コード(`bc983e7`の`apu.odin`)と修正後コード
(現行)の両方でビルドし30秒キャプチャ。Python(numpy/wave)で1秒ごとのRMSを比較した
結果、**修正前後のPCM出力がバイト完全一致**(`cmp -l`で差分0バイト)。
post-intro(8-30秒)平均RMSはref=2516.6、before=after=2538.2、比率は約1.01倍で
「修正前3〜4倍」という計画時の想定は再現しなかった。原因を切り分けるため
`apu_sweep_clock`/`apu_trigger_pulse`に一時トレースを仕込み再実行したところ、
このキャプチャ条件(Start/A周期トグルでタイトル画面通過)の30〜60秒間、
**CH1が一度も`apu_trigger_pulse`でトリガーされていない**ことを確認した
(`apu_sweep_clock`は7585回呼ばれたが全て`pulse1.enabled=false`で先頭ガード
即return)。つまり今回のキャプチャシナリオはT21-1で修正した分岐に到達しておらず、
修正前後で出力が一致するのは論理的に整合している。T21-2のレジスタレベル回帰
テストで修正の効果自体は直接確認済みだが、**実ROムでの「乖離が縮まったことの
実測確認」という当初の受け入れ基準は今回のキャプチャ条件下では確認できなかった**
(advisorに相談の上、正直に記録)。

2026-07-20 T21-4 完了: `./scripts/build_macos.sh --test`(-o:speed)/
`./scripts/build_macos.sh --debug --test`の両方で482件全テストがパス。
`tests/savestate_test.odin`の`test_savestate_write_is_deterministic`/
`test_savestate_round_trip_restores_all_fields`/
`test_savestate_deterministic_replay_after_restore`/
`test_savestate_deterministic_replay_after_restore_cgb`個別実行でも全パス
(sweep関連フィールドのバイト配置変更なし、回帰なし)。フェーズ21実装完了。
ただし実ROMでの改善実測(T21-3)は当初想定どおりの結果が得られておらず、
ユーザーの聴感上の問題の実質的な解消を保証するものではない(下記「未検証項目」
参照、Fableへのエスカレーションが必要)。

## 未検証項目・残課題(正直に記録)

1. **実ROMでのRMS改善の実測確認**: T21-3で使った自動入力シナリオ(Start/A周期
   トグルでタイトル画面通過)では、Prince of Persia (Japan).gbの最初30〜60秒間に
   CH1(スイープ付き矩形波)が一度もトリガーされず、今回の修正が実行されるコード
   パスに到達しなかった。ゲーム内でCH1スイープを使うと思われる場面(ジャンプ/
   剣戟等の効果音、より長時間のプレイ、実際の移動入力を伴うプレイなど)での
   再測定が必要。
2. **実機(人間の耳)での聴覚確認**: 「残」。本フェーズはコードレベルの修正・
   単体回帰テスト・自動キャプチャでの実測比較まで実施したが、ユーザー自身が
   実際にゲームを操作して音を聴いての確認は未実施。
3. Prince of Persia以外のROM、および他のGBC対応表記載タイトルでのCH1スイープ
   使用箇所の回帰確認は未実施(本フェーズのスコープ外、必要なら別フェーズで
   対応)。
