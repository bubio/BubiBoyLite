# フェーズ 0: 骨格・CLI・SDL2 窓・最小 CI

## 前提

- 依存フェーズ: なし（最初のフェーズ）
- 着手前に [architecture.md](../architecture.md) を必読。ディレクトリレイアウトと core/app 分離はそこで固定済み。
- `mise install` を実行し `odin version` が `dev-2026-07` 系を返すことを確認してから始める。

## ゴール

ビルド・実行・テスト・CI の土台を作る。エミュレーション機能はまだ実装しない。
「SDL2 の窓にテストパターンが出て、CLI 引数が仕様どおりパースされ、CI が回る」状態にする。

## フェーズ完了の検証コマンド

```sh
./scripts/build_macos.sh          # (Linux なら build_linux.sh)
./bbl -v                          # => "bbl x.y.z" を表示して exit 0
./bbl --scale 2                   # => 320x288 の窓にテストパターン表示、Esc で終了
odin test tests -collection:bbl=src   # => 全パス
# GitHub Actions の ci.yml がグリーン
```

---

### T0-1: リポジトリ初期化とパッケージ骨格

- [x] 完了

**目的**: git リポジトリ、Odin パッケージ構造、最小のビルドが通る状態を作る。
**作るもの**:
- `git init`、`.gitignore`（`bbl`, `bbl.exe`, `tests/roms/`, `*.o`, `.DS_Store` など）
- architecture.md のレイアウトどおりに `src/core/`, `src/app/`, `tests/`, `scripts/` を作成
- `src/core/hardware.odin`: 定数 `SCREEN_WIDTH :: 160`, `SCREEN_HEIGHT :: 144`, `CPU_HZ :: 4194304`, `CYCLES_PER_FRAME :: 70224`
- `src/app/main.odin`: `package main` で "BubiBoyLite" を出力するだけの main
- `tests/smoke_test.odin`: `@(test)` で `core.SCREEN_WIDTH == 160` を expect する 1 本
**参照**: architecture.md「ディレクトリレイアウト」
**完了条件 (DoD)**: `odin build src/app -collection:bbl=src -out:bbl && ./bbl` が "BubiBoyLite" を出力。`odin test tests -collection:bbl=src` が 1 テストパス。
**検証方法**:
```sh
odin build src/app -collection:bbl=src -out:bbl && ./bbl
odin test tests -collection:bbl=src
```
**落とし穴**: Odin は 1 ディレクトリ = 1 パッケージ。`src/` 直下に .odin ファイルを置かないこと。collection 名 `bbl` は全コマンドで統一する。
**依存**: なし

---

### T0-2: バージョン定義と -h / -v

- [x] 完了

**目的**: バージョンを単一の場所で定義し、`-h`/`--help` と `-v`/`--version` を実装する。
**作るもの**:
- `src/app/version.odin`: `VERSION :: "0.1.0"`（**この 1 行が全リポジトリで唯一のバージョン定義**。
  フェーズ 11 で CI が sed 抽出するため、`VERSION :: "x.y.z"` の形式を崩さない）
- `src/app/cli.odin`: `-h`/`--help` で BluePrint 記載の使用法を表示して exit 0、`-v`/`--version` で `bbl 0.1.0` を表示して exit 0
**参照**: BluePrint.md「コマンドラインオプション」
**完了条件 (DoD)**: `./bbl -v` が `bbl 0.1.0` を出力し exit code 0。`./bbl -h` に `--scale`, `--fullscreen`, `--shader`, `--recent` の説明が含まれる。
**検証方法**:
```sh
./bbl -v; echo "exit=$?"
./bbl -h | grep -- --scale
```
**落とし穴**: なし
**依存**: T0-1

---

### T0-3: CLI オプションのパース

- [x] 完了

