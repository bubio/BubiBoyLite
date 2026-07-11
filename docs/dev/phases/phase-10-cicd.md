# フェーズ 10: CI/CD 全プラットフォーム

## 前提

- 依存フェーズ: 0（最小 CI が存在）。機能フェーズと並行可能だが、8/9 完了後が手戻りが少ない。
- **テンプレートは M88M**（`~/dev/_Emu/M88M/.github/workflows/` と `~/dev/_Emu/M88M/scripts/`）。設計方針は
  `~/dev/_Emu/M88M/docs/CI.md` にも文書化されている。raylib/CMake 部分を Odin/SDL2 に読み替える。
- 対応マトリクス（BluePrint）: macOS 13.5+ (x86_64 / arm64 **別バイナリ**)、Windows 10+ (x86 / x86_64 / arm64)、
  Ubuntu 22.04+ (amd64 / arm64)、Raspberry Pi OS (armhf)、FreeBSD 14+ (x86_64)。
- **配布バイナリは SDL2 静的リンク**（BluePrint）。開発ビルドは動的のまま（architecture.md の二段構え）。

## ゴール

全プラットフォームのビルド workflow がグリーンになり、各バイナリがスモークテストを通過する。

## フェーズ完了の検証コマンド

```sh
gh workflow list && gh run list --limit 10   # 全 build-*.yml がグリーン
# 各 workflow の成果物をダウンロードして bbl -v が動く
```

## workflow 共通規約（M88M 踏襲、全タスクに適用）

- トリガー: `push`(main) / `pull_request`（いずれも `paths` フィルタで関係ファイルのみ）+ `release: [published]` + `workflow_dispatch`
- `concurrency: ${{ github.workflow }}-${{ github.ref }}`、release 以外 `cancel-in-progress: true`
- `permissions: { contents: read }`（リリース発行はフェーズ 11 の再利用 workflow だけが write）
- matrix は `fail-fast: false`
- **ビルドは必ず `scripts/build_*.sh|ps1` を呼ぶ**（インライン化禁止。例外は RPi クロスコンパイルのみ許容 — M88M と同じ）
- 成果物名: `bbl-<platform>-<arch>`（小文字）で `actions/upload-artifact` へ

---

### T10-1: SDL2 静的リンクの確立（リリースビルドモード）

- [ ] 完了

**目的**: 配布用の静的リンクビルドをローカルスクリプトで再現可能にする。全 build workflow の前提。
**作るもの**:
- `scripts/build_*.sh|ps1` に `--release` モード追加: SDL2 静的ライブラリをリンクし、単一実行ファイルを生成
  - macOS/Linux: SDL2 をソースから静的ビルドするヘルパー `scripts/build_sdl2_static.sh`（バージョンをピン止め、`build/sdl2/` にキャッシュ）。リンクは `odin build ... -extra-linker-flags:"<libSDL2.a のパスと依存 framework/lib>"`
  - vendor:sdl2 の import は共通のまま、リンク先だけ差し替える（Odin の `ODIN_VENDOR_LIB` 相当の仕組みか、システムライブラリ探索の上書きで実現。方法は実装時に調査し、**結果を architecture.md に追記**する）
  - macOS のリンク依存: CoreVideo/CoreAudio/AudioToolbox/Metal/ForceFeedback/IOKit/Carbon 等の framework
  - Windows: SDL2 の静的 .lib（VC ビルド）+ `winmm imm32 version setupapi` 等
- 検証: `otool -L` (macOS) / `ldd` (Linux) で SDL2 の動的依存が消えていること
**参照**: `~/dev/_Emu/M88M/CMakeLists.txt:107-203`（プリビルド静的 or ソース静的の二択方針）、BluePrint「静的リンクして実行ファイルのみで実行可能にする」
**完了条件 (DoD)**: ローカル（macOS）で `./scripts/build_macos.sh --release && otool -L ./bbl | grep -i sdl` がヒット 0、`./bbl -v` 動作。
**検証方法**: 上記コマンド。
**落とし穴**: これはフェーズ 10 で最も時間がかかるタスク。プラットフォームごとに 1 つずつ確立する（まず macOS/Linux、Windows は T10-4 で）。静的 SDL2 でもオーディオ/ビデオドライバのシステムライブラリ（ALSA, X11/Wayland 等）は動的のままで正しい（M88M と同じ二層構成）。
**依存**: なし

---

### T10-2: build-linux.yml (amd64 / arm64)

- [ ] 完了

**目的**: Ubuntu 22.04+ 向けビルド。
**作るもの**: `.github/workflows/build-linux.yml`:
- matrix: `ubuntu-22.04`（amd64）/ `ubuntu-22.04-arm`（arm64）
- 手順: checkout → mise で Odin → 依存 apt（SDL2 のビルド依存: `libasound2-dev libpulse-dev libx11-dev libxext-dev libwayland-dev` 等）→ `./scripts/build_linux.sh --release --test` → スモーク（`./bbl -v`）→ upload-artifact `bbl-linux-<arch>`
- 既存 ci.yml のテストジョブはこの workflow に統合するか併存かを判断し、重複実行を避ける
**参照**: `~/dev/_Emu/M88M/.github/workflows/build-linux.yml`、共通規約（上記）
**完了条件 (DoD)**: 両 arch のジョブがグリーン、成果物の bbl が `-v` スモーク通過（ジョブ内で実行）。
**検証方法**: `gh run watch`。
**落とし穴**: ubuntu-22.04 でビルドすることで glibc 依存が 22.04+ で満たされる（新しいランナーでビルドすると古い OS で動かない）。
**依存**: T10-1

