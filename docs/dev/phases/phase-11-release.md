# フェーズ 11: リリース・配布

## 前提

- 依存フェーズ: 10（macOS/Linux のビルドがグリーン。2026-07-16、Windows/Raspberry Pi OS/FreeBSDは
  ユーザー承認により対応対象外となった。docs/dev/phases/phase-10-cicd.md 参照）
- BluePrint: 「頒布する形式は全てのプラットフォームで zip ファイルとし、この中に必要ならライセンスファイルも同梱する」

## ゴール

GitHub Release の作成（タグ push）だけで、macOS/Linux の zip が自動的に添付される。

## フェーズ完了の検証コマンド

```sh
gh release create v0.1.0 --title "v0.1.0" --notes "..." # → zip が自動添付される
gh release view v0.1.0   # bbl-0.1.0-<platform>-<arch>.zip × 4 種を確認
```

---

### T11-1: バージョンの単一の源と抽出

- [x] 完了

**目的**: バージョン定義を 1 箇所（T0-2 の `src/app/version.odin`）に保ち、CI から抽出できるようにする。
**作るもの**:
- 抽出コマンドを確定し全 workflow で共通化:
  `sed -n 's/^VERSION :: "\([0-9][0-9.]*\)"/\1/p' src/app/version.odin | head -n 1`
- `scripts/get_version.sh` としてスクリプト化（workflow はこれを呼ぶ。M88M 方式の sed 直書きより一段安全）
- リリースファイル名は **Git タグではなくこの VERSION から生成**（M88M と同じ。タグ名と独立である点をコメントに明記）
**参照**: `~/dev/_Emu/M88M/.github/workflows/publish-release-assets.yml`（sed 抽出）、phase-00 T0-2
**完了条件 (DoD)**: `./scripts/get_version.sh` が `0.1.0` を出力。version.odin の値と `bbl -v` の出力が一致。
**検証方法**:
```sh
./scripts/get_version.sh
./bbl -v
```
**落とし穴**: version.odin の書式（`VERSION :: "x.y.z"`）を変えると抽出が壊れる。書式チェックを CI に足す（抽出結果が空ならジョブ失敗）。
**依存**: なし

---

### T11-2: zip パッケージングスクリプト

- [x] 完了

**目的**: 配布 zip を作るスクリプトをローカル/CI 共通で用意する。
**作るもの**: `scripts/package_zip.sh`:
- 入力: バイナリパス・プラットフォーム名・arch。出力: `bbl-<version>-<platform>-<arch>.zip`
- 同梱物: `bbl` + `LICENSE` + `README.md`。**zip 内に余計なディレクトリ階層を作らない**（展開したらファイルが直接出る。M88M docs/CI.md の「二重ラップ回避」）
- 命名規約: すべて小文字、platform ∈ {macos, linux}、arch ∈ {x86_64, arm64, amd64}（BluePrint の対応表と一致させる）
**参照**: `~/dev/_Emu/M88M/docs/CI.md`（命名規約）、BluePrint「CI/CD」
**完了条件 (DoD)**: ローカルで zip を作成し、`unzip -l` で内容 3 ファイル・階層なしを確認。
**検証方法**:
```sh
./scripts/build_macos.sh --release
./scripts/package_zip.sh ./bbl macos arm64
unzip -l bbl-*-macos-arm64.zip
```
**落とし穴**: 実行属性の保持（zip -X ではなく通常 zip で可。各 OS の zip はその OS のジョブで作る）。
**依存**: T11-1

---

### T11-3: リリース発行 workflow

- [x] 完了

**目的**: release published イベントで全成果物を zip 化して Release に添付する。
**作るもの**: `.github/workflows/publish-release-assets.yml`（`workflow_call` の再利用 workflow）:
- 各 build-*.yml に `publish-release` ジョブを追加: `if: github.event_name == 'release'` で再利用 workflow を呼ぶ
- 再利用 workflow: `actions/download-artifact` で成果物収集 → `package_zip.sh` で zip 化 → `gh release upload --clobber`
- **`permissions: contents: write` はこの再利用 workflow のジョブだけ**（build ジョブは read のまま。M88M の権限分離）
**参照**: `~/dev/_Emu/M88M/.github/workflows/publish-release-assets.yml`（構造をほぼ流用可能）
**完了条件 (DoD)**: プレリリースを作成し、4 種の zip（linux×2, macos×2）が自動添付される。
**検証方法**:
```sh
gh release create v0.1.0-rc1 --prerelease --notes "release test"
gh release view v0.1.0-rc1   # zip 4 種を確認後、削除してよい
```
**落とし穴**: release イベント時は concurrency の cancel-in-progress を無効に（M88M 踏襲）。artifact 名と zip 名のマッピングを 1 箇所（workflow の env）に集約。
**依存**: T11-1, T11-2, フェーズ 10 全体

