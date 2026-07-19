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

- [ ] 完了

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

- [ ] 完了

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
