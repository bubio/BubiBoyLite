# フェーズ 18: ステータス行の整理(ROM名の分離・メッセージ重複表示の削除・表記修正)

## 前提

- 依存フェーズ: 17(ioctl可変引数ABIバグ修正、完了済み)。
- 経緯: フェーズ17でTUI最下部固定バグが解消し、ユーザーが実機で1行のステータス表示を
  確認したところ、以下を指摘(2026-07-19):

```
▶ Wizardry I - Proving Grounds of the Mad Overlord (Japan).gbc | 59.0 fps | vol 80% | slot 1 | MBC5+RAM | 双速 | State loaded from slot 1
```

  1. ステータスを1行に詰め込みすぎ。ROM名は別の行に分けてほしい
  2. コマンド実行結果(`State loaded from slot 1` 等)はコンテンツ領域のメッセージログに
     既に表示されているので、ステータス行に重複して出す必要はない
  3. 「双速」という表記が分かりにくい(ユーザーから「これは何?」と質問があり、Fableが
     回答済み: GBC実機のCPU倍速モードを再現できているかを示す表示。表記を「2倍速」に変える)

## ゴール

ステータス行を `▶ 59.0 fps | vol 80% | slot 1 | 2倍速` のような簡潔な形式にし、ROM名+
カートリッジ種別はコンテンツ領域(Now Playing)の見出し行へ移動する。コマンド実行結果は
コンテンツ領域のメッセージログにのみ表示し、ステータス行には出さない。「双速」を
「2倍速」に統一する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # status_line_format/shell_content_now_playing のテスト PASS
./scripts/build_macos.sh --test       # -o:speed ビルド+全テスト成功
./bbl game.gbc                        # コンテンツ領域見出しにROM名+カートリッジ種別、
                                       # ステータス行は簡潔な形式、コマンド結果はログのみ