**目的**: BluePrint の全オプションを受理し、値を `Options` 構造体に格納する（動作の実装は各フェーズで）。
**作るもの**: `src/app/cli.odin` に追加:
- `Options :: struct { scale: int, fullscreen: bool, shader: Shader_Kind, recent: bool, headless: bool, rom_path: string }`
- `--scale N`: 1〜8。**9 以上は 8 に丸める**（BluePrint 仕様）。0 以下・非数値はエラーメッセージ + exit 1。デフォルト 4
- `--fullscreen`: 指定時は scale を無視するフラグ
- `--shader nearest|smooth`: デフォルト nearest。他の値はエラー + exit 1
- `--recent`: フラグのみ（実装はフェーズ 9）
- `--headless`: **開発用の隠しオプション**。SDL 初期化なしで実行（テスト ROM ランナーや CI で使用）
- 位置引数 1 個を `rom_path` に。複数あればエラー
**参照**: BluePrint.md「コマンドラインオプション」
**完了条件 (DoD)**: 下記コマンドすべてが期待どおり。
**検証方法**:
```sh
./bbl --scale 12 --headless dummy.gb 2>&1   # scale が 8 に丸まる（ログ出力で確認）
./bbl --shader bogus 2>&1; echo "exit=$?"    # エラーメッセージ + exit=1
./bbl a.gb b.gb 2>&1; echo "exit=$?"         # exit=1
```
単体テスト: `tests/cli_test.odin` にパース関数を直接呼ぶテストを 5 ケース以上（丸め、デフォルト値、エラー）。
**落とし穴**: パース処理は `parse_args(args: []string) -> (Options, bool)` のような純関数にして単体テスト可能にする（os.args を直接読むと테스트できない）。
**依存**: T0-2

---

### T0-4: ビルドスクリプト

- [ ] 完了

**目的**: ローカルと CI が共有するビルドスクリプトを作る（M88M 方式）。
**作るもの**:
- `scripts/build_macos.sh`, `scripts/build_linux.sh`: `odin build src/app -collection:bbl=src -out:bbl -o:speed` を実行。
  `--debug` 引数で `-debug` ビルド、`--test` 引数で `odin test tests -collection:bbl=src` も実行
- `scripts/build_win.ps1`: 同等の PowerShell 版（`-out:bbl.exe`）
- 各スクリプトは冒頭で `odin` コマンドの存在を確認し、無ければ「mise install を実行せよ」と案内して exit 1
**参照**: `~/dev/_Emu/M88M/scripts/build_linux.sh`（構造の参考。CMake 部分は無視してよい）
**完了条件 (DoD)**: `./scripts/build_macos.sh --test` がビルドとテストを両方成功させる。
**検証方法**:
```sh
./scripts/build_macos.sh --test && ./bbl -v
```
**落とし穴**: build_linux.sh は FreeBSD でも使うので bash 拡張を避け POSIX sh で書く（shebang は `#!/bin/sh`）。
**依存**: T0-1

---

### T0-5: SDL2 ウィンドウとテストパターン

- [ ] 完了

**目的**: SDL2 で 160×144 の論理解像度の窓を開き、core のフレームバッファを表示する経路を確立する。
**作るもの**:
- `src/core/emulator.odin`: `Emulator :: struct { framebuffer: [160*144]u32, ... }` の骨格と、
  テストパターン（グラデーション + 四隅マーカー）を framebuffer に書く `emulator_render_test_pattern`
- `src/app/video.odin`: `import sdl "vendor:sdl2"`。ウィンドウ（160*scale × 144*scale）、
  `SDL_CreateTexture(STREAMING, ARGB8888, 160, 144)`、毎フレーム `SDL_UpdateTexture` → `SDL_RenderCopy`。
  `--shader nearest` は `SDL_HINT_RENDER_SCALE_QUALITY="0"`（smooth はフェーズ 8）
- `src/app/main.odin`: ROM 指定なし & TUI 未実装の間は、テストパターンを表示するイベントループ（Esc / ウィンドウクローズで終了）
**参照**: Odin vendor:sdl2 ドキュメント（references.md）。開発中は動的リンクでよい（architecture.md）
**完了条件 (DoD)**: `./bbl --scale 2` で 320×288 の窓にテストパターンが表示され、Esc で exit 0。
**検証方法**:
```sh
./bbl --scale 2   # 目視確認: グラデーションと四隅マーカー、Esc で終了
```
**落とし穴**: macOS では SDL の初期化をメインスレッドで行うこと。`SDL_UpdateTexture` の pitch は `160 * size_of(u32)`。
**依存**: T0-3, T0-4

