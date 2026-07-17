# フェーズ 12: TUI コマンド拡張(ロゴ+プロンプト)

## 前提

- 依存フェーズ: 9(TUI 基盤、完了済み)。
- 経緯: ユーザーから「起動時に大きなロゴを出し、Claude Code のようなコマンド入力エリアを設けて
  `/settings` 等のコマンドを打てるようにしたい。エミュ動作中もコマンドを入力できるようにしたい」
  という要望があり、設計案(コマンドファースト/Vim風モーダル/ロゴ+プロンプト→ブラウザ遷移の3案)を
  比較検討の上、Plan agent と Fable レビューを経て本フェーズとして具体化した
  (`/Users/seiji/.claude/plans/tui-claude-code-bubiboylite-settings-snoopy-whale.md` に検討経緯を記録)。
- フェーズ9は既に完了(🟢)扱いのため、そちらへの追記はダッシュボードの整合性を崩す。新規フェーズとして独立させる。

## ゴール

`bbl` 引数なし起動でロゴ+コマンドプロンプトのホーム画面が出て、`/browse` で既存 ROM ブラウザへ遷移できる。
`/settings`/`/set` で基本設定(scale/fullscreen/shader/volume)を変更でき、変更は `bbl.ini` へ差分だけ
反映される。ROM 実行中も `/set` によるワンライナーコマンドが使える。

## フェーズ完了の検証コマンド

```sh
./bbl                          # ロゴ+プロンプト画面が出る → /browse で既存ブラウザへ
./bbl --recent                 # ホームをスキップし直接 recent 画面
odin test tests -collection:bbl=src   # Line_Editor・config差分パッチの単体テスト PASS
```

## 設計方針(実装前に読むこと)

- 全体アプローチは案C(ロゴ+プロンプト画面 → `/browse`/`/ls`/空Enter で既存 ROM ブラウザへ遷移)。
  T9-2/T9-3/T9-6 で実機バグ2件(`temp_allocator` クラッシュ、SDL ウィンドウ幽霊化)を踏んで検証済みの
  既存 ROM ブラウザ・ゲームループはできるだけ無改修で活かす。
- 全コマンドはスラッシュ付きに統一(`/browse` `/ls` `/recent` `/settings` `/set` `/quit` `/exit`)。
  素の入力は将来的なパス直接指定に予約する。
- **ゲーム実行中は対話メニューを一切開かない**: ブロッキングループを回すと `sdl.PollEvent` が止まり
  SDL ウィンドウが応答不能になる(直近のコミット `0a78a66` と同じ再発パターン)。ゲーム中に許可するのは
  `/set <key> <value>` のワンライナーのみ。
- `/settings` の書き戻しは行単位パッチ方式(`config_parse_ini` の map 再シリアライズは不採用、
  コメント・行順を壊すため)。「変更」はそのセッションで `/set` により明示的に操作されたキーのみを対象とする。
- 新規に追加する `make`/`append` 等の明示的な動的確保は `context.allocator` を使い、対応する `delete` を
  徹底する(T9-6 で踏んだ `-o:speed` ビルド時の `temp_allocator` 実機バグの再発防止。既存の `fmt.tprintf`
  的な使い捨て確保は踏襲してよい)。
- 詳細な設計判断(フォーカスの制約、ESC 誤判定の既知の弱点、cfg 反映フロー等)はプランファイル
  `/Users/seiji/.claude/plans/tui-claude-code-bubiboylite-settings-snoopy-whale.md` を参照。

---

### T12-1: Line_Editor 共通コンポーネント

- [x] 完了

**目的**: 複数文字を貯めて Enter で確定する最小限の行入力バッファを作る。ホーム画面・ゲーム中コマンド
モードの両方で再利用する土台。
**作るもの**: `src/app/tui.odin`:
- `Line_Editor` 構造体(`buf: [dynamic]u8`、`context.allocator` で確保)
- `line_editor_feed(editor: ^Line_Editor, ev: Key_Event) -> (submitted: bool, text: string)` のような
  純粋関数。`.Backspace` で末尾1文字削除、`.Enter` で確定、`.Escape` でクリア扱い
- 印字可能文字(0x20–0x7E)のみ受理し、Tab や Ctrl 系(0x01–0x1F)は無視する
  (`tui_parse_key` は 0x80 未満を無条件で `.Char` にするため、ここでフィルタする)