```

## 対応方針(実装前に読むこと)

### A. ROM名をステータス行からコンテンツ領域の見出しへ移動

`shell_content_now_playing` のタイトル行(`"BubiBoyLite v%s — Now Playing"`)を、ROM名+
カートリッジ種別に置き換える:

```odin
append(&lines, fmt.aprintf("%s  %s", s.rom_name, s.cart_label, allocator = allocator))
```

以降のブランク行・メッセージログ部分は無変更。

### B. ステータス行からROM名・カートリッジ種別・メッセージ抑制を削除

`status_line_format` を以下に整理する:

```odin
status_line_format :: proc(s: Status_Line, fps: f64, volume: int, slot: int, double_speed: bool, paused: bool) -> string {
	icon := paused ? "⏸" : "▶"
	speed_label := double_speed ? " | 2倍速" : ""
	warn_marker := s.warn ? " \x1b[33m⚠ underrun\x1b[0m" : ""

	return fmt.tprintf(
		"%s %.1f fps | vol %d%% | slot %d%s%s",
		icon,
		fps,
		volume,
		slot,
		speed_label,
		warn_marker,
	)
}
```

`rom_name`/`cart_label`/`msg_suffix`(`last_message` 由来)を削除。`status_line_set_message`
は引き続き `message_log` への追記を行うため、メッセージ自体はコンテンツ領域のログに
残り続ける。`last_message` フィールド自体は将来のデバッグ用として残す。

### C. 「双速」→「2倍速」表記変更

上記Bの `speed_label` 変更に含まれる。他に「双速」という文字列が出る箇所がないか
grep で確認する(過去フェーズの検証ログ・ドキュメントは履歴として無変更のまま残す)。

## 壊してはいけない既存資産

- `message_log_append`・`Message_Log` の仕組み(コンテンツ領域のメッセージログ表示)は無変更
- ステータス行の pause アイコン(⏸/▶)・fps・volume・slot・underrun警告表示は維持
- Now Playing 以外の画面(Settings/ホーム/ブラウザ)は無関係、無変更

---

### T18-1: status_line_format の整理+「2倍速」表記

- [x] 完了

**目的**: ステータス行から重複情報(ROM名・カートリッジ種別・コマンド実行結果)を除き、
「双速」を分かりやすい表記に変える。
**作るもの**: `src/app/tui.odin`:
- `status_line_format` から `rom_name`/`cart_label`/`msg_suffix`(`last_message` 由来)を削除
- `speed_label` を `" | 双速"` から `" | 2倍速"` に変更
**参照**: `status_line_set_message`(message_log への追記は無変更)
**完了条件 (DoD)**: 単体テストでステータス行にROM名・カートリッジ種別・last_messageの
内容が含まれないこと、fps/vol/slot/アイコン/2倍速表記は含まれることを検証できる。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: `last_message` フィールド自体は削除しない(message_log 追記のトリガーとして
`status_line_set_message` 内で引き続き使う)。
**依存**: なし

---

### T18-2: shell_content_now_playing の見出しをROM名+カートリッジ種別に変更

- [x] 完了

**目的**: ステータス行から追い出したROM識別情報の行き先を用意する。
**作るもの**: `src/app/tui.odin`:
- `shell_content_now_playing` のタイトル行を `fmt.aprintf("%s  %s", s.rom_name, s.cart_label, ...)`
  に変更、コメントを今回の経緯に合わせて更新
**参照**: T18-1
**完了条件 (DoD)**: 単体テストで見出しにROM名+カートリッジ種別が含まれ、状態/fps/音量/
スロットの詳細行は引き続き含まれない(ステータス行の担当のまま)ことを検証できる。
**検証方法**: `odin test tests -collection:bbl=src` + pty(実際の画面表示確認)。
**落とし穴**: メッセージログ部分の残り行数計算(`avail_rows - len(lines) - 2`)は
タイトル行が1行であることに変わりないため無変更でよい。
**依存**: T18-1

---

### T18-3: 仕上げ(pty回帰確認、-o:speed往復、docs記録)

- [ ] 完了(自動検証は全て完了・クラッシュなし。実機 macOS Terminal.app での最終確認
      のみ残、下記参照)

**目的**: フェーズ18のマイルストーン。
**作るもの**: デバッグと検証のみ。
**完了条件 (DoD)**: `odin test` 全パス + 両ビルド成功 + フェーズ17で確立した複数winsize
手法でのpty回帰確認(レイアウト崩れが無いこと)。実機 macOS Terminal.app での最終確認は
ユーザー側で実施(残項目として記録)。
**検証方法**: `./scripts/build_macos.sh --test` / `--debug --test` / pty複数サイズ一式。
**落とし穴**: なし。
**依存**: T18-1, T18-2

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-19 T18-1 完了: `odin test tests -collection:bbl=src` 475件全パス
(`test_status_line_format_contents` を新仕様に書き換え(ROM名/カートリッジ種別が
含まれないこと、「2倍速」表記、「双速」が出ないことを検証)、
`test_status_line_format_omits_last_message` を新規追加(last_messageの内容がステータス
行に出ないことを確認))。`status_line_format` から `rom_name`/`cart_label`/`msg_suffix`
を削除し `"%s %.1f fps | vol %d%% | slot %d%s%s"` の簡潔な形式に整理、`speed_label` を
「2倍速」に変更。`./scripts/build_macos.sh`(-o:speed)成功。
`grep -rn "双速"` で他の出現箇所を確認し、過去フェーズの検証ログ・ドキュメント
(phase-09-tui.md、phase-13-tui-game-menu.md)以外に残っていないことを確認(履歴記録
なので書き換えない)。

2026-07-19 T18-2 完了: `odin test tests -collection:bbl=src` 475件全パス
(`test_shell_content_now_playing_panel` を新仕様(見出しにROM名+カートリッジ種別が
含まれる)に書き換え)。`shell_content_now_playing` のタイトル行を
`fmt.aprintf("%s  %s", s.rom_name, s.cart_label, ...)` に変更、コメントを「T16-1で
一旦削除→T18-2で見出しへ移動」という経緯に更新。`./scripts/build_macos.sh`
(-o:speed)成功。
pty検証(実ROM): (1) コンテンツ領域見出しに「rapid_di_ei.gb MBC5+RAM等のカートリッジ
種別」が表示されること、(2) ステータス行が `▶ 60.0 fps | vol 80% | slot 1` のような
簡潔な形式でROMファイル名を含まないこと、(3) 出力全体に「双速」が一切出現しないこと、
(4) `/save` 実行後 "State saved to slot 1" がコンテンツ領域のメッセージログに表示され、
その後のステータス行の再描画(1秒tick)には一切含まれない(重複しない)ことを確認。
ユーザー指摘のスクリーンショット例(ROM名+fps+vol+slot+cart+双速+コマンド結果を
1行に詰め込んでいた形式)からの改善を実バイナリで確認できた。

2026-07-19 T18-3 完了(自動検証は完了・クラッシュなし。実機確認のみ残、チェックは
付けない): `odin test tests -collection:bbl=src` 475件全パス(-o:speed/-debug両方)、
`./scripts/build_macos.sh --debug --test` 成功。
フェーズ17で確立した複数winsize手法(80x24・119x41・119x44・100x30、race-freeな
winsize設定+pyteによる正確な行位置検証)でpty回帰確認を実施し全パス: 全サイズで
コンテンツが実際の最終行まで届き、区切り線・ステータス行・入力行がそれぞれ
rows-2/rows-1/rows行目にちょうど来ることを再確認(T18の変更によるレイアウト崩れなし)。
既存のpty回帰スクリプト群(T13〜T16由来)の一部が、T18-2で削除した固定文字列
「Now Playing」を直接アサートしていたため「ROM名見出しが表示されること」の確認に
書き換えて再実行(内容の変更であって挙動の後退ではないことを確認した上での更新):
T14固定レイアウト回帰確認19項目、T13/T14フルラウンドトリップ3回、T15総合コマンド
オンリー確認14項目、T16-1のNow Playing簡素化確認8項目、T14-6のリサイズ+SIGTERM
復元確認5項目、いずれも全パス。`-debug`ビルドでも100x30での行位置確認がクリーン。
各検証ともbbl.iniは検証前後でバイト一致。最終バイナリは`-o:speed`で再ビルド済み。
**残項目**: 実機 macOS Terminal.app での最終確認 — ステータス行が簡潔になり、ROM名が
コンテンツ領域に表示され、「2倍速」表記になっていることの目視確認。ユーザー側での
確認をお願いする。PLAN.mdはこのため🟡のまま、タスク数2/3で据え置く。
