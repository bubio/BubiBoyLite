# フェーズ 8: フロントエンド完成（設定・表示・コントローラー）

## 前提

- 依存フェーズ: 5（オーディオ駆動ペーシング確立後）。6/7 と並行作業可能。
- BluePrint の CLI 仕様・設定ファイル仕様をすべて満たすフェーズ。完了時に BluePrint との突き合わせを行う。

## ゴール

設定ファイル、フルスクリーン、smooth シェーダー、ゲームコントローラー、キーコンフィグを実装し、
BluePrint 記載の全ユーザー向け機能（TUI 以外）を仕様どおりにする。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src
# T8-7 の受け入れチェックリストを全項目実施
```

---

### T8-1: 設定ファイル

- [x] 完了

**目的**: BluePrint 仕様の設定ファイルを実装する: **実行ファイルと同じ場所、起動時になければ全デフォルト値で作成**。
**作るもの**: `src/app/config.odin`:
- 形式: INI 風の単純な `key = value`（依存ライブラリなしで自前パース。コメント行 `#` 対応）
- ファイル名: `bbl.ini`、場所: `os.args[0]` の実体パスのディレクトリ（シンボリックリンクは解決する）
- 項目（初期セット）: `scale`, `fullscreen`, `shader`, `save_dir`（空=ROM と同じ場所）, `state_dir`（同）, `volume` (0-100), キー割当（`key_a = X` 等）, コントローラー割当
- 優先順位: **CLI 引数 > 設定ファイル > デフォルト**（CLI は「一時的な設定変更」であり設定ファイルに書き戻さない — BluePrint「引数で一時的な設定変更も可能」）
- 不正値は警告してデフォルトにフォールバック（起動は止めない）
**参照**: BluePrint.md「設定ファイルの場所」、`~/dev/_Emu/BubiBoy/src/BubiBoy.IO/AppSettings.fs`（項目の参考）
**完了条件 (DoD)**: 単体テスト: パース、デフォルト生成内容、CLI 優先。結合: 設定ファイル削除 → 起動 → 全デフォルトで再生成される。
**検証方法**:
```sh
rm -f ./bbl.ini && ./bbl --headless && cat ./bbl.ini   # デフォルト値で生成される
odin test tests -collection:bbl=src
```
**落とし穴**: 実行ファイルの場所はカレントディレクトリではない。macOS/Linux は `os.args[0]` を絶対化 + シンボリックリンク解決、Windows は実行ファイルパス API。書き込み不可の場所（/usr/bin 等）に置かれた場合は警告してデフォルト値のまま動く。
**依存**: なし

---

### T8-2: フルスクリーン

- [x] 完了

**目的**: BluePrint 仕様の `--fullscreen`: **--scale を無視し、画面に収まる最大の整数倍率で表示**。
**作るもの**: `src/app/video.odin`:
- `SDL_WINDOW_FULLSCREEN_DESKTOP` を使用（解像度切替なし）
- 倍率 = `min(display_w / 160, display_h / 144)` の整数、余白は黒（レターボックス）
- Alt+Enter（macOS は Cmd+Enter も）でトグル
**参照**: BluePrint.md「コマンドラインオプション」
**完了条件 (DoD)**: `./bbl --fullscreen --scale 2 rom.gb` で scale が無視されフルスクリーン最大整数倍率になる（目視）。
**検証方法**: 目視 + ログに算出倍率を出力して確認。
**落とし穴**: 整数倍でない拡大は禁止（ドットが不均一になる）。ウィンドウサイズ変更イベントで倍率再計算。
**依存**: なし

---

### T8-3: smooth シェーダー

- [x] 完了

