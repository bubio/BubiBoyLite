# フェーズ 15: 操作の完全スラッシュコマンド化 + 設定の即時反映

## 前提

- 依存フェーズ: 14(固定レイアウトシェル。ゲーム中も alt screen 常時維持、完了済み)。
- 経緯: フェーズ14で固定レイアウトシェル(下部に区切り線+ステータス行+入力行、ゲーム中も
  alt screen 常時維持)は実現済み。ユーザーからの追加要望(2026-07-19):
  1. **ゲーム中も同じモードで動くこと** — 現状はまだ `+`/`-`/`1`-`4`/`s`/`l`/`p` の
     1キーホットキーが「入力バッファが空のときだけ」残っており(T14-5)、ホーム画面の
     コマンド体系と体験が異なる
  2. **音量操作なども常にスラッシュコマンドで行う** — 生ホットキーを廃止し、全操作を
     コマンド入力に統一
  3. **`/settings` の値変更を即座に反映してほしい** — 現状 `volume` のみ `audio_set_volume`
     で即時反映されるが、`scale`/`fullscreen`/`shader` は `live_cfg`/`bbl.ini` は更新される
     ものの実行中の SDL 表示には反映されず、次回起動時のみ適用される
  4. **入力行・ステータス行はターミナル最下部に固定** — 調査の結果これは T14 で既に実現済み
     (`tui_render_shell` が alt screen 内で毎フレーム `rows` を取得し、最下行=入力行、
     その上にステータス行・区切り線を配置。リサイズもポーリング検知で追従)。
     **追加実装は不要**、回帰しないことだけ確認する

本フェーズは 2 と 3 が実質的な変更対象。1 は 2 の実装結果として自動的に満たされる。
4 は現状維持の確認のみ。

## ゴール

ゲーム実行中の1キー生ホットキー(+,-,1-4,s,l,p)を完全廃止し、全操作をスラッシュコマンドに
統一する(旧ホットキーの利便性は `/volume up`・`/volume down` として残す)。`/settings`・`/set`
での scale/fullscreen/shader/volume 変更が実行中の SDL 表示へ即座に反映される。固定レイアウト
(入力行・ステータス行が最下部固定)のリグレッションが無いことを確認する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # game_input_route/parse_game_command/live_setting_kind 等のテスト PASS
./scripts/build_macos.sh --test       # -o:speed ビルド+全テスト成功
./bbl game.gbc                        # ゲーム中 s/l/p/+/-/1-4 を押しても入力行に文字が入るだけ、
                                       # /save /load /pause /volume up 等のコマンドで従来動作、
                                       # /settings で scale/fullscreen/shader を変更すると即座に反映