- カーソル移動(左右)は実装しない(末尾追記 + Backspace のみ)
**参照**: `tui_parse_key`(tui.odin:127、既存のキー解析)、phase-09-tui.md T9-1
**完了条件 (DoD)**: 単体テストで Backspace/Enter/Escape/印字可能文字フィルタの挙動を検証できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: `context.temp_allocator` を使わない(上記設計方針参照)。
**依存**: なし

---

### T12-2: config.odin 行単位パッチ書き戻し

- [x] 完了

**目的**: `/settings`/`/set` で変更した値だけを `bbl.ini` へ安全に書き戻す。
**作るもの**: `src/app/config.odin`:
- 元のファイル内容を行単位で走査し、指定された `key = value` 行だけ値を置換する関数
  (該当行が無ければ末尾に追記)。コメント行・他のキーの行・行順は一切変更しない
- CLI 引数による一時的な上書き値を誤って書き戻さないよう、呼び出し側(T12-4/T12-5)が
  「そのセッションで明示的に `/set` されたキー」だけをこの関数へ渡す設計にする
**参照**: `config_parse_ini`(config.odin:115、map化はコメント・順序を保持しないため今回は使わない)、
`config_render_default_ini`(config.odin:282、デフォルト生成時のコメント形式の参考)
**完了条件 (DoD)**: 単体テストで、(1) 既存キーの値だけが変わりコメント・他行が保持されること、
(2) 存在しないキーは末尾に追記されること、を確認できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: map 再シリアライズは使わない(初回使用でコメントが消え、map 順不定でキー順が
書き込みごとに変わるため)。
**依存**: なし

---

### T12-3: ホーム画面(ロゴ+プロンプト)

- [x] 完了

**目的**: 起動時にロゴとコマンドプロンプトを表示し、既存 ROM ブラウザへの入口にする。
**作るもの**: `src/app/tui.odin`:
- `tui_run_command_home`(仮称)を新設。`run_tui()` のトップレベルを「ホーム画面 ⇄ 既存ブラウザ画面」の
  2段ループに拡張する
- 画面上部にロゴ(複数行 ASCII アート定数)を `display_width` で中央寄せ。ターミナル幅が不足する場合は
  既存の `Tui_Frame.title` 相当の1行タイトルにフォールバック
- コマンド: `/browse`/`/ls`(引数無し)→ 既存 `tui_run_rom_browser` を呼ぶ。`/recent` → 既存
  `tui_run_recent_browser`。空 Enter は `/browse` 相当。`/quit`/`/exit` → 終了
- `--recent` 指定時はホーム画面をスキップし直接 recent 画面を表示(既存の `show_recent_first` の
  優先順位を維持)
- ブラウザ画面側で `q`/`Esc` を押すとホーム画面へ戻る(フッター文言 `"↑↓ 選択 Enter 起動/移動 q 終了"`
  も「q 戻る」等に修正)
- プロンプト行のカーソル表示方法(`CURSOR_SHOW` 切替 or 擬似カーソル)を決めて実装
**参照**: `run_tui`(tui.odin:869)、`tui_run_rom_browser`(tui.odin:679)、T12-1 の `Line_Editor`
**完了条件 (DoD)**: `./bbl` でロゴ+プロンプトが表示され、`/browse` で ROM ブラウザへ遷移、`q` で
ホームへ戻れる。`--recent` はホームをスキップする。
**検証方法**: pty 経由での自動検証、または目視確認。
**落とし穴**: `tui_run_rom_browser`/`tui_run_recent_browser` 自体のロジックは変更しない(T9-6 で
検証済みの資産を壊さない)。
**依存**: T12-1

---

### T12-4: /settings 対話メニューと /set ワンライナー(ホーム画面)

- [x] 完了

**目的**: ホーム画面から基本設定を変更できるようにする。
**作るもの**: `src/app/tui.odin` / `src/app/config.odin`:
- `/settings`(引数無し、ホーム画面限定)→ `scale`/`fullscreen`/`shader`/`volume` の対話メニュー
  (既存の `List_Item`/選択の仕組みを再利用)
- `/set <key> <value>` のワンライナー
- 確定したキーだけを T12-2 の行単位パッチ関数で `bbl.ini` へ即時書き込み。メモリ上の `cfg` も同時に
  直接更新(ファイル再ロードはしない: `config_apply_cli_overrides` の再適用が必要になり、かつ
  `config_load` の警告出力が alt screen 表示中に画面を乱すため)
- 反映タイミング: `scale`/`fullscreen`/`shader` は次回 ROM 起動から(即時反映はスコープ外)。`volume`
  はホーム画面ではファイル+メモリ反映のみ(実際の音量反映は次回 ROM 起動から)