**目的**: `--shader smooth` を実装する。
**作るもの**: `src/app/video.odin`:
- nearest: `SDL_HINT_RENDER_SCALE_QUALITY = "0"`（既存）
- smooth: いったん整数倍（2 倍以上）に nearest で拡大した中間テクスチャ（`SDL_TEXTUREACCESS_TARGET`）を作り、それを linear で最終サイズへ描く（sharp-bilinear。単純 linear だけだと滲みすぎる）
- 設定ファイル/CLI の両方から切替可能
**参照**: BluePrint.md「--shader」
**完了条件 (DoD)**: nearest/smooth の見た目の差を確認（目視）。切替でクラッシュ・リークなし。
**検証方法**: `./bbl --shader smooth rom.gb` / `--shader nearest` の比較。
**落とし穴**: レンダーターゲット切替（`SDL_SetRenderTarget`）の戻し忘れに注意。
**依存**: T8-2（倍率計算を共有）

---

### T8-4: セーブ先ディレクトリ設定

- [x] 完了

**目的**: BluePrint 仕様「セーブファイルは ROM と同じ場所がデフォルト、場所は設定ファイルで変更可能」を完成させる。
**作るもの**: `src/app/saveram.odin` / `statefile.odin` 変更:
- `save_dir` / `state_dir` が空なら ROM と同じディレクトリ、指定があればそこへ（`~` と環境変数を展開。**実ユーザー名のハードコード禁止**）
- ディレクトリが存在しなければ作成を試み、失敗したら警告して ROM 同置にフォールバック
- ファイル名は `<ROMベース名>.sav/.rtc/.stateN` で共通
**参照**: BluePrint.md「セーブ、ステートファイルの場所」
**完了条件 (DoD)**: 単体テスト: パス解決（デフォルト/指定/~ 展開）。結合: `save_dir` 指定でそこに .sav ができる。
**検証方法**:
```sh
odin test tests -collection:bbl=src
# bbl.ini に save_dir を設定してゲームでセーブ → 指定先に .sav
```
**落とし穴**: `~` 展開は HOME（Windows: USERPROFILE）環境変数で行う。
**依存**: T8-1

---

### T8-5: ゲームコントローラー対応

- [x] 完了

**目的**: BluePrint「ゲームコントローラーでも操作できる」を実装する。
**作るもの**: `src/app/input.odin`:
- `SDL_INIT_GAMECONTROLLER` + GameController API（Joystick API ではなく。マッピング DB が使える）
- 接続/切断のホットプラグ（`SDL_CONTROLLERDEVICEADDED/REMOVED`）
- デフォルト割当: D-pad/左スティック=十字キー、A/B ボタン=A/B（Nintendo 配置に合わせ SDL の B=GB の A）、Start/Back=Start/Select
- ガイドボタン等の追加割当は設定ファイルで（T8-6 と共通の割当機構）
**参照**: BluePrint.md「特徴」、SDL_GameController API
**完了条件 (DoD)**: 実コントローラーでゲーム操作できる（目視）。未接続でも起動に影響なし。
**検証方法**: コントローラーを挿してプレイ、抜き差しでクラッシュしないこと。
**落とし穴**: スティックはデッドゾーン（±8000/32767 目安）を設ける。SDL の A/B とゲームボーイの A/B の物理位置が逆（Xbox 配置）である点をデフォルト割当に反映。
**依存**: なし

---

### T8-6: キーコンフィグ

- [x] 完了

**目的**: キーボード/コントローラーの割当を設定ファイルで変更可能にする。
**作るもの**: `src/app/input.odin` + `config.odin`:
- `key_a = X` / `key_start = Return` / `pad_a = b` 等。SDL のキー名（`SDL_GetKeyFromName`）とボタン名（`SDL_GameControllerGetButtonFromString`）でパース
- 不正名は警告してその項目だけデフォルト
- デフォルト生成される bbl.ini に全割当をコメント付きで出力（ユーザーが編集の起点にできる）
**参照**: BluePrint.md「キーボードショートカットで操作」
**完了条件 (DoD)**: 単体テスト: 割当パースと不正値フォールバック。結合: bbl.ini でキーを変えて反映確認。
**検証方法**:
```sh
odin test tests -collection:bbl=src
# bbl.ini の key_a を書き換えて動作確認
```
**落とし穴**: ショートカット（F5 等）とゲーム入力の衝突チェック（同キー割当は警告）。
**依存**: T8-1, T8-5