```

## 設計方針(実装前に読むこと)

- **A. 生ホットキーの廃止**: `game_input_route`(tui.odin)から「バッファ空なら
  `game_key_to_action` でホットキー化する」分岐を削除。`Game_Input_Route.Hotkey` バリアント、
  `Game_Action` enum、`game_key_to_action` を削除。main.odin の `case .Hotkey:` ブロックを削除。
  `/` は特別扱い不要になる(全 `.Char` が無条件で `.Editor` へ行くため)。
- **B. 音量の相対増減をコマンド化**: 旧ホットキー `+`/`-`(`AUDIO_VOLUME_STEP` ずつ増減、
  非永続)の利便性を残すため、`parse_game_command` に `volume up`/`volume down` を追加。
  `Game_Command_Kind` に `Volume_Up`/`Volume_Down` を追加し、main.odin の `.Submit` 分岐に
  旧ホットキーと全く同じ処理(`audio_adjust_volume` → `"Volume %d%%"`)を移植する。
  `/set volume <n>`(絶対値・永続化あり)とは別物として共存する。
- **C. scale/fullscreen/shader の即時反映**: `video.odin` に `video_set_fullscreen`(明示的に
  状態指定、`video_toggle_fullscreen` はこれを呼ぶようリファクタ)と `video_apply_scale`
  (`SetWindowSize`、フルスクリーン中は何もしない)を追加。
- **設定反映の一本化**: main.odin に `apply_live_setting(video, audio, key, cfg)` を新設し、
  `config_apply_set` 成功後の2箇所(設定ビューの `.Adjust`、`/set` コマンド)にあった
  「volume のときだけ audio_set_volume」という重複ロジックを、shader/fullscreen/scale も含めて
  一本化する。SDL 実呼び出しを含むため単体テスト不可(このリポジトリの既存方針:
  `video_compute_layout` のように実SDL呼び出しが無い部分だけをテスト対象にする、
  `video_layout_test.odin` 参照)。「どのキーがどの反映処理に対応するか」だけを
  `live_setting_kind(key) -> Live_Setting_Kind` として切り出し、これを単体テスト対象にする。
- **D**: 削除・整理対象のテスト(`game_key_to_action` 関連、`.Hotkey` 期待)を新仕様に書き換え。
  `Volume_Up`/`Volume_Down` のパーステスト、`live_setting_kind` のテストを追加。

## 壊してはいけない既存資産

- SDLウィンドウ側のショートカット(Alt+Enter フルスクリーン、F1-F5/F9 セーブ/ロード等)は
  本フェーズと無関係の別経路(端末キーではなくSDLキーイベント)。無変更
- alt screen 常時維持・固定シェルレイアウト(T14)は無変更。リグレッションしないことだけ確認
- opt-none 3点セット、context.allocator 方針、contextless write は無変更
- `/set` の対象キー(scale/fullscreen/shader/volume の4つ)は無変更。`config_apply_set` の
  バリデーション(範囲外は拒否)は無変更

---

### T15-1: game_input_route 簡素化(生ホットキー廃止)

- [x] 完了

**目的**: ゲーム中の1キー生ホットキーを完全に廃止し、全ての文字入力を入力行へ統一する。
**作るもの**: `src/app/tui.odin`:
- `game_input_route` から「バッファ空なら `game_key_to_action` でホットキー化する」分岐を削除
- `Game_Input_Route.Hotkey`、`Game_Action` enum、`game_key_to_action` を削除
- `src/app/main.odin` の `case .Hotkey:` ブロックを削除
**参照**: 旧 `game_input_route`(tui.odin 1782-1816行目)、旧 `game_key_to_action`
**完了条件 (DoD)**: 単体テストで s/l/p/+/-/1 等の文字がバッファ空/非空どちらでも `.Editor` を
返すことを検証できる。ビルド成功。
**検証方法**: `odin test tests -collection:bbl=src` + `./scripts/build_macos.sh`
**落とし穴**: `/` も無条件で `.Editor`(専用モードへのトリガーという特別扱いは無くなった)。
**依存**: なし

---

### T15-2: volume up/down コマンド(旧 +/- ホットキーの移植)

- [x] 完了

**目的**: 音量の相対増減(旧 `+`/`-` ホットキー)の利便性をスラッシュコマンドとして残す。
**作るもの**: `src/app/tui.odin` / `src/app/main.odin`:
- `parse_game_command` に `volume up`/`volume down` を追加、`Game_Command_Kind` に
  `Volume_Up`/`Volume_Down` を追加
- main.odin の `.Submit` 分岐に対応処理を追加(`audio_adjust_volume(&audio, ±AUDIO_VOLUME_STEP)`
  → `status_line_set_message` で `"Volume %d%%"`、旧ホットキーと同一ロジック)
**参照**: 旧ホットキー実装(削除済み、T15-1参照)、`AUDIO_VOLUME_STEP`(audio.odin)
**完了条件 (DoD)**: パーステストで `volume up`/`volume down`/`/volume up` が正しく解釈され、
`volume`単体・`volume 50`・`volume sideways` は Unknown であることを検証できる。
**検証方法**: `odin test tests -collection:bbl=src` + pty(`/volume up` で音量が
`AUDIO_VOLUME_STEP` 分増加し bbl.ini は変化しないこと)。
**落とし穴**: `/set volume <n>`(絶対値・永続化あり)と役割が異なる別コマンドであり、
`config_apply_set` は経由しない。
**依存**: T15-1

---

### T15-3: video_set_fullscreen / video_apply_scale

- [x] 完了

**目的**: scale/fullscreen の即時反映に使う SDL 操作を用意する。
**作るもの**: `src/app/video.odin`:
- `video_set_fullscreen(video, want) -> bool`(明示的に状態指定、既に一致していれば何もしない)
- `video_apply_scale(video, scale)`(`SetWindowSize`、フルスクリーン中は何もしない)
- `video_toggle_fullscreen` を `video_set_fullscreen(video, !video.fullscreen)` を呼ぶ形に
  リファクタ(戻り値/ログ挙動は変えない)
**参照**: 既存 `video_toggle_fullscreen`(video.odin)
**完了条件 (DoD)**: ビルド成功、既存 `video_compute_layout` テスト等の既存 video テストが
全パス(リグレッションなし)。
**検証方法**: `odin test tests -collection:bbl=src` + `./scripts/build_macos.sh`
**落とし穴**: SDL 実呼び出しのため単体テスト対象外(video_compute_layout 以外の既存方針どおり)。
**依存**: なし(T15-1と並行可)

---

### T15-4: apply_live_setting による即時反映の一本化

- [x] 完了(SDLウィンドウの実際のサイズ変化/フルスクリーン切替の目視は残、下記参照)

**目的**: `/settings`・`/set` での scale/fullscreen/shader/volume 変更を実行中の SDL 表示へ
即座に反映する。
**作るもの**: `src/app/main.odin`:
- `Live_Setting_Kind` enum + `live_setting_kind(key) -> Live_Setting_Kind`(純粋関数、
  単体テスト対象。key文字列→どの反映処理かの写像だけを切り出す)
- `apply_live_setting(video, audio, key, cfg)`(`live_setting_kind` で分岐し
  audio_set_volume/video.shader直接代入/video_set_fullscreen/video_apply_scaleを呼ぶ)
- 設定ビューの `.Adjust` 経由・`/set` コマンド経由の2箇所にあった
  「`set_ok && eff.key == "volume"` のときだけ `audio_set_volume`」という重複ロジックを
  `if set_ok { apply_live_setting(...) }` に統一
**参照**: `config_apply_set`(config.odin)、T15-3
**完了条件 (DoD)**: `live_setting_kind` の単体テストで4キー+不明キーの写像を検証できる。
pty でゲーム中 `/settings` の shader/fullscreen/scale 変更が即座に反映されることを確認する
(可能な範囲で自動検証、SDLウィンドウの実際の見た目の目視確認は残として記録)。
**検証方法**: `odin test tests -collection:bbl=src` + pty。
**落とし穴**: `apply_live_setting` 自体はSDL実呼び出しのため単体テスト対象外(上記参照)。
**依存**: T15-3

---

### T15-5: 仕上げ(コマンドオンリー回帰確認、固定レイアウト回帰確認、-o:speed 往復、docs記録)

- [ ] 完了(自動検証は完了・クラッシュなし。SDLウィンドウの実際のサイズ変化/フルスクリーン
      切替の目視確認のみ残、下記チェックリストと検証ログ参照。チェックは付けない)

**目的**: フェーズ15のマイルストーン。
**作るもの**: デバッグと検証のみ。チェックリスト:
- [x] ゲーム中に `s`/`l`/`p`/`+`/`-`/`1`-`4` を単独で押しても即時発火せず、入力行に文字が
      入るだけであること
- [x] `/save`・`/load`・`/pause`・`/resume`・`/slot N`・`/volume up`・`/volume down`・`/set` が
      全て従来どおり機能すること
- [x] 固定レイアウト(入力行・ステータス行が最下部固定、リサイズ追従)のリグレッションが
      無いこと
- [x] `-o:speed` フルラウンドトリップ、`-debug` ビルドも成功
- [ ] scale/fullscreen の実際のウィンドウサイズ変化・フルスクリーン切替の実機 GUI 目視確認
      (この開発環境には対話的GUIセッションが無く実施不能、T9-6/T12-6/T13-6/T14-6 と同じ
      既知の制約。ユーザーによる実機確認が必要)
**完了条件 (DoD)**: チェックリスト全項目 + 検証ログに記録。
**検証方法**: pty 全項目 + `-o:speed`/`-debug` 往復。
**落とし穴**: なし(既知の落とし穴は各タスクに記載済み)。
**依存**: T15-1, T15-2, T15-3, T15-4

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-19 T15-1 完了: `odin test tests -collection:bbl=src` 469件全パス(旧
`game_key_to_action` 関連テスト4本+`/`専用モードテスト1本+`.Hotkey`ルーティングテスト1本を
撤去し、`test_game_input_route_now_playing_chars_always_go_to_editor`(旧ホットキー文字
s,l,p,+,-,1 と q,/ が Now_Playing ビューでバッファ空/非空どちらでも常に `.Editor` を返す
こと)に置き換え)。`src/app/tui.odin` の `game_input_route` から「バッファ空なら
`game_key_to_action` でホットキー化する」分岐を削除し、`Game_Input_Route.Hotkey`・
`Game_Action`・`game_key_to_action` を削除。`src/app/main.odin` の `case .Hotkey:` ブロック
(旧 +/-音量・1-4スロット・s/l保存復元・p一時停止)を削除。`./scripts/build_macos.sh`
(-o:speed)成功。pty検証: ゲーム中に `s`,`l`,` `,`p`,`+`,`-`,`1` を続けて入力しても
Paused/Resumed/Volume/State saved 等のメッセージが一切発火せず、入力行に文字が
そのまま蓄積されること(`> sl p+-1_`)を確認、`/quit` で正常終了。

2026-07-19 T15-2 完了: `odin test tests -collection:bbl=src` 471件全パス(新規2件:
`volume up`/`volume down`/`/volume up` のパース、`volume`単体・`volume 50`・
`volume sideways` は Unknown)。`Game_Command_Kind` に `Volume_Up`/`Volume_Down` を追加、
`parse_game_command` に `volume up`/`volume down` の解釈を追加。main.odin の `.Submit`
分岐に旧ホットキーと全く同じロジック(`audio_adjust_volume(&audio, ±AUDIO_VOLUME_STEP)` →
`"Volume %d%%"`)を移植。`./scripts/build_macos.sh`(-o:speed)成功。pty検証(実ROM):
`/volume up` で音量が `AUDIO_VOLUME_STEP`(5)分増加し、`/volume down` で元の値に戻ること、
一連の操作後 bbl.ini がバイト単位で変化しないこと(`/set volume` と異なり非永続の設計どおり)
を確認。

2026-07-19 T15-3 完了: `odin test tests -collection:bbl=src` 471件全パス(SDL実呼び出しを
含むため新規テストは無し、既存方針どおり)。`video_set_fullscreen(video, want)`(既に
一致していれば何もしない、失敗時は video.fullscreen を変更しない)と
`video_apply_scale(video, scale)`(`SetWindowSize`、フルスクリーン中は何もしない)を追加。
`video_toggle_fullscreen` を `video_set_fullscreen(video, !video.fullscreen)` を呼ぶ形に
リファクタ(戻り値・ログ挙動は変えていない)。`./scripts/build_macos.sh`(-o:speed)成功。

2026-07-19 T15-4 完了: `odin test tests -collection:bbl=src` 473件全パス(新規2件:
live_setting_kind の4キー写像、不明キー・空文字・大文字小文字違いは None)。
`Live_Setting_Kind`/`live_setting_kind`/`apply_live_setting` を main.odin に追加し、
設定ビューの `.Adjust` 経由・`/set` コマンド経由の2箇所にあった「volumeのときだけ
audio_set_volume」という重複ロジックを `if set_ok { apply_live_setting(...) }` に統一
(shader/fullscreen/scaleも同じ経路で即時反映されるようになった)。
`./scripts/build_macos.sh`(-o:speed)成功。pty検証(実ROM): `/set scale 3`→適用メッセージ、
`/settings`内で←→によるshader切替→適用メッセージ→Esc復帰、`/set fullscreen true`→
`/set fullscreen false`、`/set scale 4`で既定値に戻す、という一連のscale/fullscreen/shader
変更の連続実行後もクラッシュ・ハングなく`/quit`で正常終了することを確認、bbl.iniは
増減を対で行い検証前後でバイト一致。
**未確認のまま**: SDLウィンドウの実際のピクセルサイズ変化・フルスクリーン切替の見た目
(pty/ヘッドレス環境では観測不可能、T9-6以降と同じ既知の制約)。T15-5で改めて記録する。

2026-07-19 T15-5 完了(自動検証は全て完了・クラッシュなし。実機GUI確認のみ残、チェックは
付けない): `odin test tests -collection:bbl=src` 473件全パス(-o:speed/-debug両方)。
`./scripts/build_macos.sh --debug --test` 成功。pty検証:
(1) T14から継続の固定レイアウト回帰確認(pty_shell_layout.py、19項目)を現行バイナリで
再実行し全パス — ホーム/ゲーム中とも「区切り線+ステータス行(fps)+入力行」の同一構造、
home→game→home の全区間で ALT_SCREEN_EXIT 不発行、直接起動でも同じシェルになることを
再確認(T14からのリグレッションなし)。
(2) T13/T14から継続のフルラウンドトリップ(pty_roundtrip.py)を3回連続実行し全パス。
(3) 本フェーズ専用の総合コマンドオンリー確認(14項目): ゲーム中に `s`,`l`,`p`,`+` を
単独で押しても State saved/State loaded/Paused/Volume のいずれのメッセージも一切発火
しないこと、`/slot 3`・`/save`・`/load`・`/pause`・`/resume`・`/volume up`・
`/volume down`・`/set volume 42`・`/settings` の全コマンドが機能し `/quit` で正常終了
することを確認。
(4) `-debug` ビルドでも同じ総合確認がクリーンに通過。
各検証とも bbl.ini は増減を対で行い検証前後でバイト一致。
**残項目**: scale/fullscreen の実際のウィンドウサイズ変化・フルスクリーン切替の見た目は
ヘッドレス環境(対話的GUIセッション無し)では観測不可能(T9-6/T12-6/T13-6/T14-6と同じ
既知の制約)。ユーザーによる実機確認が必要。実施できたらT15-5をチェックしフェーズを
🟢に更新すること。PLAN.mdはこのため🟡のまま、タスク数4/5で据え置く。
