# フェーズ 13: ゲーム中TUIメニュー(状態機械+オーバーレイパネル)

## 前提

- 依存フェーズ: 12(TUI コマンド拡張。T12-1〜T12-5 完了、T12-6 は実機GUI確認のみ残)。
- 経緯: TUI 充実化の要望(ゲーム中もTUI維持・コマンド入力、補完、選択式設定、ファイルIPC等)に
  ついてアイデア出しを実施し、ユーザー選択により、まず **「A: ゲーム中TUI維持(オーバーレイ型)」**
  を実装する(検討経緯とスコープ外の保留アイデアは
  `/Users/seiji/.claude/plans/tui-tui-tui-sharded-shore.md` に記録)。
- 現状の核心制約: ゲーム中にブロッキングTUIループを回すと `sdl.PollEvent` が止まり SDL
  ウィンドウが幽霊化する(コミット 0a78a66 で実証)。そのため T12-5 では `/set` ワンライナーのみ
  許可する workaround を入れた。本フェーズはこれを構造的に解決する:
  **TUIメニューをブロッキングループから「状態機械+毎フレーム1ステップ」に変え**、
  ゲームループから step を呼ぶことで SDL ポンプを止めずに対話メニューを実現する。

## ライブラリ判断(調査済み・確定)

**TUIライブラリは採用しない。** Odin の選択肢は TermCL(唯一実用級)、termbox2 Cバインディング、
WIP の grungy/odin-tui のみ。

- 欲しい機能(補完・選択式メニュー・ゲーム中TUI)はどのライブラリにも無く結局自作。ライブラリが
  提供する低レベル部分(raw mode・ANSI・入力解析)は既に自前実装済み
- 現実装の実機知見(クラッシュ時端末復元、`-o:speed` バグ回避の opt-none 3点セット、`TCSANOW`
  復元、`VMIN/VTIME` 動的切替)はライブラリに移植不能で、移行は再発リスク
- SDLループとの共存には「TUIがイベントループを所有しない」ことが必須。ライブラリの自前ループ
  設計はむしろ邪魔

## ゴール