- `config_dir_path()` 失敗時はクラッシュせずエラーメッセージを表示するに留める
**参照**: T12-2、`config_apply_cli_overrides`(config.odin:402)
**完了条件 (DoD)**: `/set volume 50` で `bbl.ini` の該当行だけが変わり、他の値・コメント・行順が
保持される。`/settings` を開いて何も変更せず閉じても `bbl.ini` は変化しない。
**検証方法**: `/set` 実行前後で `bbl.ini` を diff。
**落とし穴**: 「変更」の判定は値比較ではなくセッション内の明示操作のみ(`--scale 6` 起動中に
確認だけして閉じても書き込まれないこと)。
**依存**: T12-1, T12-2, T12-3

---

### T12-5: ゲーム実行中のコマンドモード(/set のみ)

- [x] 完了

**目的**: ROM 実行中も `/set` によるワンライナーコマンドを打てるようにする。
**作るもの**: `src/app/main.odin`:
- `run_rom_window` 内の既存ホットキー処理(`game_key_to_action`)に `/` トリガーを追加
- `paused` ローカル変数(main.odin:159, 247-249)を一時停止/再開の小関数として抽出し、`/` 押下時に
  呼んで自動一時停止する。確定(Enter)/キャンセル(Esc)時、コマンドモードに入る前が非一時停止状態
  だった場合のみ再開する
- コマンドモード中は T12-1 の `Line_Editor` を使い、`status_line_tick` の代わりに入力中の行を
  `\r\x1b[K` で stderr に描く
- **対話メニューは開かない**: `/settings`(引数無し)がゲーム中に打たれた場合は「ホーム画面で
  実行してください」等のメッセージを表示するに留める
- `/set` 確定時は最終的に既存の内部 API(`handle_shortcut_action` や `audio_adjust_volume` 系)を
  呼ぶ形にし、二重実装を避ける
**参照**: `run_rom_window`(main.odin:73)、`handle_shortcut_action`(main.odin:355)、T12-1
**完了条件 (DoD)**: ゲーム実行中に `/` でコマンドモードに入るとエミュレーションが自動一時停止し、
SDL ウィンドウが応答不能にならない。`/set volume 50` が機能する。
**検証方法**: 実機での目視確認(SDL ウィンドウのフォーカス切り替えを伴うため pty のみでは検証不可)。
**落とし穴**: 自動ポーズ中もオーディオコールバックはバッファを消費し続けるためアンダーラン警告が
出うる(既存 `p` ポーズと同じ挙動)。`key_reader_poll` は VMIN=0/VTIME=0 の完全ノンブロッキングで、
CSI シーケンスが read 境界で分割されると単独 ESC に誤判定されうる既知の弱点がある(対処は今回のスコープ外)。
**依存**: T12-1

---

### T12-6: 統合検証

- [ ] 完了

**目的**: フェーズ12のマイルストーン。
**作るもの**: デバッグと修正のみ。チェックリスト:
- [ ] `./bbl` → ロゴ+プロンプト → `/browse` → ROM ブラウザ → `q` → ホームへ戻る、が一巡
- [ ] `--recent` でホームをスキップし直接 recent 画面
- [ ] `/settings`/`/set` で `bbl.ini` に差分だけ反映(コメント・行順保持)
- [ ] `--scale 6` 等 CLI 併用時、`/set` を使わなければ `bbl.ini` の scale が変化しない
- [ ] ゲーム実行中に `/` でコマンドモード、SDL ウィンドウが応答不能にならない、`/set volume 50` が機能
- [ ] 可能なら macOS Terminal / Linux 実機確認
**参照**: プランファイルの「検証方法」セクション。
**完了条件 (DoD)**: チェックリスト全項目 + 検証ログに記録。
**検証方法**: 各項目を手動実行。
**落とし穴**: なし(既知の落とし穴は各タスクに記載済み)。
**依存**: T12-1, T12-2, T12-3, T12-4, T12-5

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-17 T12-1 完了: `odin build src/app -collection:bbl=src -out:bbl -debug` 成功、
`odin test tests -collection:bbl=src` 420件全パス(Line_Editor の単体テスト5件を追加:
文字蓄積+Enter確定、Backspace、空状態でのBackspaceが範囲外アクセスしないこと、Escapeでの
クリア、制御文字フィルタ、reset)。`src/app/tui.odin` に `Line_Editor`/`line_editor_feed`/
`line_editor_text`/`line_editor_reset`/`line_editor_destroy` を追加。`context.allocator` を
明示使用(T9-6 の temp_allocator 実機バグを踏まえた設計方針どおり)。