---

### T10-3: build-macos.yml (x86_64 / arm64 別バイナリ)

- [ ] 完了

**目的**: macOS 13.5+ 向け。BluePrint 指定により**ユニバーサルではなく別バイナリ**。
**作るもの**: `.github/workflows/build-macos.yml`:
- ランナー: `macos-latest`（arm64）でネイティブビルド + x86_64 クロス（`odin build -target:darwin_amd64` + x86_64 の静的 SDL2）。クロスが困難なら `macos-13`（intel）ランナー併用に切替可
- `MACOSX_DEPLOYMENT_TARGET=13.5` を SDL2 ビルドと odin リンクの両方に適用
- 成果物: `bbl-macos-x86_64` / `bbl-macos-arm64`
**参照**: `~/dev/_Emu/M88M/.github/workflows/build-macos.yml`（ただし M88M はユニバーサル。**本プロジェクトは別バイナリ**な点が意図的な差分）
**完了条件 (DoD)**: 両バイナリのジョブがグリーン。`file bbl` で各 arch 単体（universal でない）を確認するステップを含む。
**検証方法**: `gh run watch` + 成果物ダウンロードして手元 Mac で `-v`。
**落とし穴**: Xcode 26 世代の SDK でビルド（BluePrint 想定）。deployment target 未指定だとランナー OS 依存になり 13.5 で動かない。
**依存**: T10-1

---

### T10-4: build-windows.yml (x86 / x86_64 / arm64)

- [ ] 完了

**目的**: Windows 10+ 向け 3 アーキテクチャ。
**作るもの**:
- `scripts/build_win.ps1` に `--release`（静的 SDL2）と `-Architecture x86|x64|arm64` を実装（Odin の `-target:windows_i386|windows_amd64|windows_arm64`）
- `.github/workflows/build-windows.yml`: `windows-latest`、matrix で 3 arch。スモークは x64 のみ実行（ランナー上で動くのは x64/arm64エミュ）
- 成果物: `bbl-windows-<arch>`（bbl.exe 入り）
**参照**: `~/dev/_Emu/M88M/.github/workflows/build-windows.yml` + `scripts/build_win.ps1`
**完了条件 (DoD)**: 3 arch ジョブグリーン、x64 スモーク通過。
**検証方法**: `gh run watch`。
**落とし穴**: x86 (32bit) の SDL2 静的ライブラリの用意が最難関。Odin の i386 ターゲットサポート状況も実装時に確認し、**不可能と判明したら 🔴 にして報告**（BluePrint の対応表を狭める判断はユーザーに委ねる）。
**依存**: T10-1

---

### T10-5: build-rpi.yml (armhf) と build-freebsd.yml (x86_64)

- [ ] 完了

**目的**: Raspberry Pi OS (armhf) と FreeBSD 14+ (x86_64) 向けビルド。
**作るもの**:
- `.github/workflows/build-rpi.yml`: `ubuntu-22.04` 上で armhf クロスコンパイル（`gcc-arm-linux-gnueabihf` + armhf の SDL2 静的ビルド + `odin build -target:linux_arm32`）。M88M と同様、クロス都合のインライン記述を許容
- `.github/workflows/build-freebsd.yml`: `vmactions/freebsd-vm@v1`（release 14 系）内で `pkg install` → `sh scripts/build_freebsd.sh --release`。`scripts/build_freebsd.sh` は build_linux.sh の POSIX sh 共通化で流用できるなら薄いラッパーでよい
- 成果物: `bbl-rpi-armhf` / `bbl-freebsd-x86_64`
**参照**: `~/dev/_Emu/M88M/.github/workflows/build-rpi.yml` / `build-freebsd.yml` / `scripts/build_freebsd*.sh`
**完了条件 (DoD)**: 両ジョブグリーン。FreeBSD はジョブ内で `-v` スモーク、armhf はビルド成功まで（実機スモークは手動・任意）。
**検証方法**: `gh run watch`。
**落とし穴**: Odin の FreeBSD / arm32 ターゲット対応は実装時に要確認（mise の Odin nightly が該当ターゲットを持つか）。不可なら 🔴 で報告。vmactions は遅いので `timeout-minutes` を長めに。
**依存**: T10-1

---

### T10-6: テスト ROM の CI 実行と paths フィルタ整理

- [ ] 完了

**目的**: フェーズ 10 のマイルストーン。CI の完成度を上げる。
**作るもの**:
- linux/macos の workflow に `fetch_test_roms.sh`（actions/cache 付き）→ `odin test tests -collection:bbl=src` を組み込み（testing.md）
- 全 workflow に `paths` フィルタ（例: build-windows.yml は `src/**`, `scripts/build_win.ps1`, 自 workflow のみで発火）
- README に CI バッジ追加
- 各 OS 成果物の `-v` スモークが全 workflow に入っていることを最終確認
**参照**: `~/dev/_Emu/M88M/docs/CI.md`（paths フィルタ方針）、testing.md
**完了条件 (DoD)**: 全 build workflow + テストがグリーン。docs だけの変更でビルド workflow が走らないことを確認。
**検証方法**:
```sh
gh run list --limit 10   # 全グリーン
# docs のみ変更の push でビルドがスキップされる
```
**落とし穴**: paths フィルタに自分自身（workflow ファイル）を入れ忘れると workflow 修正で CI が走らない。
**依存**: T10-2〜T10-5

---

## 検証ログ

（タスク完了ごとに 1 行追記）
