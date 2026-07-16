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

- [x] 完了

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

- [x] 完了

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

- [x] 完了

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
- `scripts/build_win.ps1` に `--release`（2026-07-16 方針転換: SDL2 公式配布物の動的ライブラリを使用。
  検証ログ参照）と `-Architecture x86|x64|arm64` を実装（Odin の `-target:windows_i386|windows_amd64|windows_arm64`）
- `.github/workflows/build-windows.yml`: `windows-latest`、matrix で 3 arch。スモークは x64 のみ実行（ランナー上で動くのは x64/arm64エミュ）
- 成果物: `bbl-windows-<arch>`（bbl.exe + SDL2.dll 入り）
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

2026-07-16 T10-1 完了: `./scripts/build_macos.sh --release && otool -L ./bbl | grep -i sdl` がヒット 0、`./bbl -v` で `bbl 0.1.0` 出力（macOS arm64 実機で検証）。
SDL2 2.30.9 をソースから `scripts/build_sdl2_static.sh` で静的ビルドし `build/sdl2/macos-arm64/` にキャッシュ。
リンクは `-Wl,-force_load,<libSDL2.a>` + `-Wl,-dead_strip_dylibs` + framework 群（architecture.md に方式を追記済み）。
`scripts/build_linux.sh --release` / `scripts/build_sdl2_static.sh linux <arch>` も実装したが、
**この開発環境（macOS）には Linux 実行環境がなく、Linux 側の実リンク・実行検証は未実施**
（`sh -n` によるシェル構文チェックのみ実施、OK）。macOS x86_64 クロスビルドも本タスクでは未実施（T10-3 の範囲）。

2026-07-16 Odin（mise 固定 `dev-2026-07`）のクロスコンパイル制約を実機調査（全タスクに影響するため先に記録）:
- `odin build <pkg> -target:linux_arm32 -show-system-calls`（macOS arm64 ホストから実行）→
  `Linking for cross compilation for this platform is not yet supported (linux arm32)` で即エラー。
  同様に `-target:freebsd_amd64`・`-target:linux_amd64` も macOS ホストからは同一メッセージで即エラー。
- 一方 `-target:darwin_amd64`（同一 OS・異なる arch、macOS arm64 ホストから）は実際に `clang -target x86_64-apple-macosx ...` のリンクコマンドまで到達した（`-show-system-calls` で確認）。
  → Odin の「クロスコンパイル未対応」制限は **OS をまたぐクロスで発動する**ことを確認（Apple SDK が multi-arch を単一 SDK にバンドルしているための例外的成功で、ELF ターゲットには同じ仕組みがない）。
- `gh api repos/odin-lang/Odin/releases/tags/<tag>` を dev-2026-07/dev-2026-07a/dev-2026-06/dev-2026-05 で確認: アセットは
  `odin-linux-amd64` / `odin-linux-arm64` / `odin-macos-amd64` / `odin-macos-arm64` / `odin-windows-amd64` の 5 種のみ。
  **FreeBSD 向けバイナリは一度も配布されていない**（mise の `github:odin-lang/Odin` バックエンドでは FreeBSD に Odin 自体をインストールできない）。
- `odin build --help` に sysroot 相当のクロスターゲット設定オプションは存在しない。
- これらから T10-4（Windows arm64）・T10-5（RPi armhf・FreeBSD）の実現可能性を判断した（各タスクの記載を参照）。

2026-07-16 T10-2 未完了（CI 未検証、GitHub remote 不在のため）: `.github/workflows/build-linux.yml` を作成。
matrix: amd64（ubuntu-22.04・ネイティブ） / arm64（ubuntu-22.04-arm・ネイティブ、クロスコンパイルではない）。
`scripts/build_linux.sh --release --test` を呼び、`fetch_test_roms.sh`（actions/cache 付き）→ビルド→`odin test`→
`ldd | grep -i libsdl2` で静的リンク確認→`-v` スモーク→`actions/upload-artifact` の順。
構文検証: `actionlint .github/workflows/build-linux.yml` exit=0、`python3 -c "import yaml; yaml.safe_load(...)"` OK
（両方実施、区別して記録: actionlint はワークフロースキーマ検証、yaml.safe_load は YAML 構文のみ）。
**実際の CI 実行（グリーン確認）は GitHub remote が無いため未実施。**
既存 `.github/workflows/ci.yml`（フェーズ0の最小 CI）はこの workflow と build-macos.yml に統合する判断をし削除した
（重複したテスト実行を避けるため。PLAN.md 依存グラフの「0 の最小 CI → 10 CI/CD 拡張」が意図する置き換えと解釈）。