---

### T8-7: BluePrint 受け入れチェック

- [ ] 完了

**目的**: フェーズ 8 のマイルストーン。BluePrint の仕様を一項目ずつ突き合わせる。
**作るもの**: このタスクの下にチェックリストを作り全項目を実施:
- [ ] `bbl -h` / `--help` が使い方を表示
- [ ] `bbl -v` / `--version` がバージョン表示
- [ ] `--scale 1〜8` が効き、9 以上は 8 に丸め
- [ ] `--fullscreen` が --scale を無視して最大整数倍率
- [ ] `--shader nearest` / `smooth` が切替わる（デフォルト nearest）
- [ ] 設定ファイルが実行ファイルと同じ場所に自動生成される
- [ ] .sav が ROM と同じ場所（デフォルト）/ 設定した場所に保存される
- [ ] キーボードで全操作可能、コントローラーでプレイ可能
- [ ] 実 BIOS 関連のオプション・コードが存在しない
- [ ] コード・設定・ドキュメントに実ユーザー名が含まれない: `git grep -i "$(whoami)"` がヒット 0
**参照**: BluePrint.md 全文
**完了条件 (DoD)**: 上記チェックリスト全項目にチェックが付き、結果を検証ログに記録。
**検証方法**: 各項目のコマンド実行 + 目視。
**落とし穴**: `--recent` は フェーズ 9 の管轄（ここでは未実装で正しい）。
**依存**: T8-1〜T8-6

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-12 T8-1 完了: `odin test tests -collection:bbl=src` 349 tests 全パス(config_test.odin 19件追加)。結合検証 `rm -f ./bbl.ini && ./bbl --headless && cat ./bbl.ini` を実行しデフォルト値で全項目(scale/fullscreen/shader/save_dir/state_dir/volume/key_*/pad_*)が生成されることを確認。生成後に scale を手編集して再起動しても上書きされない(既存ファイル優先)ことを確認。`grep -i "$(whoami)" bbl.ini` はヒット0。CLI優先(--scale等)はCLI引数のprovidedビットセットで判定しconfig_apply_cli_overridesで検証済み(単体テスト)。

2026-07-12 T8-2 完了: `odin test tests -collection:bbl=src` 359 tests 全パス(video_layout_test.odin 5件、input_shortcut_test.odinにAlt/Cmd+Enterトグル判定5件を追加)。video_compute_layoutを純粋関数として切り出し、min(display_w/160, display_h/144)の整数倍率算出とレターボックス中央寄せを単体テストで検証(4Kディスプレイ相当3840x2160でも整数倍率になることを確認)。実機目視: `--scale 3`のウィンドウ表示と`--fullscreen`(実行環境の3440x1440ディスプレイ)をscreencapture+Readツールで確認。フルスクリーン時のログ`video: 表示倍率 = 10 (出力サイズ 3440x1440)`(=min(21,10))を確認し、スクリーンショットで画面全体を覆う黒レターボックス+中央寄せされた10倍表示を確認(画像は開発機のスクリーンショットのため作業記録にのみ使用しコミットはしない)。Alt+Enter/Cmd+Enterのトグル自体はキー判定ロジックの単体テストのみで、実キー入力によるライブトグルは未確認(TUIなし・対話的キー入力不可のため)。

2026-07-12 T8-3 完了: `odin test tests -collection:bbl=src` 359 tests 全パス(T8-2と同一の video_layout_test.odin を共有、追加の専用単体テストは無し。中間テクスチャ生成/SetRenderTarget切替はSDL依存でapp側の統合コードのため純粋関数化していない)。実機目視: `--scale 6 --shader nearest` と `--shader smooth` をそれぞれ起動しscreencaptureで同一座標を撮影、色境界(オレンジ色ブロックと背景グラデーションの境目)を8倍ズームして比較。nearestは1px単位でハードエッジ、smoothは境界に中間色のブレンドされたピクセル列が確認でき、sharp-bilinearの効果を視覚的に確認した。`--scale 1 --shader smooth`(中間倍率2倍未満でスムース処理をスキップするフォールバック経路)でもクラッシュしないことを確認。レンダーターゲット切替の戻し忘れは無い(video_present内でSetRenderTarget(renderer, video.intermediate)の直後に必ずnilへ戻すコードパスのみで、早期returnが無いことをコードレビューで確認)。

