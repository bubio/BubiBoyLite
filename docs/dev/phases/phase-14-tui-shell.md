# フェーズ 14: Claude Code 風固定レイアウトTUI(ゲーム中も同一画面構成を維持)

## 前提

- 依存フェーズ: 13(ゲーム中TUIメニュー。状態機械 menu_step・parse_game_command 拡張は完了済み)。
- 経緯: フェーズ13(オーバーレイ型)は完了したが、ユーザーの本来のビジョンはスクリーンショット
  (Claude Code の画面)で示された **固定レイアウト** だった。計画は
  `/Users/seiji/.claude/plans/tui-tui-tui-sharded-shore.md`(フェーズ14として全面更新済み)参照。

```
┌──────────────────────────────────┐
│  コンテンツ領域                    │  ← ロゴ / ファイルブラウザ / 設定メニュー /
│  (rows - 3 行)                    │     ゲーム中は Now Playing + メッセージログ
├──────────────────────────────────┤  ← 区切り線
│ ステータス行                       │  ← fps / vol / slot / メッセージ
│ > コマンド入力行_                  │  ← 常時表示・常時入力可能
└──────────────────────────────────┘
```

**要件: ゲーム起動中も全く同じ画面構成を維持する。** ゲーム中だけ alt screen を抜けて1行
ステータスに縮退する現在の構成(T9〜T13)を廃止する。

実現可能性: T13 で全メニューが「状態機械+毎フレーム step」化済みのため、ゲームループから
毎反復シェルを step/描画しても SDL ポンプは止まらない(幽霊化問題は解決済み)。
残る作業は**レイアウトの統一**が主。

## ゴール