2026-07-16 T10-3 未完了（CI 未検証）: `.github/workflows/build-macos.yml` を作成。
BluePrint どおり別バイナリ（ユニバーサル禁止）。x86_64 クロスビルドは避け、`macos-15`（arm64ネイティブ）/
`macos-15-intel`（x86_64ネイティブ）の 2 ランナー構成にした
（`macos-13` Intel ランナーは 2026-07 時点で廃止済み・`actions/runner-images` README で確認、
`macos-14` 系も deprecated のため `macos-15` 系を採用）。
`MACOSX_DEPLOYMENT_TARGET=13.5` を env に設定。`file ./bbl` で universal でないことを確認するステップを含む。
構文検証: actionlint exit=0、yaml.safe_load OK。**実際の CI 実行は未実施。**

2026-07-16 T10-3 追記（ユーザー指示によりランナー変更）: CLAUDE.md が想定する Xcode 26 世代に
合わせ、ランナーを `macos-15`/`macos-15-intel` から `macos-26`（arm64）/`macos-26-intel`（x64）へ
差し替えた。`macos-26` は2026-02-26にGA(WebSearchで`github.blog`のchangelog
「macos-26 is now generally available for GitHub-hosted runners」を確認)、利用可能ラベルは
`macos-26`(arm64標準)・`macos-26-intel`(x64標準)・`macos-26-large`(x64大型)・`macos-26-xlarge`
(arm64大型)の4種(`actions/runner-images`の`macos-26-Readme.md`で確認)。
構文再検証: actionlint exit=0、yaml.safe_load OK。**実際の CI 実行は依然未実施。**

2026-07-16 T10-1/T10-2 実 CI 実行で判明した全プラットフォーム共通のリンカ問題:
macOS の修正過程で `odin build ... -print-linker-flags` を実機確認した結果、
odin は vendor:sdl2 の foreign import 由来の `-lSDL2` を、`-extra-linker-flags`
で渡す内容(自前ビルドの静的アーカイブへの `-L` 等)より**前**に置くことが判明した
（実際の呼び出し例: `... -L/usr/local/lib -L/opt/homebrew/lib -L/ -lSDL2 -lm
-target ... <ここに -extra-linker-flags の内容> ...`）。リンカは `-l` を左から
右へ処理し、その時点までに見えている `-L` しか使わないため、後方に `-L` を
足すだけでは `-lSDL2` を自前の静的アーカイブへ向けられない。macOS ローカルで
これまで成功していたのは、odin が既定で足す `/opt/homebrew/lib` に Homebrew 版
SDL2 の dylib がたまたま存在し、そちらへ解決されていた（`force_load`+
`dead_strip_dylibs` で最終的に静的化されるため気付かなかった）だけだった。
GitHub Actions ランナーには Homebrew 版 SDL2 が無いため
`ld: library 'SDL2' not found` で即失敗し（build-macos.yml 初回 CI 実行で再現）、
同根の問題が build-linux.yml でも `ld: cannot find -lSDL2` として再現した
（実際に workflow_dispatch でどちらも実行し確認済み）。
修正方針はプラットフォームで機構が異なるため統一しない:
- **macOS**: `build-macos.yml` に `brew install sdl2` ステップを追加し、odin の
  既定検索パスに `-lSDL2` が解決できる先を用意した。最終バイナリは
  `force_load`+`dead_strip_dylibs` により常に自前の静的アーカイブへ差し替わる
  ため Homebrew 側のバージョンは成果物に影響しない
  （`otool -L`/`file` 検証ステップ込みで build-macos.yml が実際に green になった
  ことを確認済み: run 29468924053、両 arch success）。
- **Linux/FreeBSD**（`build_linux.sh`。FreeBSD は薄いラッパー経由で同じコードを使う）:
  `apt install libsdl2-dev`のような動的ライブラリ導入は採らない。GNU ld には
  ld64 の `dead_strip_dylibs` に相当する後始末が無いため、最初の(odin 自動挿入の)
  `-lSDL2` が `.so` へ動的解決されると最終バイナリに `DT_NEEDED libSDL2.so` が
  残ってしまい、静的リンク要件も「SDL2 は静的リンク」の検証ステップ
  (`ldd | grep sdl`)も満たせなくなるため。代わりに `ld --verbose` の
  `SEARCH_DIR(...)` 出力から ld が既定で見るディレクトリを取得し、自前ビルドの
  `libSDL2.a` をそこへ直接コピーする（`.a` としての解決なので実行ファイルに
  動的依存が残らず、ピン止めしたバージョンがそのまま使われる）。FreeBSD の既定
  リンカ(lld)は同じ `SEARCH_DIR` 出力形式を持たない可能性があるため、
  検出できない場合は `/usr/lib` へフォールバックする実装にした。
  **Linux 側はこの修正を push 直後で CI 未検証**（次のコミットで確認する）。