---

### T0-6: ヘッドレスモード

- [ ] 完了

**目的**: `--headless` で SDL を一切初期化せずに実行できることを保証する（CI・テスト ROM ランナーの前提）。
**作るもの**: `src/app/main.odin` で `options.headless` なら video/audio/input の初期化をスキップし、
現時点では「headless: nothing to do」と出力して exit 0。
**参照**: architecture.md「core と app の分離」
**完了条件 (DoD)**: `DISPLAY= ./bbl --headless` が（X11/ディスプレイなしでも）exit 0。
**検証方法**:
```sh
DISPLAY= ./bbl --headless; echo "exit=$?"
```
**落とし穴**: SDL の import 自体は問題ないが、`SDL_Init` を呼ばないこと。tests/ パッケージは app を import しない（core のみ）ので、この経路とは独立。
**依存**: T0-3

---

### T0-7: LICENSE と README 雛形

- [ ] 完了

**目的**: MIT ライセンスの確定（BluePrint「ゆるいライセンス」）と最低限の README。
**作るもの**:
- `LICENSE`: MIT License 全文。Copyright 行は `Copyright (c) 2026 BubiBoyLite contributors`（**実名・実ユーザー名を書かない**）
- `README.md`: プロジェクト概要 3 行、ビルド方法（`mise install` → `./scripts/build_*.sh`）、`bbl -h` の使用法
**参照**: BluePrint.md「ライセンス」「注意事項」
**完了条件 (DoD)**: LICENSE が MIT 全文で存在し、README にビルド手順がある。
**検証方法**:
```sh
head -1 LICENSE   # => "MIT License"
grep "mise install" README.md
```
**落とし穴**: なし
**依存**: なし

---

### T0-8: 最小 CI

- [ ] 完了

**目的**: ubuntu と macos でビルド + テストを回す最小の GitHub Actions を作る。以後の全フェーズのリグレッションガード。
**作るもの**: `.github/workflows/ci.yml`:
- トリガー: `push`（main）, `pull_request`, `workflow_dispatch`
- `concurrency: { group: "ci-${{ github.ref }}", cancel-in-progress: true }`、`permissions: { contents: read }`
- matrix: `ubuntu-24.04`, `macos-latest`
- ステップ: checkout → Odin セットアップ（mise を CI に入れて `mise install` するか、`jdh/setup-odin` 系 action。**mise.toml のバージョンと一致させること**）→ SDL2 導入（apt: `libsdl2-dev` / brew: `sdl2`）→ `./scripts/build_linux.sh --test`（macos は build_macos.sh）
- `scripts/fetch_test_roms.sh` の雛形も作る（この時点では「まだ ROM なし」で正常終了する空実装でよい。フェーズ 1 で中身を足す）
**参照**: `~/dev/_Emu/M88M/.github/workflows/build-linux.yml`（トリガー・concurrency・権限の書き方）、testing.md
**完了条件 (DoD)**: GitHub に push して ci.yml の両 OS ジョブがグリーン。
**検証方法**: GitHub Actions の実行結果を確認（`gh run watch` または Web UI）。
**落とし穴**: CI 上の Odin ンストールは mise 経由が最も確実（ローカルと同一バージョンになる）。`mise use` ではなく `mise install` + `mise exec -- odin ...` かシムを PATH に追加。
**依存**: T0-4, T0-6

---

## 検証ログ

（タスク完了ごとに 1 行追記: `YYYY-MM-DD T0-N 完了: <検証結果の要約>`）

2026-07-11 T0-1 完了: odin build src/app -collection:bbl=src -out:bbl && ./bbl => "BubiBoyLite" 出力, odin test tests -collection:bbl=src => 1 test passed
2026-07-11 T0-2 完了: ./bbl -v => "bbl 0.1.0" exit=0, ./bbl -h に --scale/--fullscreen 記載を確認
2026-07-11 T0-3 完了: scale 12→8 丸め確認、--shader bogus/2重ROM指定で exit=1、odin test tests -collection:bbl=src 8 tests 全パス (cli_test.odin 7本追加)