`bbl` 引数なし起動からゲーム実行・終了まで、常に「コンテンツ領域+区切り線+ステータス行+
入力行」の同一画面構成が維持される。ゲーム中のコンテンツ領域は Now Playing パネル+
メッセージログ。入力行は常時アクティブで、ゲーム中は入力バッファが空のときだけ既存1キー
ホットキーが効く。T13 のオーバーレイ描画は撤去(menu_step 状態機械は再利用)。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src      # シェル描画・メッセージログ・ルーティングの単体テスト PASS
./scripts/build_macos.sh --test          # -o:speed ビルド+全テスト成功
./bbl                                    # ホーム→browse→ROM起動→ゲーム中も同一レイアウト→quit
```

pty 検証で「ゲーム起動前後で画面構成が同一」(区切り線・ステータス行・入力行が両方に存在し、
ゲーム開始時に ALT_SCREEN_EXIT が発行されない)ことを必ず確認する。

## 設計方針(実装前に読むこと)

- **レイアウトシェル(純粋関数)**: `Shell_Frame { cols, rows, content: []string, status, input, hint }`
  + `tui_render_shell`。CURSOR_HOME + 行ごと `\x1b[K`、既存 Builder 方式・`write_padded`・
  `rune_display_width` を全面再利用。最下行に改行を書かない(スクロール防止)。
  描画は dirty 時のみ(毎フレーム無条件描画はしない)。ステータス行は1秒ごと dirty。
- **alt screen を常時維持**(ホーム〜ブラウザ〜設定〜**ゲーム中**〜終了まで)。
  `tui_suspend_for_game` の alt screen 退出をやめ、VMIN/VTIME=0 切替のみ残す。終了時と
  クラッシュ時(シグナル+assertion_failure_proc)の復元は tui_force_restore が既に
  ALT_SCREEN_EXIT を含むため確実に走ることを確認する。
- **書き出しは contextless `tui_plat_write_raw`**(T12-6 の os.write_string -o:speed 発火の
  前例があるため、シェル描画は最初から contextless で書く)。
- **入力行は常時アクティブ**: タイプは常に入力行へ。モード切替の `/` プレフィックス待ちは廃止。
  ゲーム中は**入力バッファが空のときだけ**既存1キーホットキー(+,-,1-4,s,l,p)を解釈。
  ブラウザ・設定表示中は ↑↓←→/Enter/Esc をその画面の状態機械へ(Enter/Esc は入力バッファが
  空のときのみ画面側、非空なら入力行側)、印字文字は入力行へ。
- **メッセージログ**: リングバッファ(32件)。`status_line_set_message` をログ追記+ステータス行
  表示の二本立てに統合。app 層の eprintf 診断はシェル有効時はログ経由に付け替え。core 層の
  低頻度ログ(cpu: STOP 等)は当面許容(次回描画で上書き)。
- **非TTY フォールバック無変更**: `--headless`、非TTY直接起動(status line 無し)は従来どおり。
  直接起動(`bbl rom.gb`)で stdin/stdout/stderr が TTY ならゲーム中シェルを使う(TUI経由と
  同一の見た目)。stdout 非TTY 等でシェルを使えない場合は従来の1行ステータス表示に
  フォールバックする。
- **厳守**: opt-none 3点セット+`tui_run_settings_menu` の属性維持。新設のゲーム中描画
  ヘルパーで `-o:speed` アサーションが出た場合のみ opt-none 追加(T13-6 の前例)。
  ファイルI/Oまたぎは context.allocator。push しない。

---

### T14-1: tui_render_shell(純粋関数)+ Shell_Frame

- [x] 完了

**目的**: 全画面を「コンテンツ領域(rows-3)/区切り線/ステータス行/入力行」に分割する共通
レンダラを作る。以降の全画面(ホーム/ブラウザ/設定/ゲーム中)がこれ1本で描画される。
**作るもの**: `src/app/tui.odin`:
- `Shell_Frame :: struct { cols, rows: int, content: []string, status: string, input: string, hint: string }`
- `SHELL_RESERVED_ROWS :: 3`
- `tui_render_shell :: proc(f: Shell_Frame, allocator := context.allocator) -> string`
  CURSOR_HOME 開始、rows 行ちょうど(改行 rows-1 個、最下行に改行なし)、各行 `\x1b[K` +
  cols-1 幅 write_padded。入力行は `"> " + input + "_"`、hint は入力行右端に右寄せ(幅が
  足りなければ省略)。content が rows-3 を超える分は切り捨て、不足分は空行。
- `tui_write_shell`(tui_plat_write_raw で書き出し)
**参照**: `tui_render_frame`(tui.odin:200、Builder 方式の参考)、`write_padded`(tui.odin:86)
**完了条件 (DoD)**: 文字列テストで行数・`\x1b[K` 数・入力行形式・打ち切り・hint 右寄せを検証。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 最下行に改行を書くとスクロールして1行ズレる。全行 cols-1 幅打ち切りで自動折り
返しを防ぐ。
**依存**: なし

---

### T14-2: ホーム/ブラウザ/設定をシェル描画に移行

- [x] 完了

**目的**: TUI 側3画面の描画を Shell_Frame へ差し替える(ロジック無変更、描画のみ)。
**作るもの**: `src/app/tui.odin`:
- コンテンツ組み立ての純粋関数群: `shell_content_home`(ロゴ中央寄せ+コマンド一覧)、
  `shell_content_list`(heading+項目リスト、選択カーソル、選択が常に見えるスクロール窓)
  — 所有 []string を返し `shell_lines_destroy` で解放(ファイルI/O後に呼ばれるため
  temp_allocator 不可)
- `tui_run_command_home` / `tui_run_rom_browser` / `tui_run_recent_browser` /
  `tui_run_settings_menu` の描画ブロックを `tui_write_shell` へ差し替え(キー処理・状態遷移は
  無変更、opt-none 維持)
- 旧 `tui_render_home_screen`/`tui_write_home_screen`/`tui_render_frame`/`tui_write_frame` は
  撤去(テストも新描画に合わせて書き換え)
**参照**: T14-1、既存3ループ(tui.odin)
**完了条件 (DoD)**: 既存の遷移テスト+新シェル出力テストが通り、pty でホーム→/settings→
/browse→戻る、が新レイアウトで一巡する。
**検証方法**: `odin test tests -collection:bbl=src` + pty 検証。
**落とし穴**: ブラウザの entries 再代入+ブロック defer の既存パターン(tui.odin:1200)を
壊さない。描画のみ差し替えること。
**依存**: T14-1

---

### T14-3: メッセージログ(リングバッファ)+ status_line 統合

- [x] 完了(タイムスタンプは付けない設計判断に変更: core:time の time.now() は UTC で、
      ローカル時刻にはタイムゾーン処理が必要。UTC 表示はかえって誤解を招くため見送り)

**目的**: 単発表示だった操作メッセージを履歴付きログにし、ゲーム中コンテンツ領域に直近数件を
表示できるようにする。
**作るもの**: `src/app/tui.odin` / `src/app/main.odin`:
- `MESSAGE_LOG_CAP :: 32`、`Message_Log`(固定長リング、entries は所有 clone)、
  `message_log_append` / `message_log_len` / `message_log_get`(0=最古) / `message_log_destroy`
- `Status_Line` に `log: ^Message_Log` を追加し、`status_line_set_message` が
  `[HH:MM:SS] msg` 形式でログへも追記する(log が nil なら従来どおり)
- app 層 eprintf の付け替えは T14-4(シェル有効フラグが入ってから)で行う
**参照**: `status_line_set_message`(tui.odin)、`core:time`
**完了条件 (DoD)**: リングの上書き(33件目で最古が消える)・順序・clone 所有をテストで検証。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: entries は必ず clone(借用を保持しない)。destroy で全 delete。
**依存**: なし(T14-4 が使う)

---

### T14-4: ゲーム中 alt screen 維持+シェル描画+Now Playing、オーバーレイ撤去

- [x] 完了

**目的**: フェーズの核心。ゲーム中も TUI と同一のシェル画面構成を維持する。
**作るもの**: `src/app/tui.odin` / `src/app/main.odin`:
- `tui_suspend_for_game` から ALT_SCREEN_EXIT/CURSOR_SHOW を除去(VMIN/VTIME=0 のみ)、
  `tui_resume_from_game` から ALT_SCREEN_ENTER/CURSOR_HIDE を除去(VTIME=1 のみ)
- 直接起動: `tui_game_terminal_begin` を stdout TTY 時に alt screen 突入までやる形に拡張
  (tui_exit で復元)。stdout 非TTY なら従来の1行ステータスへフォールバック
- Now Playing コンテンツ(純粋関数 `shell_content_now_playing`): ROM名/状態/fps/音量/
  スロット/カートリッジ+メッセージログ直近数件
- `status_line_tick` を「1秒窓の更新(`status_line_update`、更新有無を返す)」と「レガシー
  stderr 書き出し」に分離。シェル有効時は update→dirty→シェル再描画
- ゲームループ末尾の描画を `tui_render_shell` 1本に統一(モード: Now Playing / Settings)。
  T13-3 の `tui_render_menu_overlay`/`MENU_OVERLAY_CLOSE`/`game_menu_overlay_draw` は**撤去**
  (menu_step/menu_adjust_value は再利用)。show_status の eprintln はシェル有効時に抑制
**参照**: T14-1/T14-3、`run_rom_window`(main.odin)、T13-5 の配線
**完了条件 (DoD)**: ビルド+全テスト成功。pty: ゲーム起動→画面構成がホームと同一(区切り線+
ステータス行+入力行)、ALT_SCREEN_EXIT がゲーム開始時に発行されない。
**検証方法**: `./scripts/build_macos.sh --test` + pty 検証。
**落とし穴**: run_rom_window は os.exit(1) 経路がある(ROM読み込み失敗等)。alt screen 内で
exit すると画面が復元されないため、TUI経由の失敗時は tui_force_restore が効く形を保つこと。
**依存**: T14-1, T14-3

---

### T14-5: 入力ルーティング(常時入力行、空バッファ時のみホットキー)

- [x] 完了

**目的**: Claude Code と同様「タイプした文字は常に入力行へ」を全画面で実現する。
**作るもの**: `src/app/tui.odin` / `src/app/main.odin`:
- ゲーム中: `Game_Tui_Mode.Command` を廃止し「表示ビュー(Now_Playing/Settings)+入力バッファ」
  に整理。印字文字は、バッファ空 かつ ホットキー(+,-,1-4,s,l,p)ならホットキー実行、
  それ以外はバッファへ。Enter はバッファ非空なら `parse_game_command`(先頭 `/` 許容)、
  Esc はバッファクリア。Settings ビュー中の ↑↓←→ は menu_step へ、Enter/Esc はバッファ空の
  ときだけメニュー側(Close)
- `parse_game_command` を先頭 `/` 付き入力にも対応(`/pause` と `pause` の両対応)
- ブラウザ/recent: 印字文字は入力行へ(バッファ空のときのみ q=戻る を維持)、Enter は
  バッファ非空なら `parse_home_command` としてコマンド実行(run_tui へ返して遷移)、
  空なら従来の選択決定
**参照**: T13-5 の配線、`parse_home_command`/`parse_game_command`
**完了条件 (DoD)**: ルーティングとパーサ両対応の単体テスト+pty でゲーム中に `/pause` 等を
直接タイプして動作、バッファ空での 1キーホットキーも動作。
**検証方法**: `odin test tests -collection:bbl=src` + pty 検証。
**落とし穴**: `save` は 's' がホットキーのため素で打てない(仕様: `/save` と打つ)。ホットキー
文字は「バッファ空のとき」しか消費しないこと。
**依存**: T14-4

---

### T14-6: 仕上げ(リサイズ、-o:speed 往復、crash restore 確認、docs 記録)

- [ ] 完了(自動検証は全て完了・クラッシュなし。実機 GUI での目視確認のみ残、下記
      チェックリストと検証ログ参照。T12-6/T13-6 と同じ扱いでチェックは付けない)

チェックリスト:
- [x] リサイズ時の全画面再描画(ゲーム中に 80→60 列・24→30 行へ変更して再描画を確認。
      TUI側3画面も last_cols/last_rows 監視で同様)
- [x] `-o:speed` フルラウンドトリップ(ホーム→/settings→/browse→ROM起動→ゲーム中
      /settings→←→調整→Esc→/quit→ホーム→/quit)5回連続クリーン、T12-6 型アサーション
      再発なし(新設 game_shell_draw への opt-none 付与は不要と判断)
- [x] crash restore: ゲーム中(alt screen 維持状態)に SIGTERM → ALT_SCREEN_EXIT が
      出力されプロセス終了することを確認
- [x] `-debug` ビルドでも同じ往復 1回クリーン、`./scripts/build_macos.sh --test` 成功
- [ ] macOS Terminal / Linux 実機での目視確認(SDL ウィンドウの実応答性・フォーカス切替、
      リサイズ時の実際の見た目、Now Playing 画面の視認性。この開発環境には対話的GUI
      セッションが無く実施不能、T9-6/T12-6/T13-6 と同じ既知の制約。ユーザーによる
      実機確認が必要)

**目的**: フェーズ14のマイルストーン。
**作るもの**: 微修正+検証+docs:
- 全画面でリサイズ時の再描画(last_cols/last_rows 監視)を確認
- `-o:speed` でホーム→browse→ROM起動→ゲーム中 settings/コマンド→quit→ホーム→quit の
  pty 往復(複数回)。アサーション再発時は T13-6 の前例どおり段階対応
- クラッシュ時復元: ゲーム中(alt screen 維持状態)で SIGTERM を送り、ALT_SCREEN_EXIT が
  出力されることを確認
- phase-14 ファイルへの検証ログ記録、PLAN.md 更新
**完了条件 (DoD)**: `odin test` 全パス + 両ビルド成功 + pty 往復クリーン + 復元確認。
実機 GUI 確認は残項目として正直に記録(チェックはその分付けない)。
**検証方法**: `./scripts/build_macos.sh --test` / `--debug --test` / pty。
**落とし穴**: 実機 GUI(SDLウィンドウ応答性・フォーカス切替)はこの開発環境では検証不能
(T9-6/T12-6/T13-6 と同じ既知の制約)。
**依存**: T14-1〜T14-5

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-18 T14-1 完了: `odin test tests -collection:bbl=src` 469件全パス(新規5件:
行数=rows・改行=rows-1・`\x1b[K`=rows と最下行改行なし、コンテンツの rows-3 打ち切り、
全行 cols-1 幅パディング、hint 右寄せと幅不足時の省略、cols/rows=0 の 80x24 フォールバック)。
`./scripts/build_macos.sh`(-o:speed)成功。`Shell_Frame`/`SHELL_RESERVED_ROWS`/
`tui_render_shell`(純粋)/`tui_write_shell`(contextless 書き出し、T12-6 の前例を踏まえ最初から
tui_plat_write_raw 使用)/`shell_lines_destroy` を追加。

2026-07-18 T14-2 完了: `odin test tests -collection:bbl=src` 467件全パス(旧 tui_render_frame
4件+旧 tui_render_home_screen 3件を撤去し、shell_content_list 3件(heading+項目+info 右寄せ、
選択マーカー、スクロール窓で選択が常に見える)+shell_content_home 2件(ロゴ+コマンド一覧、
狭い幅での1行タイトルフォールバック)に移行)。`shell_content_home`/`shell_content_list`
(いずれも所有 []string を返す純粋関数、temp_allocator 不使用)を追加し、
`tui_run_command_home`/`tui_run_settings_menu`/`tui_run_rom_browser`/`tui_run_recent_browser`
の描画ブロックを `tui_write_shell` へ差し替え(キー処理・状態遷移・entries 管理・opt-none は
無変更)。旧 `Tui_Frame`/`tui_render_frame`/`tui_write_frame`/`tui_render_home_screen`/
`tui_write_home_screen` を撤去。`-o:speed` pty 検証: (1) ホーム→/settings→←→で volume/scale
適用→Esc→/quit の一巡、(2) ホーム→/settings→/browse→ROM起動→ゲーム中メニュー→復帰→終了の
フルラウンドトリップ、いずれもクラッシュなし・bbl.ini 検証前後バイト一致。

2026-07-18 T14-3 完了: `odin test tests -collection:bbl=src` 471件全パス(新規4件:
追記と順序(0=最古)+範囲外は ""、CAP+1 件で最古だけが押し出されるリング上書き、
entries が clone 所有であること(呼び出し元バッファ書き換えの影響を受けない)、
status_line_set_message がログへも追記し空メッセージは追記しないこと)。
`Message_Log`(固定長32件リング)+`message_log_append/len/get/destroy` を追加、
`Status_Line.log`(非所有ポインタ)経由で `status_line_set_message` と統合。
タイムスタンプは見送り(UTC しか取れないため、上記の設計判断)。app 層 eprintf の
付け替えはシェル有効フラグが入る T14-4 で実施。`-o:speed` ビルド成功。

2026-07-18 T14-4 完了: `odin test tests -collection:bbl=src` 470件全パス(オーバーレイ3件を
撤去し shell_content_now_playing 2件(パネル内容+ログ古→新表示、⏸表示+ログの残り行数
制限)に置き換え)。実装: (1) `tui_suspend_for_game`/`tui_resume_from_game` から alt screen
出入りを除去(VMIN/VTIME 切替のみ)、(2) `tui_game_terminal_begin` を stdout TTY 時に
alt screen 突入まで行う形に拡張(ok, shell の2値返し。stdout 非TTY はレガシー1行表示へ
フォールバック)、(3) `Game_View`/`Game_Panel_Info`/`shell_content_now_playing`/
`game_shell_draw` を新設しゲームループ末尾の描画を shell_active 分岐でシェル1本に統一、
(4) `status_line_tick` を `status_line_update`(1秒窓の判定+last_line/last_fps 更新、書き出し
なし)とレガシー書き出しに分離、`status_line_repaint` は撤去、(5) T13-3 のオーバーレイ
(`tui_render_menu_overlay`/`MENU_OVERLAY_*`/`game_menu_overlay_draw`)撤去(menu_step は
再利用)、(6) `show_status`/`handle_shortcut_action` に quiet_terminal を追加しシェル有効時の
stderr 直書きを抑制(SDL側ショートカット結果もメッセージログ経由に)、(7) run_rom_window の
os.exit(1) 失敗経路に tui_force_restore を前置(alt screen 内での exit による画面破壊防止)。
`-o:speed` pty 検証 19項目全パス: ホーム/ゲーム中とも「区切り線+ステータス行(fps)+入力行」の
同一構造、**home→game→home の全区間で ALT_SCREEN_EXIT が一切発行されない**こと、最終 /quit
時のみ発行されること、ゲーム中設定ビューの ←→ 適用、直接起動(`bbl rom.gb`)でも alt screen+
Now Playing シェルになること、を確認。`--debug` ビルドも成功。bbl.ini 検証前後バイト一致。

2026-07-18 T14-5 完了: `odin test tests -collection:bbl=src` 474件全パス(新規4件:
game_input_route の「バッファ空のときだけホットキー」「非ホットキー文字と `/` は常に入力行」
「空/非空 Enter・Esc の振り分け」「設定ビューの ↑↓←→=メニュー・Enter/Esc=空時のみメニュー」、
parse_game_command の先頭 `/` 両対応(/pause・/set・/save 2・`/`単体=Empty・従来形式維持))。
実装: 純粋関数 `game_input_route`(tui.odin)を新設し、main.odin のキー処理を route 駆動に
書き換え。`Game_Tui_Mode`(Play/Command/Menu)を廃止し「Game_View + 入力バッファ空/非空」に
整理(Command モードは常時入力行に吸収)。タイプ中の自動一時停止は廃止し、設定ビュー表示中
のみ pause(閉じるときに復元、/pause・/resume は明示操作)。`game_key_to_action` 自体は無変更
(既存テスト維持、`/` の .Enter_Command_Mode は「入力行へ `/`」として解釈)。レガシー
フォールバックも同じルーティングでエコー行表示のみ分岐。
`-o:speed` pty 検証 12項目全パス: 空バッファ `p` の即時 pause/resume、`/pause`+素の `resume`
両対応、`/slot 2`、`/save 3`(バッファ非空中の `s` がホットキー化しないこと)、Esc クリア後の
ホットキー復活、設定ビュー開閉と←→適用、`/quit` 終了。T14-4 の画面構成検証19項目も再実行し
全パス(リグレッションなし)。bbl.ini 検証前後バイト一致。

2026-07-18 T14-6 途中経過(自動検証完了・実機GUI確認のみ残、チェックは付けない):
`odin test tests -collection:bbl=src` 474件全パス、`./scripts/build_macos.sh --test`
(-o:speed)と `--debug` の両ビルド成功。pty 検証: (1) ゲーム中の端末リサイズ
(80→60列、24x60→30x100)で全画面再描画されること(TIOCSWINSZ で実際に master 側の
winsize を変更して確認。SIGWINCH 不要のポーリング検知)、(2) ゲーム中 SIGTERM で
ALT_SCREEN_EXIT が出力されてから終了すること(シグナルハンドラ経由の tui_force_restore、
alt screen 常時化後も復元経路が機能)、(3) `-o:speed` フルラウンドトリップ5回連続クリーン
(T12-6 型アサーション再発なし。game_shell_draw は素の実装のまま、opt-none 3点セット+
tui_run_settings_menu の既存属性は無変更で維持)、(4) `-debug` でも同往復クリーン。
いずれも bbl.ini は検証前後でバイト一致。
**残項目**: macOS Terminal / Linux 実機での目視確認(SDLウィンドウの実応答性、リサイズ・
Now Playing 画面の実際の見た目)。実施できたら T14-6 をチェックしフェーズを 🟢 に更新する
こと。PLAN.md はこのため 🟡 のまま、タスク数 5/6 で据え置く。