2026-07-16 T10-3 初回実 CI 実行で失敗を検出・修正: ユーザーが GitHub remote(`bubio/BubiBoyLite`、
Public)を作成しpush、build-macos.ymlを`workflow_dispatch`で手動実行したところ両arch
(`macos-26`/`macos-26-intel`)とも`Build (release, static SDL2) and test`ステップで失敗。
ログ(`gh run view --log`)を取得したところ原因は`ld: library 'SDL2' not found`。
根本原因: `scripts/build_macos.sh`はvendor:sdl2のforeign importが暗黙に要求する
`-lSDL2`を解決する`-L`パスを渡していなかった。ローカル(このセッションの開発機)では
odinが暗黙に追加する`-L/opt/homebrew/lib`にHomebrew版SDL2(`sdl2-compat`)のdylibが
たまたま存在したため`-lSDL2`が解決され、`-force_load`+`-dead_strip_dylibs`で結果的に
静的化されて「たまたま動いていた」に過ぎなかった(T10-1完了時点のローカル検証は
この点でクリーンルームでなかったことが判明)。GitHub Actionsのランナーには
Homebrew版SDL2が入っておらず`-lSDL2`が解決不能で即失敗していた。
修正: `SDL2_LIB_DIR="$(dirname "$SDL2_LIB")"; EXTRA_LINKER_FLAGS="-L$SDL2_LIB_DIR ..."`
を追加し、自前でビルドした静的アーカイブのディレクトリを明示的にリンカ検索パスへ
入れることで、Homebrewの有無に関わらず`-lSDL2`が自前のピン止めビルドへ解決される
ようにした。ローカルで再ビルドし回帰なしを確認(`otool -L`ヒット0、`./bbl -v`動作)。
CI側の再検証はこのコミットのpush後にユーザー側で実行予定。

2026-07-16 T10-4 一部ブロック・未完了: `scripts/build_win.ps1` に `--release`・`-Architecture x86|x64|arm64` を実装、
`scripts/build_sdl2_static.ps1`（SDL2 を `-DSDL_FORCE_STATIC_VCRT=ON` で静的ビルド）を新規作成、
`.github/workflows/build-windows.yml` を作成（matrix: x86/x64 のみ）。
**arm64 は 🔴 ブロック**: 上記の実機調査で `odin build <pkg> -target:"?"` の対応ターゲット一覧に
`windows_arm64` が存在しないことを確認済み（windows は `windows_i386`/`windows_amd64` の 2 つのみ）。
これは「クロス未対応」以前に**ターゲット自体が実装されていない**ため、ワークフロー側の工夫では回避不可能。
`build_win.ps1` は arm64 選択時に上記理由を表示して即 `exit 1` する（将来 Odin が対応した際に外せる形でコメント）。
BluePrint の対応表（Windows arm64）を狭めるか、Odin の対応を待つかはユーザー判断に委ねる。
x86/x64 レグ: PowerShell 構文チェックのみ実施（`brew install powershell` で `pwsh` を用意し、
`[System.Management.Automation.Language.Parser]::ParseFile` でパース OK を確認）。
x86 が x64 ホストからの同一 OS 内クロスとして成立するかは Windows 環境が無く未検証。
静的 SDL2 の実リンクも MSVC 環境が無く未検証。actionlint / yaml.safe_load はどちらも OK。
**実際の CI 実行は未実施。**