2026-07-17 T12-2 完了: `odin build src/app -collection:bbl=src -out:bbl -debug` 成功、
`odin test tests -collection:bbl=src` 424件全パス(config_patch_ini の単体テスト4件を追加:
対象キーだけ置換されコメント・行順が保持されること、変更が空ならバイト単位で元と一致すること、
存在しないキーは末尾に追記されること、コメントアウトされた行はキーとして扱わないこと)。
`src/app/config.odin` に `config_patch_ini`/`config_patch_file` を追加(map 再シリアライズでは
なく行単位走査による置換方式、コメント・行順を保持する設計方針どおり)。

2026-07-17 T12-3 完了: `odin build src/app -collection:bbl=src -out:bbl -debug` 成功、
`odin test tests -collection:bbl=src` 433件全パス(parse_home_command 6件、
tui_render_home_screen 3件を追加)。`src/app/tui.odin` に `TUI_LOGO`(複数行 ASCII アート)、
`Home_Command`/`parse_home_command`(純粋関数)、`tui_render_home_screen`(描画とI/Oを分離した
純粋関数)、`tui_run_command_home` を追加。`run_tui` を `Tui_Screen`(Home/Browse/Recent)の
2段ループに書き換え、既存の `tui_run_rom_browser`/`tui_run_recent_browser` 自体のロジックは
無改修(呼び出し元のループ構造のみ変更)。フッター文言を「q 終了」→「q 戻る」に修正
(ブラウザ側の q が「プロセス終了」から「ホームへ戻る」に意味が変わったため)。`--recent` は
初回のみホーム画面をスキップして直接 recent 画面を開く優先順位を維持。
**実装中に発見した見た目の問題と修正**: 当初ロゴの各行を `display_width` ベースで個別に
中央寄せしていたところ、行ごとに幅が違う ASCII アートでは左端がジグザグに崩れて見えることが
pty 検証で判明(単体テストは文字列の部分一致しか見ておらず、この種の見た目崩れは検出できない
種類のバグだった)。ロゴ全体の最大幅を基準に共通の左パディングを1回だけ計算し、全行に同じ
パディングを使う方式に修正して解消。
pty(`pty.openpty`)で配線を検証: (1) `./bbl` 起動→ロゴ+プロンプト画面表示→`/browse`入力→
既存 ROM ブラウザ画面(「ROM を選択してください」)へ遷移→`q`→ホーム画面へ戻る→`/quit`→
プロセス正常終了(exit status 0)の一巡を確認。(2) `./bbl --recent` がホーム画面(ロゴ)を
スキップし、直接 recent 画面(「最近使ったファイル」「履歴がありません」)を表示することを確認。

2026-07-17 T12-4 完了: `odin build src/app -collection:bbl=src -out:bbl -debug` 成功、
`odin test tests -collection:bbl=src` 441件全パス(parse_home_command の /settings・/set 系4件、
config_apply_set の4件を追加)。`src/app/config.odin` に `config_apply_set`(検証・適用・
config_patch_file への即時書き戻しを一体化)を追加。`src/app/tui.odin` に `Settings_Field`・
`tui_run_settings_menu`(↑↓選択→Enter編集→Enter確定の対話メニュー、既存の `Tui_Frame`/
`List_Item` を再利用)を追加し、`Home_Command_Kind` に `.Settings`/`.Set` を追加、
`parse_home_command` を `/settings`(引数無し)・`/set <key> <value>` にも対応させた。
`/settings`・`/set` はホーム画面のループ内で完結処理し(画面遷移せず)、処理後はホーム画面に
留まる設計とした。書き戻しは T12-2 の行単位パッチ方式のため、値を変更してもコメント・
他の設定項目は保持される(pty検証で確認、下記)。
**実装中に発見したバグと修正**: `config_apply_set` 内で `config_path(config_dir)` の戻り値
(`fmt.tprintf` = temp_allocator の借用)に対して `defer delete(path)` していたため
memory tracking が `bad free` を検出(config.odinの既存関数群と同じ規約——`config_path` の
戻り値は呼び出し側が delete しない——を見落としたための単純なミス)。該当 `defer delete`を
削除して解消(同種のミスをテストコード側にも作ってしまっていたため合わせて修正)。
`live_cfg` というローカル変数を run_tui に追加(Odin は関数パラメータのアドレスを直接
取れない制約があるため、`&cfg` が使えず一度ローカル変数へコピーする必要があった)。
以降、run_rom_window へは `live_cfg`(/set で更新され得る)を渡すよう変更。
pty(`pty.openpty`)で実際の配線を検証: (1) `/set volume 55` 実行後、応答メッセージ表示・
`bbl.ini` の `volume` 行だけが `55` に変わり `scale = 4` 等の他のデフォルト値・コメントが
保持されることを確認。(2) 続けて `/settings` を開くと一覧に `volume: 55` が反映されている
ことを確認、Esc でホーム画面へ戻れることを確認。(3) `/set volume abc`(不正値)ではエラー
メッセージが表示され `bbl.ini` の `volume` が `55` のまま変化しないことを確認
(CLI引数由来の一時値・不正値の両方が誤って永続化されない設計どおり)。

