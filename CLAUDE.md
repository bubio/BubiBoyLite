# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Game Boy Color エミュレーター。正式名称は **BubiBoyLite**、実行ファイル名は **bbl**。
`docs/dev/BluePrint.md` が仕様の唯一の源。実装方針の判断は必ず BluePrint を参照すること。

## 開発計画書（実装時はここから始める）

開発は `docs/dev/PLAN.md` のフェーズ計画に沿って進める。

1. **まず `docs/dev/PLAN.md` の進捗ダッシュボード**で現在のフェーズを特定する
2. そのフェーズの詳細ファイル `docs/dev/phases/phase-NN-*.md` と `docs/dev/architecture.md` を読む（全フェーズを読む必要はない）
3. タスクの「検証方法」を実行して成功した場合のみチェックを付け、PLAN.md の進捗更新ルールに従って記録する

補助資料: `docs/dev/testing.md`（テスト ROM 戦略）、`docs/dev/references.md`（I/O レジスタ表・BubiBoy 対応表）。

## 技術スタック / ツールチェイン

- 言語は **Odin**。`mise` 経由でインストール済み（`mise.toml` でバージョン固定: `odin = "dev-2026-07"`）。`mise install` でセットアップし、`odin` コマンドが使えることを確認する。
- 描画・音声・入力は **SDL2**。**静的リンク**して単一実行ファイルで動くようにする（配布物は実行ファイル + 必要ならライセンスのみ）。
- UI は CLI が主体。加えて Claude Code のような **TUI** も提供する。

## ビルド / 開発

- プラットフォームごとのビルドスクリプトを用意する（macOS/Linux は `sh`、Windows は `ps1`）。
- **同じスクリプトを CI/CD からも呼び出し**、ローカルと CI で差異が出ないようにするのが設計意図。ビルド手順をスクリプトと GitHub workflow に二重管理しないこと。
- CI/CD は GitHub Actions で行う。実装時は `~/dev/_Emu/M88M` の workflow を参考にする。
- 配布形式は全プラットフォームで **zip**。

## 対応プラットフォーム

macOS 13.5+ (Xcode 26 想定 / x86_64・Apple Silicon を **別バイナリ**、ユニバーサルにしない), Windows 10+ (x32/x86_64/arm64), Ubuntu 22.04+ (amd64/arm64), Raspberry Pi OS (armhf), FreeBSD 14+ (x86_64)。できるだけ広いアーキテクチャをカバーする方針。

## 設定・セーブファイルの配置ルール

- **設定ファイル**: 実行ファイルと同じ場所。起動時に無ければ全デフォルト値で自動生成する。
- **セーブ / ステートファイル**: 実行中の ROM ファイルと同じ場所がデフォルト。設定ファイルで変更可能。

## CLI オプション（BluePrint 準拠）

`bbl [options] game.gbc`

- `--scale`: 表示倍率 1〜8（超過は 8 に丸め）。デフォルト 4。
- `--fullscreen`: 画面に収まる最大整数倍率で表示。指定時は `--scale` を無視。
- `--shader`: `nearest`（デフォルト）または `smooth`。
- `--recent`: 最近使ったファイルから選択。ただし ROM 指定があればそちらを優先。
- `-h/--help`, `-v/--version`。

## 重要な制約

- **実 BIOS ROM の読み込みには対応しない**（対応しない機能として明記されている）。
- **実際のユーザー名を絶対にコード / 設定 / コミットに残さない**。パスは必ず `~` や環境変数で表現する。
- ライセンスは MIT 相当のゆるいもの。

## 参考リポジトリ

- `~/dev/_Emu/BubiBoy`: 前身プロジェクト（エミュレーション実装の参考）。
- `~/dev/_Emu/M88M`: CI/CD workflow の参考。
