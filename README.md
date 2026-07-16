# BubiBoyLite

Odin + SDL2 で実装する Game Boy Color エミュレーター（実行ファイル名 `bbl`）。
仕様の唯一の源は [docs/dev/BluePrint.md](docs/dev/BluePrint.md)。
開発計画は [docs/dev/PLAN.md](docs/dev/PLAN.md) を参照。

[![Build Linux](https://github.com/bubio/BubiBoyLite/actions/workflows/build-linux.yml/badge.svg)](https://github.com/bubio/BubiBoyLite/actions/workflows/build-linux.yml)
[![Build macOS](https://github.com/bubio/BubiBoyLite/actions/workflows/build-macos.yml/badge.svg)](https://github.com/bubio/BubiBoyLite/actions/workflows/build-macos.yml)

## 概要

CLI 中心の Game Boy Color エミュレーターです。引数なしで起動すると Claude Code 風の
TUI（テキストベース UI）が立ち上がり、ROM 選択からゲーム起動・終了までターミナル上で完結します。
ゲームコントローラーにも対応しています。

<!--
  スクリーンショット未収録（この環境には SDL2 ウィンドウを表示できるディスプレイが無いため撮影不可）。
  実機で撮影後、以下のように差し替えてください:
  ![TUI screenshot](docs/img/tui.png)
  ![Game screenshot](docs/img/game.png)
-->
TUI 画面とゲーム画面のスクリーンショットは未収録です。実機でお試しの際はぜひ撮影してみてください。

## 対応プラットフォーム

| OS | アーキテクチャ |
|---|---|
| macOS 13.5 以上 | x86_64, Apple Silicon (arm64) |
| Ubuntu 22.04 以上 | amd64, arm64 |

macOS 版はユニバーサルバイナリではなく、アーキテクチャごとに別バイナリで配布します。
Windows・Raspberry Pi OS・FreeBSD には対応していません
（2026-07-16、対応対象から除外。経緯は [phase-10-cicd.md](docs/dev/phases/phase-10-cicd.md) 参照）。

## 動作要件

SDL2 がシステムにインストールされている必要があります（ビルド時・実行時とも動的リンク）。

```sh
brew install sdl2               # macOS
sudo apt install libsdl2-2.0-0  # Linux（ビルドする場合は libsdl2-dev）
```

## インストール

[Releases](https://github.com/bubio/BubiBoyLite/releases) から自分のプラットフォームに合った
zip をダウンロードして展開するだけです。展開すると `bbl` 本体・`LICENSE`・`README.md` が
同じ階層に並びます。

```sh
unzip bbl-<version>-<platform>-<arch>.zip
./bbl game.gbc
```

macOS では初回実行時に Gatekeeper（quarantine）によって「開発元が未確認」の警告が出ることがあります。
その場合は `xattr -d com.apple.quarantine ./bbl` を実行するか、Finder で右クリック →「開く」を選んでください。

## 使い方

```
使用法: bbl [options] game.gbc

  -h, --help        コマンドラインの使い方を表示
  -v, --version     バージョンを表示
  --scale N         表示倍率 (1-8、9以上は8に丸める、デフォルト 4)
  --fullscreen      フルスクリーン表示 (--scale は無視される)
  --shader KIND     シェーダー: nearest, smooth (デフォルト nearest)
  --recent          最近使ったファイルを表示して選択

キーボードショートカット(ROM実行中):
  矢印キー          十字キー
  Z / X             B / A
  Enter             Start
  右Shift           Select
  F1-F4             セーブステートのスロット選択 (1-4、デフォルト 1)
  F5                現在のスロットへセーブステートを保存
  F7                現在のスロットからセーブステートを復元
  Esc               終了
```

ROM を指定せずに `bbl` だけを実行すると TUI が起動し、カレントディレクトリ（`rom_dir` 設定時はそこ）の
`.gb`/`.gbc` ファイルを一覧表示します。矢印キーで選択・Enter で起動・q で終了です。
`--recent` を付けると最近使ったファイルの履歴（最大20件）から選べます。ROM ファイルの指定がある場合は
そちらが優先され、`--recent` は無視されます。

ゲーム実行中は SDL ウィンドウが主役になりますが、起動元のターミナルには FPS・音量・スロット・
カートリッジ種別などのステータス行が表示され続けます。ターミナル側からも次のキーで操作できます
（SDL ウィンドウ側のショートカットと同じ結果になります）:

| キー | 動作 |
|---|---|
| `+` / `-` | 音量を上下 |
| `1`-`4` | セーブステートのスロット選択 |
| `s` | 現在のスロットへ保存 |
| `l` | 現在のスロットから復元 |
| `p` | 一時停止 / 再開 |

## 設定ファイル (bbl.ini)

初回起動時、実行ファイルと同じ場所に `bbl.ini` が全デフォルト値で自動生成されます。
コマンドライン引数はここに書かれた値を一時的に上書きしますが、設定ファイルへの書き戻しはしません
（優先順位: CLI 引数 > 設定ファイル > デフォルト）。`#` から行末まではコメントです。

| キー | 内容 | デフォルト |
|---|---|---|
| `scale` | 表示倍率 (1-8) | `4` |
| `fullscreen` | フルスクリーン表示 (`true`/`false`) | `false` |
| `shader` | シェーダー (`nearest`/`smooth`) | `nearest` |
| `save_dir` | セーブファイル(`.sav`/`.rtc`)の保存先。空欄なら ROM と同じ場所 | (空欄) |
| `state_dir` | ステートファイル(`.state`)の保存先。空欄なら ROM と同じ場所 | (空欄) |
| `rom_dir` | TUI の ROM 一覧が開く起動ディレクトリ。空欄ならカレントディレクトリ | (空欄) |
| `volume` | 音量 (0-100) | `100` |
| `key_up`/`key_down`/`key_left`/`key_right`/`key_a`/`key_b`/`key_start`/`key_select` | キーボード割当（SDL キー名） | 矢印キー / Z・X / Enter / 右Shift |
| `pad_up`/`pad_down`/`pad_left`/`pad_right`/`pad_a`/`pad_b`/`pad_start`/`pad_select` | ゲームコントローラー割当（SDL ボタン名） | 十字キー / B・A / Start / Back |

`save_dir`/`state_dir` は `~` や環境変数（`HOME` 等）の展開に対応しています。
キー/ボタン割当がセーブステート操作(F1-F5, F7)や終了(Esc)のショートカットと衝突する場合、
起動時に警告が出ます。

## ビルド方法

```sh
mise install
./scripts/build_macos.sh   # Linux なら build_linux.sh
```

`--debug` でデバッグビルド、`--release` でリリースビルド（最適化 + macOS は `-minimum-os-version` 指定）、
`--test` でビルド後に `odin test tests -collection:bbl=src` も実行します。

テスト ROM（Blargg・Mooneye・dmg-acid2 等）はライセンスの都合でリポジトリに同梱していません。
`./scripts/fetch_test_roms.sh` でピン止めされたバージョンを取得できます（詳細は
[docs/dev/testing.md](docs/dev/testing.md)）。

配布用 zip は `./scripts/package_zip.sh <binary> <platform> <arch>` で作成します
(`bbl`/`LICENSE`/`README.md` を同梱、階層なし)。タグ付き GitHub Release を作成すると
CI が自動的に全プラットフォームの zip を添付します。

## ライセンス

[MIT](LICENSE)。BubiBoy 自体のソースコードのみが対象で、テスト ROM（Blargg・Mooneye・dmg-acid2 等）は
それぞれ別ライセンスの第三者成果物のためリポジトリに同梱していません。

実 BIOS（ブートROM）の読み込みには対応していません。起動時は各モードのブート後レジスタ状態を
直接セットします。