---

### T11-4: README・ドキュメント整備

- [ ] 完了

**目的**: 配布に足る利用者向けドキュメントにする。
**作るもの**: `README.md` 拡充:
- 概要、スクリーンショット（TUI とゲーム画面）、対応プラットフォーム表（BluePrint 転記）
- インストール（Release zip の展開のみ）、使い方（`bbl -h` 全文 + ショートカット表 + TUI 説明）
- 設定ファイル (bbl.ini) の全項目リファレンス
- ビルド方法（mise → scripts）、テスト ROM の入手（fetch スクリプト）
- ライセンス節（MIT + テスト ROM は同梱しない旨）
- **実 BIOS 非対応の明記**、実ユーザー名がドキュメントに含まれないこと
**参照**: BluePrint.md 全文、`~/dev/_Emu/BubiBoy/README.md`（構成の参考）
**完了条件 (DoD)**: README に上記全節が存在。`git grep -i "$(whoami)"` ヒット 0。
**検証方法**:
```sh
git grep -i "$(whoami)" || echo OK
```
**落とし穴**: スクリーンショットの撮影環境のパス（ウィンドウタイトル等）に実ユーザー名が写り込まないよう確認。
**依存**: なし

---

### T11-5: リリースドライランと v0.1.0

- [ ] 完了

**目的**: フェーズ 11 = プロジェクト全体のマイルストーン。最初の公開リリースを出す。
**作るもの**: 手順の実施と最終確認:
1. 全フェーズのダッシュボードが 🟢 であること（8/9 の残タスクがあれば先に完了）
2. `odin test tests` 全パス、全 workflow グリーン
3. プレリリース (rc) で T11-3 の 4 zip を確認 → 各 OS（手元にある範囲: macOS 必須、Linux は可能な範囲）で zip 展開 → `bbl -v` と実ゲーム起動
4. 問題なければ `v0.1.0` を正式リリース
5. PLAN.md のダッシュボードを全完了に更新し、次期計画（精度向上、追加 MBC 等）の候補メモを検証ログに残す
**参照**: PLAN.md
**完了条件 (DoD)**: GitHub Release v0.1.0 に 4 zip が添付され、macOS の zip からの展開バイナリで実ゲームがプレイできる。
**検証方法**:
```sh
gh release view v0.1.0
# ダウンロード → 展開 → ./bbl <ゲーム>
```
**落とし穴**: zip からの実行は「ビルドディレクトリの隣に bbl.ini や .sav がない初回起動」なので、設定自動生成（T8-1）の初回パスが本当に動くかの最終確認になる。macOS では初回実行時の quarantine（Gatekeeper）挙動を README に注記。
**依存**: T11-3, T11-4

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-16 T11-1 完了: `scripts/get_version.sh` を作成。`./scripts/get_version.sh` が `0.1.0` を出力し、
`./bbl -v` の `bbl 0.1.0` と一致することを確認。

2026-07-16 T11-2 完了: `scripts/package_zip.sh` を作成。`./scripts/build_macos.sh --release` →
`./scripts/package_zip.sh ./bbl macos arm64` → `unzip -l bbl-0.1.0-macos-arm64.zip` で
`bbl`/`LICENSE`/`README.md` の 3 ファイル・階層なしを確認。展開後 `bbl` に実行権限が保持され
（`-rwxr-xr-x`）、`./bbl -v` が正常動作することも確認済み（macOS arm64 実機）。

2026-07-16 T11-3 完了: `.github/workflows/publish-release-assets.yml`（`workflow_call` 再利用 workflow）
を作成。`actions/download-artifact` で生バイナリ artifact を回収 → artifact 名（`bbl-<platform>-<arch>`）
から platform/arch を切り出し `scripts/package_zip.sh` で正式 zip を生成 → `gh release upload --clobber`。
`build-linux.yml`・`build-macos.yml` それぞれに `publish-release` ジョブ（`needs: build`、
`if: github.event_name == 'release'`、`permissions: contents: write` はこのジョブのみ）を追加し
この再利用 workflow を呼ぶ。ユーザー承認のうえ実際に `gh release create v0.1.0-rc1 --prerelease` で
検証: release イベントで両 workflow が自動発火し、`gh release view v0.1.0-rc1` で
`bbl-0.1.0-linux-amd64.zip`・`bbl-0.1.0-linux-arm64.zip`・`bbl-0.1.0-macos-arm64.zip`・
`bbl-0.1.0-macos-x86_64.zip` の 4 種が自動添付されたことを確認（`unzip -l` で中身 3 ファイル・
階層なしも確認）。検証後 `gh release delete v0.1.0-rc1` でプレリリースとタグを削除済み。
