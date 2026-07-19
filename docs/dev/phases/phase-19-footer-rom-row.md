# フェーズ19: 固定フッターにROM行を追加 + CPU倍速表記の明確化

## 前提

- 依存フェーズ: 18(ステータス行の整理、完了済み)。
- 経緯: フェーズ18の対応をユーザーが確認し、2点の指摘(2026-07-19):
  1. **フェーズ18の理解違い**: ユーザーの本来の要望は「ROM名をステータス表示の中で
     別の行に分けてほしい」であり、「コンテンツ領域(上のスクロールする方)に移して
     ほしい」ではなかった。フェーズ18でコンテンツ領域の見出しに移したのは誤り。
     **固定フッター(区切り線+ステータス関連+入力行)の中に、ROM名専用の行を追加する**
     のが正しい対応
  2. **「2倍速」表記が誤解を招く**: 「2倍速で実行なんてしてない」という指摘どおり、
     この表記はゲーム全体の再生速度が2倍になっていると誤解させる。実際はGBC実機の
     CPUクロックが内部的に2倍になるハードウェアモード(fps自体は変わらない)。
     **CPUの話だと明確にわかる表記に変更する**

## ゴール

固定フッターを「区切り線+meta行(ROM名+カートリッジ種別)+ステータス行+入力行」の
4行構成にする。コンテンツ領域からはT18-2で追加したROM見出し行を削除する(巻き戻し)。
「2倍速」を「CPUクロック倍速」のようなCPUの話だと明確な表記に変更する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # tui_render_shell/shell_content_now_playing/status_line_format のテスト PASS
./scripts/build_macos.sh --test       # -o:speed ビルド+全テスト成功
./bbl game.gbc                        # 固定フッターが区切り線/ROM名+カートリッジ種別/
                                       # ステータス(CPUクロック倍速表記含む)/入力行の
                                       # 4行構成、コンテンツ領域にROM名の重複が無い