2026-07-16 T10-4 方針転換: Windows は静的リンクを諦め、SDL2 公式配布物(devel-VC パッケージ、
`SDL2-devel-2.32.10-VC.zip`)の動的ライブラリをそのまま使うことにした（ユーザー提案。
公式リリースページ https://github.com/libsdl-org/SDL/releases/tag/release-2.32.10 を確認したところ
Windows 向けは `SDL2.lib`(動的インポートライブラリ)+`SDL2.dll` のみで、静的アーカイブ
(`SDL2-static.lib` 相当)は含まれていないと判明したため）。
`scripts/build_sdl2_static.ps1` → `scripts/fetch_sdl2_windows.ps1` にリネームし、CMake ソースビルドから
公式 ZIP のダウンロード+展開に置き換えた。`build_win.ps1` はビルド後に `SDL2.dll` を `bbl.exe` と
同じフォルダへコピーするようにした。`docs/dev/BluePrint.md`の「静的リンク」節にWindows例外として
追記済み（ユーザー承認）。`.github/workflows/build-windows.yml` の成果物アップロードに `SDL2.dll` を追加。
`fetch_sdl2_windows.ps1` は pwsh(Homebrew経由でインストール可能、cross-platform)を使い
**実際にこの macOS 開発機で実行し検証済み**: x86/x64 双方で ZIP のダウンロード→展開→
`SDL2.dll`/`SDL2.lib`/`SDL2main.lib` のコピーが成功、2回目実行でキャッシュスキップも確認。
最終的な MSVC リンク自体は「このホストからの windows_amd64 クロスリンクは未対応」という
Odin 自身のメッセージが出て(想定通り、リンクなしでのビルド構造検証のみ)、実リンクの成否は
引き続き実 CI(Windows ランナー)での確認が必要。

2026-07-16 T10-5 未完了:
- **RPi armhf（🔴 ブロック、`build-rpi.yml` は作成せず）**: 上記の実機調査で macOS→`linux_arm32` のクロスリンクが
  `not yet supported` で即エラーになることを確認したが、これは OS 跨ぎ（macOS→Linux）を含むテストであり、
  実際の CI シナリオ（Linux x86_64 ホスト→`linux_arm32`、同一 OS 内クロス）を直接検証できる Linux 環境が
  このセッションにはない。ただし `odin build --help` に sysroot 相当のクロスターゲット設定オプションが
  存在しないこと、darwin の成功例が Apple SDK 固有の multi-arch バンドルに起因すること
  （ELF クロスには同じ仕組みがない）から、同じ制限に当たる可能性が高いと判断した。
  **確証はなく、Linux 環境での実地検証が別途必要。** ビルドを試みても初回 CI で失敗する可能性が高いと
  判断し、`build-rpi.yml` は意図的に作成を見送った。
- **FreeBSD amd64（訂正: ブロックではなく、pkg 経由で実現可能と判明）**: 当初 `gh api` で
  odin-lang/Odin の GitHub Release に FreeBSD バイナリが無いことのみを根拠に「インストール不可能」と
  誤って結論していたが、これは **mise（`github:odin-lang/Odin` バックエンド）に限った話**であり、
  FreeBSD 自体のパッケージ経路を未確認のまま拡大解釈していた誤りだった。改めて freshports.org で
  確認したところ、**FreeBSD の pkg に `lang/odin`（`pkg install odin-lang`）が存在し、
  ports バージョン `2026.07` が `dev-2026-07` タグ由来**（mise.toml の固定バージョンとほぼ一致）と分かった。
  そのため `.github/workflows/build-freebsd.yml` を作成した（mise を使わず `pkg install odin-lang` で
  Odin を導入する点だけ他プラットフォームと異なる。ワークフロー内にコメントで明記）。
  **pkg のバージョンは mise.toml の固定バージョンと完全一致する保証がない**
  （ports 追従のタイミング次第でずれ得る）ため、他プラットフォームとの版ずれが無いか
  継続的な確認が必要（ユーザー判断事項として記録）。
  SDL2 のビルド依存パッケージ名は freshports.org の `devel/sdl20` 依存欄
  （`libX11`/`libXcursor`/`libXext`/`libXi`/`libXfixes`/`libXrandr`/`libXScrnSaver`/
  `wayland`/`wayland-protocols`/`libxkbcommon`/`evdev-proto`）に合わせた。
  `scripts/build_freebsd.sh`（`build_linux.sh` への薄いラッパー、`uname -s` で FreeBSD を判別）も実装済み。
  **FreeBSD 環境がこのセッションにないため、pkg のパッケージ名の正確性・実ビルド・実リンクは未検証**
  （actionlint / yaml.safe_load のみ実施、いずれも OK）。
- BluePrint の対応表を狭めるか（RPi armhf のみ）、Odin の arm32 クロスリンク対応を待つか、
  pkg 版と mise 版の Odin バージョン差異をどう扱うか（FreeBSD）はユーザー判断に委ねる。