2026-07-17 T12-5 完了: `odin build src/app -collection:bbl=src -out:bbl -debug` 成功、
`odin test tests -collection:bbl=src` 447件全パス(game_key_to_action の `/` 1件、
parse_game_command 5件を追加)。`src/app/tui.odin` に `Game_Action.Enter_Command_Mode`
(`/` キー)、`Game_Command`/`parse_game_command` を追加。`src/app/main.odin` の
`run_rom_window` に `/` トリガーでのコマンドモードを追加し、`config_dir_path()` の解決と
`live_cfg`(/set で更新可能なローカルコピー)をループ開始前に用意。既存の1文字ホットキー
処理はそのまま維持し、コマンドモード中は同じ `key_reader_poll` イベントを `Line_Editor` へ
routing する形にした。`paused` の一時停止/再開を `game_pause_for_command_mode`/
`game_resume_after_command_mode` という小さいヘルパーへ抽出(呼び出し元がコマンドモード
突入前の一時停止状態を憶えておき、抜けるときにその状態だけ復元する)。
**プラン方針どおり、ゲーム中に対話メニュー(`/settings`)は一切開かない**(`Settings_Unavailable`
を返しメッセージ表示のみ)。`/set <key> <value>` のみ許可し、確定時は `config_apply_set` で
検証・適用・`bbl.ini` への即時書き戻し、`volume` の場合は追加で `audio_set_volume` を呼び
実際の音量にも即時反映する。
**実装中に発見し修正したバグ**: (1) `config_apply_set` 内外で `config_path()`(`fmt.tprintf`
= temp_allocator の借用)に対する不要な `defer delete` が残っており memory tracking の
`bad free` を誘発していた点は T12-4 で修正済みだったが、同種のミスが無いか再確認した。
(2) **表示と入力パースの不整合**: 当初 `parse_game_command` は入力に `/set ` プレフィックスを
要求していたが、コマンドモードの画面エコー(`\r\x1b[K/%s_`)は `/` を固定表示として常に
前置する設計にしたため、ユーザーが実際に打つ文字列(Line_Editor に蓄積される内容)には
先頭の `/` が含まれない。pty 検証で「`set volume 30` と打っても "不明なコマンドです" に
なる」という形で顕在化(単体テストは `parse_game_command` に直接 `/set ...` という
文字列を渡していたため、この画面表示との不整合を検出できていなかった)。
`parse_game_command` の期待形式を `set <key> <value>`(`/` 無し)に修正して解消。
pty(`pty.openpty`)で実際の ROM(`tests/roms/mooneye/acceptance/rapid_di_ei.gb`)を
`bbl test.gb`(直接起動)で実行して検証: (1) `/` でコマンドモードに入り入力エコーが表示、
`set volume 30` を確定すると `vol 30%` がステータス行に反映され `bbl.ini` にも
`volume = 30` として書き込まれることを確認。(2) `/` → 入力 → Esc でキャンセルすると
"Command cancelled" が表示され、ゲームループが継続する(プロセスが生きたまま、SDL幽霊化
の兆候なし)ことを確認。(3) `set volume abc`(不正値)はエラー表示のみで `bbl.ini` は
変化しないことを確認。(4) `settings`(引数無し)はゲーム中では「ホーム画面(TUI)で
実行してください」と表示するのみで対話メニューには遷移しないことを確認。
**未確認**: SDL ウィンドウそのものへのフォーカス切り替え・実際のキーボード入力(この
開発環境に対話的GUIセッションが無く、T9-2/T9-6から継続する既知の制約)。ターミナル側の
配線(stdin/stderr経由)は上記の通り確認済み。
