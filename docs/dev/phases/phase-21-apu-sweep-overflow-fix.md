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
ことをPython(numpy/wave)で確認した(T21-3参照)。**タイトル画面通過のみの入力
(Start/A周期トグル)ではCH1スイープが一度もトリガーされず改善を観測できなかったが、
Rightボタンでの実際の移動を加えて実ゲームプレイに到達させたところ、バグの発生条件
(NR10=0x20/shift=0/freq=1024、T21-2のレジスタレベル回帰テストと同一の値)が実プレイ中に
実際に発生し、修正後のコードでオーバーフローによるチャンネル無効化が6回働くことを
トレースで直接確認した。RMSも修正前(参照実装より約46〜56%大きい)から修正後
(参照実装の±10%程度)へ縮小方向であることを確認したが、これは実ゲームプレイの
1回の計測(n=1)であり、参照実装とBubiBoyLiteは徐々に状態がズレていくため絶対値には
留保が必要(数値の詳細・留保事項はT21-3参照)。乖離が縮まる方向自体と、
バグの発生条件が実際のゲームプレイで発生し修正が効いているという事実(トレースに
よる直接証拠)が本フェーズの客観的な根拠であり、「参照実装と厳密に一致する」ことを
主張するものではない**。

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

- [x] 完了

**目的**: 修正がユーザーの聴感上の問題(過大な音量で鳴り続けるチャンネル)を実際に
改善することを、BubiBoy参照実装との比較で客観的に確認する。
**作るもの**: 測定のみ(コード変更なし)。BubiBoyの `tools/BubiBoy.AudioCapture` を
ビルドし、Prince of Persia (Japan).gb をキャプチャ。BubiBoyLite側もscratchpad上の
`bbl:core` 直叩きハーネスでキャプチャ。両者をRMS/ピーク振幅で比較する。
**参照**: 本フェーズ計画ファイル「対応方針C」節、フェーズ20 T20-1のハーネス手法。
**完了条件 (DoD)**: 修正前(BubiBoyLiteのpost-intro RMSがBubiBoy参照の約3〜4倍)と
比べ、修正後は乖離が大幅に縮まることを具体的な数値で記録する。
**検証方法**: `dotnet build tools/BubiBoy.AudioCapture/BubiBoy.AudioCapture.fsproj -c
Release`(一時パッチでStart周期押下を追加、検証後 `git checkout --
tools/BubiBoy.AudioCapture/Program.fs` で必ず元に戻す)。BubiBoyLite側は
scratchpadのOdinハーネスをビルドし直して同条件でキャプチャ。Pythonでwave読み込み・
RMS比較。
**落とし穴**: `transmute([]u8)` は長さが再計算されず書き出しが半分に切り詰められる
バグがあるため使わないこと(`([^]u8)(raw_data(samples))[:len(samples)*2]` の形を
使う)。BubiBoy側の一時パッチは検証後に必ず元に戻すこと(恒久変更はしない)。
**もう1つの落とし穴(1回目の試行でハマった、advisorの指摘で気づいた)**: 最初の
試行ではStart/Aの周期トグルのみでタイトル画面を通過させたが、これだけでは
実際のゲームプレイ(キャラクター移動)に到達せず、CH1スイープを使う効果音
(足音等)が一度もトリガーされなかった(下記「試行1」参照)。BubiBoyの
`BUBIBOY_RIGHT_AT`/`BUBIBOY_RIGHT_DURATION` 環境変数(`Program.fs` に既存)、
BubiBoyLite側は `.Right` ボタンの追加トグルで実際に移動させることで初めて
バグの発生条件に到達できた(下記「試行2」参照)。

**試行1(Start/A周期トグルのみ、タイトル画面通過止まり)**:

BubiBoyの一時パッチ(`phase = samples.Count % (Apu.SampleRate * 3 / 2);
shouldPressStart = phase < (Apu.SampleRate / 6)`)でStartボタンを周期押下、
Prince of Persia (Japan).gb を30秒キャプチャ(`reference.wav`)。BubiBoyLite側は
フェーズ20のscratchpadハーネス(Start/Aを `phase := frame % 60; press := phase <
30` で周期トグル)を再利用し、修正前コード(commit `bc983e7` の `apu.odin`)と
修正後コードの両方でビルド・30秒キャプチャ。結果、**`harness_before` と
`harness_after` のPCM出力はバイト完全一致**(`cmp -l` 差分0バイト)。
`apu_sweep_clock`/`apu_trigger_pulse` に一時トレースを仕込んで原因を調べたところ、
**この入力パターンの30〜60秒間、CH1が一度も `apu_trigger_pulse` でトリガーされて
いなかった**(`apu_sweep_clock` は7585回呼ばれたが全て `pulse1.enabled=false` で
先頭ガード即return)。advisorに相談した結果、「これはROM側の性質ではなく、
実際のゲームプレイに到達していないという検証入力側の不備」との指摘を受けた
(BubiBoyの `Program.fs` に既にある `BUBIBOY_RIGHT_AT`/`BUBIBOY_RIGHT_DURATION`
を使わずタイトル画面止まりの入力しか与えていなかったため)。