2026-07-16 T10-6 未完了（依存タスク T10-5 の RPi armhf レグがブロックされているため DoD 未達）: README に
CI バッジを追加（`.github/workflows/build-linux.yml` / `build-macos.yml` / `build-windows.yml` の 3 つ。
GitHub remote 未設定のため `OWNER/BubiBoyLite` はプレースホルダ、実 URL への差し替えは remote 設定後に必要）。
`fetch_test_roms.sh`（actions/cache 付き）→ `odin test tests -collection:bbl=src` の組み込みは
build-linux.yml・build-macos.yml の作成時（T10-2/T10-3）に併せて実施済み（x64 のみ build-windows.yml にも実施済み）。
全 workflow（linux/macos/windows/freebsd）に `paths` フィルタ（各自の `src/**`・`tests/**`・該当スクリプト・
自 workflow ファイル自身）を設定済み。`docs/**`・`*.md` はどの `paths` にも含まれないため、
**docs のみの変更ではどの build workflow もトリガーされない設計になっている**（目視確認、実際の push による
トリガー未検証テストは GitHub remote が無いため未実施）。
RPi armhf の workflow のみ存在しないため「全 build workflow がグリーン」の DoD は原理的に達成不能
（T10-5 の RPi armhf ブロックが解消されるまで）。

2026-07-16 advisor レビューを受けて 3 点訂正・追記:
1. **T10-5 の記述矛盾を修正**: 旧版のログが「`build-rpi.yml`/`build-freebsd.yml` の実体は作成した」
   と「ワークフローファイル自体は…作成を見送った」を同じ段落内で両方書いており矛盾していた
   （実際には両ファイルとも当初は作成していなかった）。上記 T10-5 のログ本文を書き直して解消。
2. **FreeBSD の「ブロック」判定が誤りだったと判明**: mise 経由のインストール不可能性のみを根拠に
   「FreeBSD は Odin 自体が使えない」と拡大解釈していたが、FreeBSD の pkg（`lang/odin`）で
   `dev-2026-07` 相当が配布されていることを freshports.org で確認し、訂正した。
   `.github/workflows/build-freebsd.yml` を新規作成し、README の CI バッジにも追加した
   （build-freebsd.yml は actionlint / yaml.safe_load とも OK。FreeBSD 環境が無いため実ビルドは未検証）。
3. **T10-1 の DoD を再検証し、`-minimum-os-version` の欠落を発見・修正**: `otool -l ./bbl` で
   `LC_BUILD_VERSION` を確認したところ、`minos` がビルドホストの OS バージョン（26.0）になっており、
   BluePrint の「macOS 13.5+」要件を満たしていなかった（odin のデフォルトは `-minimum-os-version:11.0.0` だが、
   `-extra-linker-flags` 経由の静的リンクではこれが効かず、ホストの SDK バージョンがそのまま埋め込まれていた）。
   `scripts/build_macos.sh` の `--release` 分岐に `-minimum-os-version:$MACOSX_DEPLOYMENT_TARGET`
   （=13.5）を追加。再ビルドして `otool -l ./bbl | grep -A5 LC_BUILD_VERSION` で `minos 13.5` を確認、
   `otool -L ./bbl | grep -i sdl` がヒット 0 のままであること、`./bbl -v` が動作することも再確認した
   （T10-1 の DoD は元々「otool -L がヒット0 かつ -v 動作」のみを要求しており、この意味では元から
   満たしていたが、BluePrint の実質要件により合致させるため追加修正した）。
   リンク時に `ld: warning: building for macOS-13.5, but linking with dylib ... built for newer version 26.0`
   という警告が出るが、`-Wl,-dead_strip_dylibs` で最終バイナリからは当該 dylib 参照ごと除去されるため
   実害はない（`otool -L` で確認済み）。

2026-07-16 T10-2/T10-3 実 CI グリーンを確認、両タスクを完了扱いにする:
ユーザーが GitHub remote(`bubio/BubiBoyLite`, Public)を作成し push、build-macos.yml を
`workflow_dispatch` で手動実行したことをきっかけに、macOS・Linux 双方で
「odin が vendor:sdl2 由来の `-lSDL2` を `-extra-linker-flags` より前に置く」という
共通の根本原因を発見・修正した(詳細は直前のログ参照)。両プラットフォームとも
修正後に実際に workflow_dispatch/push で再実行し、以下の run が green になったことを
`gh run view`で確認済み:
- macOS: run 29468924053(`build (x86_64, macos-26-intel)` / `build (arm64, macos-26)` とも success、
  `otool -L`/`file` の静的リンク検証ステップ込み)