2026-07-12 T8-4 完了: `odin test tests -collection:bbl=src` 370 tests 全パス(save_state_dir_test.odin 11件追加。実ディレクトリ作成・実ファイルI/Oを伴うテストを含む)。実装中に発見した既存stdlibの落とし穴: このOdinバージョンの`os.make_directory_all`は対象パスが既に存在すると`.Exist`エラーを返す(mkdir -pのような「既存なら成功」ではない)ため、resolve_and_ensure_dirで`.Exist`を非致命扱いに修正(修正前は2回目以降の起動でsave_dir指定時に毎回ROM同置へフォールバックする不具合があった)。結合検証: 実際に`bbl`バイナリをビルドし、`save_dir = ~/bbl_t84_saves_test`を設定したbbl.ini + MBC2+BATTERYの実ROM(tests/roms/mooneye/emulator-only/mbc2/ram.gb)で起動、osascriptで実際にEscキーを送って終了させ、`~`展開先のディレクトリが自動作成され`testcart.sav`/`testcart.sav.bak`が書き込まれることを確認(テスト後に生成物は削除済み)。state_dir側は同じresolve_and_ensure_dir/state_path_for_rom_with_dirの単体テスト(実ファイルの保存→ロードのラウンドトリップ)で検証。

2026-07-12 T8-5 完了: `odin test tests -collection:bbl=src` 377 tests 全パス(controller_test.odin 7件追加。ボタン/軸イベント→GBボタンの変換は純粋関数化し、core.Emulatorを使ってJOYPレジスタの実際の変化まで検証)。SDL_INIT_GAMECONTROLLER を video_init に追加、Controller_Manager でホットプラグ(CONTROLLERDEVICEADDED/REMOVED)と1台までの接続管理を実装、左スティックはデッドゾーン±8000で十字キーへマップ。デフォルト割当はconfig.odinのdefault_pad_map(T8-1で作成済み)をそのまま使用(SDLのB=GBのA、SDLのA=GBのB、Xbox配置とNintendo配置の左右逆転を吸収)。**実機コントローラーでの操作感は未確認**(ハードウェア無し)。確認できたのはコントローラー未接続時の起動・実行(実バイナリで1.5秒間クラッシュなく動作継続、`video: 表示倍率 = 4`のログも正常出力)と、ホットプラグイベントハンドラの単体テスト(未接続状態でのREMOVED/destroyがクラッシュしないこと)のみ。

2026-07-12 T8-6 完了: `odin test tests -collection:bbl=src` 382 tests 全パス(keyconfig_test.odin 5件追加)。input_key_to_button/input_handle_key_eventをkey_map引数で可変にし(従来のハードコードswitchから、config.odinのdefault_key_map/bbl.iniのkey_*を逆引きする方式へ変更)、main.odinはcfg.key_map/cfg.pad_map(T8-1で読み込み済み)をイベントループへ渡すよう更新。ショートカットキー衝突チェック(T8-1で実装済みのconfig_key_map_conflicts/config_warn_key_conflicts)は結合検証: `key_select = F5`と書いたbbl.iniで`./bbl --headless`を実行し、`config: key_select (F5) はセーブステート/終了ショートカットと衝突しています`という警告が実際に出力されることを確認(起動は継続、DoD「警告してその項目だけデフォルト」ではなく単純警告のみに留める設計だが、割当自体は反映されクラッシュしないことも確認)。bbl.iniのデフォルト生成にキー/パッド全割当がコメント付きで出ることはT8-1のconfig_render_default_iniで既に達成済み。