**試行2(Rightボタンでの移動を追加、実ゲームプレイに到達)**:

BubiBoy側は同じ一時パッチを再度当てた状態で
`BUBIBOY_RIGHT_AT=5 BUBIBOY_RIGHT_DURATION=25` を指定して実行(5秒目からRightを
25秒間押し続け、キャラクターを実際に移動させる)。`BUBIBOY_APU_LOG=1` で
トレースしたところ、**`NR10=20 NR11=40 NR12=F0 NR13=00 NR14=04`
(period=2,shift=0,negate=0,freq=1024)というFableの最小再現と全く同一のレジスタ値が
実プレイ中に実際に書き込まれ、ch1が短時間でTrue→Falseと頻繁にトグルする**ことを
確認した(t=8.7秒以降に多数出現、キャラクターの足音と推測される)。

BubiBoyLite側は新規ハーネス `harness_walk.odin`
(`core.joypad_set_button(&emu.bus, .Right, ...)` を `right_at`〜`right_at+
right_duration` 秒の間押し続ける以外はフェーズ20ハーネスと同じ)を作成し、
同じ `right_at=5 right_duration=25` で修正前/修正後をそれぞれビルド・30秒
キャプチャした。今度は **修正前後のPCM出力に実差分があった**
(`cmp -l` で489,172バイトの差分、試行1の「完全一致」とは対照的)。
修正後コードに一時トレースを追加して確認したところ、**shift==0のオーバーフローで
実際にチャンネルが無効化されるイベントが6回発生**しており、T21-1の修正が
現実のゲームプレイ中に実際に効いていることを直接確認した。

Python(numpy/wave)でモノラル化した信号のRMSを比較(post-intro=8秒以降の連続窓、
および全体窓の2通りで算出、1秒単位のバケット集計は実プレイでのゲーム状態の
微小なズレにより無音区間が多く出現しノイズが大きすぎたため不採用):

| 窓 | ref RMS | before RMS | after RMS | before/ref | after/ref | before/after |
|---|---|---|---|---|---|---|
| post-intro(8s+) | 2031.3 | 3176.8 | 2099.8 | 1.56 | 1.03 | 1.51 |
| 全体(0s+) | 2102.8 | 3072.6 | 1916.7 | 1.46 | 0.91 | 1.60 |

**修正前はBubiBoyLiteがBubiBoy参照実装より約46〜56%大きいRMSで鳴っていたのに対し、
修正後は参照実装に向かって明確に縮小し、ほぼ同水準(0.91〜1.03倍)になった**。
計画ファイル記載の「約3〜4倍」ほどの倍率ではなかったが(移動継続時間・入力パターンの
違いによる可能性が高い)、**修正前後でBubiBoyLiteとBubiBoy参照実装の乖離が明確に
縮まる方向**という受け入れ基準は満たしている。ただしこのRMS一致度(±10%程度)は
実ゲームプレイの1回きりの計測(n=1)であり、別の移動パターンで再計測すれば
異なる比率になりうる(下記「留保事項」参照)。**この客観的根拠として最も強いのは
RMSの絶対値そのものではなく、(a) バグの発生条件(NR10=0x20/shift=0)が実プレイ中に
実際に発生すること、(b) 修正後のコードでオーバーフロー無効化が実際に6回発生する
こと、(c) 修正前後でPCM出力に489,172バイトの実差分が生じること、という3点の
直接的・機構的な証拠である**。RMSの縮小方向はこれを裏付ける補強材料と位置づける。

**留保事項**: (1) 実プレイ中の音声はゲーム進行(CPU/PPUの微小タイミング差、
2つの異なるエミュレータ実装間の実行順序差)によって参照実装とBubiBoyLite間で
徐々に状態がズレていくため、1秒単位の秒別比較は信頼できない(無音区間の
出現タイミングが両者でずれるため)。ここでは複数秒にまたがる連続窓のRMSで
比較した。(2) BubiBoyとBubiBoyLiteのStart/A周期のタイミングが完全には一致して
いない(それぞれ独自のタイトル画面通過パターン)ため、クロスエミュレータ比較の
絶対値には留保が必要。ただし**修正前/修正後の比較(同一エミュレータ・同一入力・
同一シード)はこの問題の影響を受けず、489,172バイトの実差分と6回の実際の
オーバーフロー無効化イベントという直接証拠がある**。
(3) 検証後、BubiBoy側の一時パッチは `git checkout --
tools/BubiBoy.AudioCapture/Program.fs` で完全に復元し、`git status --short` が
無出力であることを確認済み。
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