- Linux: run 29469488374(`build (amd64, ubuntu-22.04)` / `build (arm64, ubuntu-22.04-arm)` とも success、
  `ldd` の静的リンク検証ステップ込み)
Linux 側は初回修正(`-L` 追加)では直らず(`ld: cannot find -lSDL2`のまま)、2回目の修正
(`ld --verbose` の `SEARCH_DIR` から検出したディレクトリへ静的アーカイブを直接コピー)でも
`set -e` 環境下での `while read` の EOF 非ゼロ終了という別のシェルスクリプトのバグを踏んで
無言で落ちる問題が発生し、3回目の修正(`for d in $(...)` へ書き換え)でようやく green になった
(コミット履歴: `13f034e`→`0fd5808`、いずれも実際の CI 失敗ログを見てから対症療法ではなく
原因を特定して直したもの)。
T10-2・T10-3 とも DoD(両 arch グリーン、静的リンク検証・`-v` スモークがジョブ内で通過)を
満たしたため `[x]` 完了にする。T10-4(Windows)・T10-5(RPi/FreeBSD)は同根の問題を抱えている
可能性が高いが未検証のまま残っている(次のタスクとして着手予定)。

2026-07-16 T10-4/T10-5 実 CI 4本(macOS/Linux/FreeBSD/Windows)を同時実行して結果が分岐:
- **macOS・Linux**: 引き続き green(HIDAPI_LIBUSB フラグ追加後も回帰無し)。
- **FreeBSD**: `-DSDL_HIDAPI_LIBUSB=OFF` を渡しても効果が無いことが実機ログで判明。
  SDL2 の CMakeLists.txt(505-511行目)に `if(FREEBSD OR NETBSD OR OPENBSD OR BSDI)
  set(HIDAPI_ONLY_LIBUSB TRUE)` → `set(SDL_HIDAPI_LIBUSB ON CACHE BOOL "" FORCE)` という
  BSD 専用のハードコードされた強制上書きがあり、ユーザー指定のオプションを無視して
  常に libusb 必須にする設計だった(取得したソース `build/sdl2/src/SDL2-2.30.9/CMakeLists.txt`
  で直接確認)。実際のリンクコマンドには `sdl2-config --static-libs` 由来の `-lusb -lusbhid`
  も含まれていたが、それでも `libusb_get_string_descriptor` 等が undefined symbol になった
  ことから、FreeBSD ベースシステムの `/usr/lib/libusb.so` だけでは不十分と判断し、
  `devel/libusb`(`pkg install libusb`)を明示的に追加したが、**このパッケージ名は
  FreeBSD 14.2 の pkg リポジトリに存在せず**(`pkg: No packages available to install
  matching 'libusb'`)、CI がより早い段階(pkg install そのもの)で即失敗するように
  後退させてしまった。この変更は取り消し済み(パッケージ不足ではなく、cmake configure
  ログに `Found libusb-1.0, version 1.0.16` と出ている以上ベースシステムに libusb 自体は
  存在しており、問題は純粋な**最終リンク時のシンボル解決**にある。実 FreeBSD 環境が無い
  状態でパッケージ名を当てずっぽうに変えて CI へ blind に push する手法はここで打ち切る:
  macOS/Linux はローカルで `-print-linker-flags` 等を使い根拠を持って直せたが、
  FreeBSD/Windows-x64 はローカル検証手段が無く、CI 1回=約2分のブラックボックス試行に
  なってしまっていた)。**未解決のまま次回セッションへ持ち越し**(実 FreeBSD 環境での
  対話的デバッグ、または `sdl2-config` の依存解決自体を見直す必要がある)。
- **Windows**: SDL2 とは無関係の、より基礎的な問題を発見。`jdx/mise-action` は
  `mise install` 自体は成功する(ログに `odin dev-2026-07 ✓ installed` と出る)が、
  `mise-shim.exe not found ... falling back to "file" shim mode` という警告が出ており、
  後続の `run:` ステップで `odin` コマンドが見つからない(`Error: odin コマンドが見つかりません`)。
  これは今回の SDL2 動的リンク切替とは無関係な、Windows ランナー上での mise の
  シム/PATH 設定に関する別の問題（未調査、次回セッションへ持ち越し）。