ROM 実行中に `/` → `settings` でオーバーレイ型の設定メニューがターミナル下部に開き、
↑↓/←→ で選択・値変更(即時反映+`bbl.ini` 差分書き込み)、Esc で閉じてステータス行に復帰できる。
メニュー表示中も SDL イベントポンプは回り続け、ウィンドウが応答不能にならない。
あわせてゲーム中コマンドを `/pause` `/resume` `/save [n]` `/load [n]` `/slot <n>` `/quit` に拡張する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src        # menu_step/オーバーレイ描画/parse_game_command 拡張の単体テスト PASS
./scripts/build_macos.sh --test            # -o:speed ビルド+全テスト成功
./bbl game.gbc                             # ゲーム中 / → settings → ←→ で volume 即時変化 → Esc で復帰
```

## 設計方針(実装前に読むこと)

- **メニュー状態機械(tui.odin、純粋関数)**: 既存の `Settings_Field` / `settings_fields` /
  `settings_field_key` / `settings_field_value_string` を土台に再利用。
  `Menu_State`(selected+status)+ `menu_step`(1キーイベント → `Menu_Effect`)。
  ↑↓=選択移動(clamp)、←→=値サイクル/増減(scale ±1 clamp 1..8、fullscreen/shader トグル、
  volume ±5 clamp 0..100)、Esc/q/Enter=Close。
  **適用(`config_apply_set`)は状態機械の外**。Effect を返すだけにして完全純粋化 →
  文字列比較テスト可能。`config_apply_set` は clamp せず範囲外を拒否する仕様のため、
  clamp は `menu_adjust_value` 側で先に行う。Effect の `value` は `context.allocator` 既定
  (temp_allocator 不可 — config.odin の既知バグ回避方針に従う)。
- **オーバーレイ描画(tui.odin、純粋関数)**: **カーソル不変条件 = 描画後カーソルは常に
  ブロック先頭行(元のステータス行)にある**。既存 `status_line_tick`(`\r\x1b[K`、改行なし)と
  コマンドモードエコーは既にこれを満たすため衝突しない。
  `tui_render_menu_overlay` は `"\r\x1b[K"+見出し → ("\n\x1b[K"+項目行)×4 → "\n\x1b[K"+フッター
  → "\x1b[5A\r"` の構造。最下行では `\n` が自然にスクロールして場所を作り、カーソル移動は全て
  相対(`\n` / `\x1b[5A`)なのでスクロール後も不変条件が保たれる(`\x1b[nB` でなく `\n` を使うのが
  要点)。各行 cols-1 幅打ち切り(既存 `write_padded` 再利用)で自動折り返しによる行数ズレを防止。
  閉じるときは `MENU_OVERLAY_CLOSE :: "\r\x1b[0J"`(カーソル行以降を全消去)。
- **ホーム画面の共有**: `tui_run_settings_menu` のシグネチャ・opt-none は維持し、中身を
  `menu_step` 駆動に書き換え。`editing`/`Line_Editor` タイプ入力は削除し←→サイクルに統一。
  描画は既存 `tui_write_frame` のフル枠のまま(`List_Item.info` に "◂ 3 ▸")。
  **遷移ロジックと値計算をホーム/ゲーム中で共有し、描画だけ分岐**。`tui_run_command_home` は無変更。
- **ゲームループ統合**: `command_mode: bool` → `Game_Tui_Mode :: enum { Play, Command, Menu }`。
  メニュー中は paused のため `sdl.Delay(16)` 経路で約60Hzポーリングが回り続け、
  **SDLポンプ停止は構造的に発生しない**。
- 書き出しは stderr。まず `fmt.eprintf`、`-o:speed` アサーション再発時は contextless な書き込み
  (既存 `tui_plat_write_raw` 相当の stderr 版)へ差し替え、それでも再発する場合のみ
  `game_menu_overlay_draw` に `@(optimization_mode="none")` を付与する(T12-6 の前例踏襲)。

## 壊してはいけない既存資産

- opt-none 3点セット(`tui_run_command_home` / `tui_term_size` / `tui_plat_term_size`)無変更、
  `tui_run_settings_menu` の opt-none 維持
- ファイルI/Oまわりの `context.allocator` 方針(config.odin:144-147 のコメント参照)、
  contextless `tui_plat_write_raw`、シグナル+`assertion_failure_proc` 復元経路
- ゲーム中ホットキー(`game_key_to_action`)の挙動、alt screen にはゲーム中一切入らない
- 既存テスト全パス

---

### T13-1: メニュー状態機械(Menu_State/Menu_Effect/menu_step/menu_adjust_value)

- [x] 完了

**目的**: 対話メニューの遷移ロジックを I/O から完全分離した純粋関数として実装し、ホーム画面と
ゲーム中オーバーレイの両方から共有できる土台を作る。
**作るもの**: `src/app/tui.odin`:
- `Menu_State :: struct { selected: int, status: string /* 所有 */ }`
- `Menu_Op :: enum { None, Redraw, Adjust, Close }`
- `Menu_Effect :: struct { op: Menu_Op, key: string /* 静的 */, value: string /* 呼び出し側 allocator */ }`
- `menu_adjust_value :: proc(cfg: Config, f: Settings_Field, delta: int, allocator := context.allocator) -> (value: string, changed: bool)`
  scale=±1 clamp 1..8、fullscreen/shader=トグル(delta 符号は無視)、volume=±5 clamp 0..100。
  既に境界にいて値が変わらない場合は `changed=false`(確保もしない)
- `menu_step :: proc(m: ^Menu_State, ev: Key_Event, cfg: Config, allocator := context.allocator) -> Menu_Effect`
  ↑↓=selected clamp 移動(.Redraw)、←→=menu_adjust_value 呼び出し(.Adjust または .None)、
  Esc/q/Enter=.Close、その他=.None
- `Settings_Field` の `@(private = "file")` を外す(tests パッケージから `menu_adjust_value` を
  直接テストするため。`settings_fields` 等の補助はファイル内利用のみなので private のまま)
**参照**: `Settings_Field` 一式(tui.odin:606-644)、`config_apply_set`(config.odin:221、
範囲外は clamp でなくエラーを返す仕様)、`Key_Event`(tui.odin:116)
**完了条件 (DoD)**: 単体テストで ↑↓clamp、各フィールド×±の値文字列、境界(scale=8 で Right →
changed=false 等)、Esc/q/Enter で .Close を検証できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: Effect の `value` を temp_allocator の借用のまま返さない(呼び出し側 delete 前提の
所有権付き文字列を allocator で確保する)。
**依存**: なし

---

### T13-2: tui_run_settings_menu の menu_step 駆動化(ホーム画面)

- [x] 完了

**目的**: ホーム画面の /settings 対話メニューを新しい状態機械に載せ替え、タイプ入力を廃止して
←→サイクル操作に統一する。ゲーム中オーバーレイ(T13-5)投入前に状態機械を実機で検証可能にする。
**作るもの**: `src/app/tui.odin`:
- `tui_run_settings_menu` の中身を `menu_step` 駆動に書き換え(シグネチャ・
  `@(optimization_mode="none")` は維持)。`editing`/`Line_Editor` を削除
- `List_Item.info` を `"◂ 3 ▸"` 形式にする純粋関数 `menu_item_info` を切り出す(単体テスト対象)
- フッター文言を ←→ 操作に合わせて更新(例: `"↑↓ 選択  ←→ 値を変更  Esc 戻る"`)
**参照**: `tui_run_settings_menu`(tui.odin:652-743)、T13-1
**完了条件 (DoD)**: menu_item_info の単体テストが通り、既存テストも全パス。ホーム画面はSDL不要
なので `./bbl` → `/settings` → ←→ で値が変わることを pty で確認できる。
**検証方法**: `odin test tests -collection:bbl=src` + pty 検証。
**落とし穴**: `.Adjust` の `eff.value` は使用後に必ず `delete` する(所有権は呼び出し側)。
**依存**: T13-1

---

### T13-3: オーバーレイ描画(tui_render_menu_overlay)と status_line_format 抽出

- [x] 完了

**目的**: ゲーム中オーバーレイの描画文字列を純粋関数として実装し、閉じた後のステータス行復帰
(repaint)手段を用意する。
**作るもの**: `src/app/tui.odin`:
- `MENU_OVERLAY_ROWS :: 6`(見出し1+項目4+フッター1)
- `tui_render_menu_overlay :: proc(m: Menu_State, cfg: Config, cols: int) -> string`
  構造は設計方針のとおり(`\r\x1b[K` 開始、`\n\x1b[K`×5、末尾 `\x1b[5A\r`)。各行 cols-1 幅打ち切り
- `MENU_OVERLAY_CLOSE :: "\r\x1b[0J"`
- `status_line_tick` の行組み立てを `status_line_format`(純粋関数)に抽出
- `Status_Line` に `last_line: string`(所有)を追加し、tick 時に保存。
  `status_line_repaint`(fps再計算なしで last_line を `\r\x1b[K` 付きで再描画)を追加
**参照**: `status_line_tick`(tui.odin:1402)、`write_padded`(tui.odin:86)
**完了条件 (DoD)**: 文字列テストで `\r\x1b[K` 開始・`\n` ちょうど5個・末尾 `\x1b[5A\r`・
cols=20 打ち切りを検証できる。status_line_format の出力に fps/vol/slot が含まれる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: カーソル復帰は `\x1b[5A`(相対)を使う。`\x1b[nB`/絶対座標は最下行スクロール時に
不変条件が壊れる。`last_line` は所有文字列なので `status_line_destroy` で delete を忘れない。
**依存**: T13-1

---

### T13-4: parse_game_command 拡張(7コマンド+slot 引数)

- [x] 完了

**目的**: ゲーム中コマンドを /set 以外にも拡張する。全て既存バックエンドへの写像のみで
新規エミュ機能は無い。
**作るもの**: `src/app/tui.odin`:
- `Game_Command_Kind :: enum { Set, Settings, Pause, Resume, Save_State, Load_State, Select_Slot, Quit, Unknown, Empty }`
  (`.Settings_Unavailable` は削除: ゲーム中 `/settings` は T13-5 でオーバーレイを開くようになる)
- `Game_Command` に `slot: int` を追加(0=指定なし)。`save 2` / `load`(slot省略可) /
  `slot 3`(1-4必須、範囲外・非数値は .Unknown) / `pause` / `resume` / `quit`・`exit`
**参照**: `parse_game_command`(tui.odin:1514)、`handle_shortcut_action`(main.odin:448)
**完了条件 (DoD)**: パーステストで各コマンド、`slot 0`/`slot 5` は Unknown、既存 /set テスト維持
を検証できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 既存テスト `test_parse_game_command_settings_is_unavailable` は仕様変更に合わせて
`.Settings` 期待へ書き換える(削除ではない)。
**依存**: T13-1(状態機械と同時に使う前提の型設計のため)

---

### T13-5: ゲームループ統合(Game_Tui_Mode 3分岐)

- [x] 完了(ターミナル側配線は pty で自動検証済み。SDL ウィンドウの実応答性の実機確認は
      T13-6 の残項目として記録)

**目的**: フェーズの核心。ゲームループから menu_step を毎フレーム1ステップ呼ぶことで、
SDL ポンプを止めずに対話メニューを実現する。
**作るもの**: `src/app/main.odin` / `src/app/tui.odin`:
- `command_mode: bool` → `Game_Tui_Mode :: enum { Play, Command, Menu }` に置き換え
- `.Play`: 現行どおりホットキー(`game_key_to_action`)全維持。`/` → `.Command`
- `.Command`: Line_Editor は現行どおり。Enter 時の分岐を拡張:
  - `.Settings`: rows≥7 ガードの上 `mode = .Menu`(pause は解除せず `mode_was_paused` を
    メニュー終了まで持ち越す)
  - `.Pause`/`.Resume`: `paused` 直接設定(`.Pause` 時は `mode_was_paused = true` に上書きして
    復元による即 resume を防ぐ)
  - `.Save_State`/`.Load_State`/`.Select_Slot`: slot>0 なら `input_state.state_slot` 設定 →
    `handle_shortcut_action`
  - `.Quit`: `running = false`
  - `.Set`: 現行のまま(live_cfg + volume 即時反映)
- `.Menu`: `menu_step` → `.Adjust` なら `config_apply_set(&live_cfg, ...)` + volume 即時反映 +
  `delete(eff.value)`、`.Close` なら `MENU_OVERLAY_CLOSE` 出力 → `status_line_repaint` →
  `game_resume_after_command_mode` → `.Play`
- ループ末尾を3分岐: `.Menu`=`game_menu_overlay_draw`(幅変化検知込み)/ `.Command`=現行エコー /
  `.Play`=`status_line_tick`
**参照**: `run_rom_window`(main.odin:210-371)、T13-1〜T13-4
**完了条件 (DoD)**: ビルド+全テスト成功。pty smoke: ROM起動 → `/` → `settings` → ←→ で
volume 即時変化 → Esc → ステータス行復帰、プロセス生存。
**検証方法**: `./scripts/build_macos.sh --test`(+ `--debug --test`)、pty 検証。
**落とし穴**: メニュー中は paused=true のため `sdl.Delay(16)` 経路に乗る(SDLポンプは回り続ける)。
SDL ウィンドウの実際の応答性はヘッドレス環境では証明不能(T12-6 と同じ制約)。
**依存**: T13-1, T13-2, T13-3, T13-4

---

### T13-6: 仕上げ(リサイズ対応、-o:speed リグレッション確認、docs 記録)

- [ ] 完了

**目的**: フェーズ13のマイルストーン。細部の仕上げと `-o:speed` 固有バグの再発確認。
**作るもの**: `src/app/tui.odin` / `src/app/main.odin` / docs:
- 幅/高さ変化時のオーバーレイ強制再描画
- `-o:speed` でホーム→/settings→ゲーム→ゲーム中 /settings 往復の pty 検証(複数回)。
  T12-6 型アサーション再発時は contextless 書き込みへ切替、それでも駄目なら
  `game_menu_overlay_draw` に opt-none 付与
- phase-13 ファイルへの検証ログ記録、PLAN.md 更新
- オプション(lone-ESC 二段 read hardening)は今回スコープ外として記録のみ
**参照**: T12-6 検証ログ(phase-12-tui-command.md)
**完了条件 (DoD)**: `odin test` 全パス + `-o:speed`/`-debug` 両ビルド成功 + pty 往復検証で
クラッシュなし。実機 GUI 確認は残項目として正直に記録(チェックはその分付けない)。
**検証方法**: `./scripts/build_macos.sh --test` / `./scripts/build_macos.sh --debug --test` / pty。
**落とし穴**: 実機 GUI(SDLウィンドウ応答性・フォーカス切替)はこの開発環境では検証不能
(T9-6/T12-6 と同じ既知の制約)。
**依存**: T13-1〜T13-5

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-18 T13-1 完了: `odin test tests -collection:bbl=src` 455件全パス(新規8件:
menu_step の↑↓clamp、menu_adjust_value の scale ±1/境界 changed=false、fullscreen/shader
トグル(delta符号無視)、volume ±5 と 98→100 clamp/境界、←→の .Adjust Effect(key="scale"
value="5")と境界での .None、Esc/Enter/q の .Close と 'x' の .None)。
`./scripts/build_macos.sh`(-o:speed)成功。`src/app/tui.odin` に
`Menu_State`/`Menu_Op`/`Menu_Effect`/`menu_adjust_value`/`menu_step` を追加(全て純粋関数、
config_apply_set 呼び出しは状態機械の外)。`Settings_Field` の `@(private = "file")` を外した
(tests パッケージから menu_adjust_value を直接テストするため。実装前の精読で判明した計画の
補正点)。Effect の value は allocator で確保した所有権付き文字列(temp_allocator 不可の
方針どおり)。

2026-07-18 T13-2 完了: `odin test tests -collection:bbl=src` 456件全パス(menu_item_info の
"◂ 3 ▸" 形式1件を追加)。`tui_run_settings_menu` を menu_step 駆動に書き換え
(シグネチャ・opt-none 維持、`editing`/`Line_Editor` タイプ入力を削除、←→サイクルに統一。
フッターを「↑↓ 選択  ←→ 値を変更  Esc 戻る」へ)。`-o:speed` ビルドの実バイナリを pty
(`pty.fork`、in-place 実行)で検証: ホーム→`/settings`→"◂ 値 ▸"表示+フッター確認→↓×3で
volume 選択→`←`で「volume = NN に更新しました」→`→`で復元→↑×3で scale→`→`で
「scale = N に更新しました」→`←`で復元→Esc でホーム復帰→`/quit` で exit 0。
増減を対で行ったため終了後の bbl.ini はバイト単位で検証前と一致(書き戻し配線と
行パッチの両方が機能している証拠)。クラッシュ・アサーションなし。

2026-07-18 T13-3 完了: `odin test tests -collection:bbl=src` 460件全パス(新規4件:
オーバーレイ構造(`\r\x1b[K` 開始・`\n` ちょうど5個・末尾 `\x1b[5A\r`・4項目+選択マーカー▸)、
m.status がフッターを置き換えること、cols=20 で全6行の表示幅が cols-1=19 に揃うこと
(write_padded 打ち切り)、status_line_format の内容(fps/vol/slot/⏸/双速))。
`./scripts/build_macos.sh`(-o:speed)成功。`tui_render_menu_overlay`/`MENU_OVERLAY_ROWS`/
`MENU_OVERLAY_CLOSE` を追加、`status_line_tick` の行組み立てを `status_line_format`(純粋)に
抽出し、`Status_Line.last_line`(所有、destroy で delete)+ `status_line_repaint` を追加。
カーソル移動は全て相対(`\n`/`\x1b[5A`)で最下行スクロール時も不変条件が保たれる設計どおり。

2026-07-18 T13-4 完了: `odin test tests -collection:bbl=src` 464件全パス(新規4件:
pause/resume(+引数付きは Unknown)、save/load のスロット省略(slot=0)と `save 2`/`load 3`、
`save 5`/`load abc` は Unknown、`slot 3` と `slot`/`slot 0`/`slot 5`/`slot x` は Unknown、
quit/exit)。既存の `test_parse_game_command_settings_is_unavailable` は仕様変更に合わせ
`test_parse_game_command_settings_opens_menu`(`.Settings` 期待)へ書き換え(計画の補正点
どおり削除ではなく改名+期待値変更)。`Game_Command_Kind` から `.Settings_Unavailable` を
削除し `Settings/Pause/Resume/Save_State/Load_State/Select_Slot/Quit` を追加、`Game_Command`
に `slot: int`(0=指定なし)を追加。main.odin 側は本タスク時点では新コマンドに暫定メッセージを
返すのみ(配線は T13-5)。`./scripts/build_macos.sh`(-o:speed)成功。

2026-07-18 T13-5 完了: `odin test tests -collection:bbl=src` 464件全パス、
`./scripts/build_macos.sh`(-o:speed)と `--debug` の両ビルド成功。`main.odin` の
`command_mode: bool` を `Game_Tui_Mode :: enum { Play, Command, Menu }` に置き換え、
`.Command` の Enter 分岐に7コマンドを配線(`.Settings`=rows≥7 ガード付きで .Menu 遷移・
pause持ち越し、`.Pause`=mode_was_paused 上書きで即resume防止、`.Save_State`/`.Load_State`/
`.Select_Slot`=slot 設定+handle_shortcut_action 写像、`.Quit`=running=false、`.Set`=現行維持)。
`.Menu` は menu_step を毎フレーム1ステップ(`.Adjust`→config_apply_set+volume即時反映+
delete(eff.value)、`.Close`→MENU_OVERLAY_CLOSE→status_line_repaint→復元)。tui.odin に
`menu_set_status`(所有clone)/`menu_state_destroy`/`game_menu_overlay_draw`(幅変化検知+
dirty時のみ描画)を追加。既存の .Play ホットキー分岐は無変更。
pty(-o:speed 実バイナリ、実ROM `tests/roms/mooneye/acceptance/rapid_di_ei.gb`、in-place実行)
で検証: ステータス行→`/`→`settings`→オーバーレイ表示(見出し+▸マーカー+◂値▸)→↓×3→`←`で
「volume = NN に更新しました」(メニュー内から config_apply_set 経由の書き戻し。T12-6 の
発火パターン「config_apply_set→ループ継続→tui_term_size」を -o:speed で通過、アサーション
なし)→`→`で復元→Esc で `\x1b[0J` 消去+ステータス行 repaint→`/pause`「Paused」→`/resume`
「Resumed」→`/slot 2`「Slot 2 selected」→`/quit` で exit 0。増減を対で行ったため bbl.ini は
検証前後でバイト一致。プロセス生存・fps 表示継続を確認(SDLウィンドウの実応答性そのものは
ヘッドレス環境では証明不能、T12-6 と同じ制約)。