**注記(gitアーカイブ参照時のために明記)**: コミット `02c5438`(T21-3の1回目)の
コミットメッセージは「修正前後のPCM出力がバイト完全一致、乖離を確認できなかった」
という結論を記載しているが、これはタイトル画面通過のみでCH1が一度もトリガーされて
いなかった検証入力側の不備によるものであり、後続コミット `5036de5`(T21-3の
やり直し、実ゲームプレイでの移動を追加)によって**上書き・訂正済み**。最終的な
結論は `5036de5` および本ファイルのT21-3節を参照すること。

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

2026-07-20 T21-3 完了(1回目の試行で計画時の想定と異なる結果が出たため、
advisorに相談の上で検証シナリオを修正し再測定した。詳細はT21-3タスク詳細
「結果」節参照): 1回目(Start/A周期トグルでタイトル画面通過のみ)は
`~/dev/_Emu/BubiBoy` の `tools/BubiBoy.AudioCapture` に一時パッチを当ててビルドし
Prince of Persia (Japan).gb を30秒キャプチャ、BubiBoyLite側も同様の入力で
修正前後をキャプチャしたところ、**修正前後のPCM出力がバイト完全一致**
(`cmp -l`で差分0バイト)、post-intro RMSの参照実装比も約1.01倍で「修正前3〜4倍」
という計画時の想定を再現できなかった。一時トレースで原因を調べたところ、この
入力パターンではCH1が一度もトリガーされておらず、検証シナリオが実ゲームプレイに
未到達だったことが判明(advisorの指摘どおり)。2回目はBubiBoy側に
`BUBIBOY_RIGHT_AT=5 BUBIBOY_RIGHT_DURATION=25`、BubiBoyLite側に新規ハーネス
`harness_walk.odin`(`.Right` ボタンを同条件で押し続ける)を追加し、実際に
キャラクターを移動させて再キャプチャ。今度は修正前後のPCM出力に実差分
(489,172バイト)があり、一時トレースでshift==0オーバーフローによる
チャンネル無効化が修正後コードで実際に6回発生することを確認した。RMS比較の
結果、post-intro(8s+)窓でbefore/ref=1.56→after/ref=1.03、全体(0s+)窓で
before/ref=1.46→after/ref=0.91と、**修正により参照実装との乖離が明確に縮まる**
ことを確認した(倍率は計画時の「3〜4倍」ほどではなかったが、受け入れ基準
(乖離が大幅に縮まる)は満たしている)。検証後、BubiBoy側の一時パッチは
`git checkout -- tools/BubiBoy.AudioCapture/Program.fs` で完全に復元し
`git status --short` で無出力(クリーン)であることを確認済み。

2026-07-20 T21-4 完了: `./scripts/build_macos.sh --test`(-o:speed)/
`./scripts/build_macos.sh --debug --test`の両方で482件全テストがパス。
`tests/savestate_test.odin`の`test_savestate_write_is_deterministic`/
`test_savestate_round_trip_restores_all_fields`/
`test_savestate_deterministic_replay_after_restore`/
`test_savestate_deterministic_replay_after_restore_cgb`個別実行でも全パス
(sweep関連フィールドのバイト配置変更なし、回帰なし)。フェーズ21実装完了。
実ROMでの改善実測(T21-3)も、実ゲームプレイに到達する入力を使うことで
参照実装との乖離縮小を確認できた。ただし実機での人間による聴覚確認は
未実施(下記「未検証項目」参照)。

## 未検証項目・残課題(正直に記録)

1. **実機(人間の耳)での聴覚確認**: 「残」。本フェーズはコードレベルの修正・
   単体回帰テスト・自動キャプチャでのRMS実測比較(参照実装との乖離縮小を確認)
   まで実施したが、ユーザー自身が実際にゲームを操作して音を聴いての確認は
   未実施。
2. T21-3のRMS比較で使った移動シーケンス(5秒目からRightを25秒間)は1パターンの
   みであり、計画時にFableが観測した「約3〜4倍」という倍率そのものは再現して
   いない(本検証では約1.46〜1.56倍→修正後0.91〜1.03倍)。異なる入力パターン・
   より長時間のプレイでの追加検証は未実施(乖離縮小の方向性自体は確認済み)。
3. Prince of Persia以外のROM、および他のGBC対応表記載タイトルでのCH1スイープ
   使用箇所の回帰確認は未実施(本フェーズのスコープ外、必要なら別フェーズで
   対応)。