```

## 対応方針(実装前に読むこと)

### A. 固定フッターにROM情報行を追加(SHELL_RESERVED_ROWS を 3→4)

`Shell_Frame` に新フィールド `meta: string` を追加。`SHELL_RESERVED_ROWS` を4に変更
(区切り線+meta行+ステータス行+入力行)。`tui_render_shell` で、区切り線の直後・
ステータス行の直前に `meta` を1行追加で書く(他の行と同じく `\x1b[K` + `write_padded`
で幅打ち切り)。

`meta` はデフォルト空文字列(ホーム/ブラウザ/設定(非ゲーム中)の3画面は指定しない=
空行になる)。ゲーム中の `game_shell_draw`(Shell_Frame構築箇所)でのみ
`meta = fmt.tprintf("%s  %s", s.rom_name, s.cart_label)` を設定する(Now Playing・
ゲーム中設定ビューの両方で、ROMが読み込まれている間は常に表示)。

`Shell_Frame` を構築している既存5箇所のうち、ゲーム中の1箇所(`game_shell_draw`)だけ
`meta` を設定し、残り4箇所(ホーム画面本体、設定メニュー、ROMブラウザ、recentブラウザ)
は無指定(空文字のまま)。

### B. コンテンツ領域見出しの巻き戻し(フェーズ18 T18-2の一部取り消し)

`shell_content_now_playing`(T18-2でROM名+カートリッジ種別の見出し行を追加した箇所)
から、その見出し行を削除する(Aで固定フッターに移ったため、コンテンツ領域に置く
必要がなくなった)。先頭の空行だけは間隔として残す。この削除によりメッセージログの
表示可能行数が1行増える。

### C. 「2倍速」表記の明確化

`status_line_format` の `speed_label` を、CPUクロックの話だと明確にわかる表記に
変更する:「CPUクロック倍速」。「CPU」という語を含め、単に「2倍速」だけの表記には
戻さない。

## 壊してはいけない既存資産

- `status_line_format` の他のフィールド(icon/fps/vol/slot/warn_marker)はフェーズ18の
  まま無変更
- ホーム/ブラウザ/設定(非ゲーム中)画面のレイアウトは、`meta`行が空行として増える
  以外は無変更
- `message_log`/`status_line_set_message` の仕組みは無変更

---

### T19-1: Shell_Frame.meta 追加、SHELL_RESERVED_ROWS 3→4

- [x] 完了

**目的**: 固定フッターにROM名専用行を追加するための土台を作る。
**作るもの**: `src/app/tui.odin`:
- `Shell_Frame` に `meta: string` フィールドを追加
- `SHELL_RESERVED_ROWS` を `3` から `4` に変更
- `tui_render_shell` で区切り線の直後・ステータス行の直前に meta 行を描画
**参照**: T14-1(`tui_render_shell`)
**完了条件 (DoD)**: 単体テストで、meta 行が区切り線とステータス行の間に来ること、
meta 未指定時は空行になりレイアウトが崩れないこと、行数・`\x1b[K` 個数の整合性を
検証できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 総行数(`rows`)は変わらないため、既存の行数系アサーション
(`\n` の個数、`\x1b[K` の個数)は変更不要な場合が多いが、`content_rows` の境界に
依存するテスト(切り捨てテスト)は reserved rows の増加分だけ調整が必要。
**依存**: なし

---

### T19-2: game_shell_draw でROM中のみ meta を設定

- [ ] 完了

**目的**: ゲーム中(Now Playing・設定ビューの両方)は固定フッターにROM名+カートリッジ
種別を表示し、それ以外の画面(ホーム/ブラウザ/設定(非ゲーム中))は空行のままにする。
**作るもの**: `src/app/tui.odin`:
- `game_shell_draw` で `meta := fmt.tprintf("%s  %s", s.rom_name, s.cart_label)` を
  計算し、`Shell_Frame` 構築時に渡す(Now Playing・設定ビューの両方の分岐で共通)
- 他4箇所の `Shell_Frame` 構築(ホーム画面本体・設定メニュー・ROMブラウザ・recent
  ブラウザ)は無指定のまま
**参照**: T19-1
**完了条件 (DoD)**: pty検証でゲーム中はROM名+カートリッジ種別が専用行に表示され、
ホーム/ブラウザ/設定は空行のままレイアウトが崩れないことを確認できる。
**検証方法**: pty(実バイナリでの表示確認)。
**落とし穴**: なし。
**依存**: T19-1

---

### T19-3: shell_content_now_playing からROM見出し行を削除(フェーズ18の巻き戻し)

- [ ] 完了

**目的**: T18-2でコンテンツ領域に追加したROM見出し行を取り除く(固定フッターに
移ったため不要)。
**作るもの**: `src/app/tui.odin`:
- `shell_content_now_playing` から `fmt.aprintf("%s  %s", s.rom_name, s.cart_label, ...)`
  の見出し行 append を削除(先頭の空行は間隔として残す)
**参照**: T18-2(巻き戻し対象)
**完了条件 (DoD)**: 単体テストでコンテンツ領域にROM名・カートリッジ種別が含まれない
こと、メッセージログの表示可能行数が1行増えたこと(境界値の変化)を検証できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: メッセージログの残り行数計算(`avail_rows - len(lines) - 2`)は
`len(lines)` が1減ることで自動的に+1される(コード変更不要、境界値のみ変わる)。
**依存**: なし(T19-1と並行可)

---

### T19-4: status_line_format の「2倍速」→CPU明記の表記に変更

- [ ] 完了

**目的**: 「2倍速」がゲーム全体の速度と誤解される問題を解消する。
**作るもの**: `src/app/tui.odin`:
- `speed_label` を `" | 2倍速"` から `" | CPUクロック倍速"` に変更
**参照**: フェーズ18 T18-1(元は「双速」→「2倍速」)
**完了条件 (DoD)**: 単体テストで新表記に「CPU」という語が含まれ、「双速」「2倍速」
単独の表記が残っていないことを検証できる。grep で他に該当箇所が無いことを確認する。
**検証方法**: `odin test tests -collection:bbl=src` + `grep -rn "2倍速\|双速" src tests`
**落とし穴**: `src/core` パッケージ内の「2倍速」はCPU/Timer動作の技術的説明コメントで
あり無関係(TUI表示文字列ではない)。書き換えないこと。
**依存**: なし(T19-1と並行可)

---

### T19-5: 仕上げ(複数winsize回帰確認、-o:speed往復、docs記録)

- [ ] 完了

**目的**: フェーズ19のマイルストーン。
**作るもの**: デバッグと検証のみ。
**完了条件 (DoD)**: `odin test` 全パス + 両ビルド成功 + フェーズ17で確立した複数
winsize手法での回帰確認(区切り線・meta行・ステータス行・入力行が正しく
rows-3〜rows行目に来ること)。実機 macOS Terminal.app での最終確認はユーザー側で
実施(残項目として記録)。
**検証方法**: `./scripts/build_macos.sh --test` / `--debug --test` / pty複数サイズ一式。
**落とし穴**: なし。
**依存**: T19-1, T19-2, T19-3, T19-4

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-19 T19-1 完了: `odin test tests -collection:bbl=src` 477件全パス(新規2件:
meta行が区切り線とステータス行の間(SHELL_RESERVED_ROWS=4のうち4行目中2番目)に来る
こと、meta未指定時は空行になりレイアウトが崩れないこと。既存の切り捨てテスト
(`test_render_shell_truncates_content_to_available_rows`)を rows=6→7 に調整し
reserved rows 増加分(+1)を反映)。`Shell_Frame` に `meta: string` を追加、
`SHELL_RESERVED_ROWS` を3→4に変更、`tui_render_shell` で区切り線の直後・ステータス行の
直前に meta 行を描画するよう追加。`./scripts/build_macos.sh`(-o:speed)成功。
