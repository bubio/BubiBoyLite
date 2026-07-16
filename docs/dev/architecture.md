# BubiBoyLite アーキテクチャ

実装前に必読。ここに書かれたレイアウト・境界・型の決定は全フェーズで固定とする。
変更が必要になったら PLAN.md の検証ログに理由を残した上で本ファイルを更新すること。

## 大原則: core と app の分離

```
src/
├── core/    # package core — エミュレーション本体。SDL2 に一切依存しない
└── app/     # package main — SDL2・CLI・TUI・設定ファイル。core を利用する側
```

- **`src/core` から SDL2 を import することを禁止する。**
  これにより CI ではディスプレイ・オーディオデバイスなしでテスト ROM を実行できる（testing.md 参照）。
- core が外界に公開するインターフェイス:
  - 映像: `framebuffer: [160*144]u32`（ARGB、0xAARRGGBB）。CGB の RGB555→ARGB 変換は core 内で行う。
  - 音声: 48000Hz ステレオの `i16` サンプルを core 内リングバッファに蓄積し、
    `apu_drain_samples(emu, dst) -> int` で app が取り出す。
  - 入力: `joypad_set_button(emu, button, pressed)` を app が呼ぶ。
  - 実行: `emulator_step(emu)`（1 命令）と `emulator_run_frame(emu)`（70224 サイクル = 1 フレーム）。

## ディレクトリレイアウト（全体）

```
BubiBoyLite/
├── src/
│   ├── core/
│   │   ├── hardware.odin      # 定数: 画面 160x144、4194304 Hz、70224 cycles/frame、モード列挙
│   │   ├── cpu.odin           # SM83 CPU（最大ファイル。BubiBoy Cpu.fs 相当）
│   │   ├── bus.odin           # メモリマップ、M-cycle tick 駆動、DMA/HDMA、CGB レジスタ
│   │   ├── interrupt.odin     # IF/IE/IME、割り込み定義
│   │   ├── timer.odin         # DIV/TIMA/TMA/TAC
│   │   ├── joypad.odin        # 0xFF00
│   │   ├── ppu.odin           # スキャンライン描画、LCD モードタイミング
│   │   ├── apu.odin           # 4ch + フレームシーケンサ
│   │   ├── cartridge.odin     # ヘッダ解析、ROM/RAM サイズ分類
│   │   ├── mbc.odin           # MBC1/2/3(RTC)/5 の状態と読み書き
│   │   ├── serial.odin        # 0xFF01/02（テスト ROM の出力キャプチャに必要）
│   │   ├── savestate.odin     # ステートのシリアライズ/復元
│   │   └── emulator.odin      # 全体の統合、step / run_frame
│   └── app/
│       ├── main.odin          # エントリポイント
│       ├── cli.odin           # 引数パーサ（--scale/--fullscreen/--shader/--recent/-h/-v）
│       ├── video.odin         # SDL2 ウィンドウ/テクスチャ、scale/fullscreen/shader
│       ├── audio.odin         # SDL2 オーディオ、オーディオ駆動ペーシング
│       ├── input.odin         # キーボード + SDL GameController
│       ├── config.odin        # 設定ファイル（実行ファイルと同じ場所、自動生成）
│       ├── recent.odin        # 最近使ったファイル履歴
│       └── tui.odin           # Claude Code 風 TUI（フェーズ 9）
├── tests/                     # package tests — core のみ import。SDL2 非依存
│   ├── rom_runner.odin        # テスト ROM 実行 + Blargg/Mooneye/acid2 判定
│   ├── roms/                  # fetch_test_roms.sh が配置（.gitignore 対象）
│   └── *_test.odin            # 単体テスト（@(test)）
├── scripts/
│   ├── build_macos.sh
│   ├── build_linux.sh
│   └── fetch_test_roms.sh
├── .github/workflows/
├── docs/dev/                  # 本計画書一式
├── LICENSE                    # MIT
└── mise.toml                  # odin = "dev-2026-07"（既存）
```

## ビルドとパッケージ参照

- Odin はディレクトリ = パッケージ。app から core は **collection** 経由で import する:
  - ビルド: `odin build src/app -collection:bbl=src -out:bbl`
  - コード: `import "bbl:core"`
  - テスト: `odin test tests -collection:bbl=src`
- ビルドコマンドは必ず `scripts/build_*.sh|ps1` に集約し、CI も同じスクリプトを呼ぶ（M88M 方式）。
  スクリプト以外の場所（workflow 内インラインなど）にビルドコマンドを二重管理しない。
- SDL2 は `vendor:sdl2`（Odin 標準添付バインディング）を使う。
  - **開発中（フェーズ 0〜9）**: 動的リンクでよい（macOS: `brew install sdl2`、Ubuntu: `libsdl2-dev`）。
  - **配布時（フェーズ 10〜11）**: BluePrint の要求どおり静的リンクに切り替える。
    各プラットフォームで SDL2 静的ライブラリを用意し、リンカフラグで指定する（phase-10 のタスクで確立）。
  - この「開発=動的 / 配布=静的」の二段構えは意図的な決定。ビルドスクリプトに `--release` 相当の分岐を持たせる。

### SDL2 静的リンクの実現方法（T10-1 で確立、macOS で実機検証済み）

`vendor:sdl2` の `sdl2.odin` は非 Windows で `foreign import lib "system:SDL2"` と書かれており、
これは最終的にリンカへ `-lSDL2` を渡す。この import 文自体は変更せず（vendor コードは変更禁止）、
`odin build ... -extra-linker-flags:"..."` でリンク先だけ静的ライブラリへ差し替える。

- **SDL2 本体の取得**: `scripts/build_sdl2_static.sh <platform> <arch>` が SDL2 2.30.9 のソースを
  取得し、CMake (`-DSDL_STATIC=ON -DSDL_SHARED=OFF`) でビルドして `build/sdl2/<platform>-<arch>/`
  にインストール・キャッシュする（`build/` は .gitignore 対象、CI では `actions/cache` を想定）。
- **macOS (ld64)**: 単純に `-L` で静的ライブラリのディレクトリを探索パスに加えるだけでは、
  Odin 本体が既定でリンカに渡す `-L/opt/homebrew/lib -L/usr/local/lib`（`odin` バイナリに
  埋め込まれている）が先に評価される。odin が組み立てる実際のリンカ呼び出しでは、この
  既定 `-L` 由来の `-lSDL2` 解決自体が `-extra-linker-flags` の内容より前に起きるため、
  後方に `-L` を追加しても効果がない（`odin build ... -print-linker-flags` で実機確認済み。
  ローカル開発機では Homebrew 版 SDL2 の dylib がこの既定パスにたまたま存在し `-lSDL2` が
  解決されていたため気付かなかったが、Homebrew 版 SDL2 が入っていない GitHub Actions
  ランナーでは `ld: library 'SDL2' not found` で即失敗した＝実機で確認済み）。
  そのため CI では `brew install sdl2` を明示的なステップとして実行し、`-lSDL2` が
  解決できる先を用意する。最終バイナリの実体は `-Wl,-force_load,<libSDL2.a への絶対パス>` で
  静的アーカイブの全シンボルを強制的に取り込み、`-Wl,-dead_strip_dylibs` で
  「取り込み済みシンボルにより結果的に不要になった」`-lSDL2` 由来の dylib 参照を
  リンク後に除去することで常に自前ビルドの静的アーカイブへ差し替わる
  （Homebrew 側のバージョンは成果物に影響しない）。フレームワーク（CoreVideo, Cocoa, IOKit,
  ForceFeedback, Carbon, CoreAudio, AudioToolbox, AVFoundation, Foundation は通常、
  GameController/Metal/QuartzCore/CoreHaptics は `-weak_framework`）は
  静的ビルドした `sdl2-config --static-libs` の出力に合わせて明示的に渡す。
  検証: `otool -L ./bbl` に `SDL2` の動的依存が 0 件（`scripts/build_macos.sh --release` で自動化、
  実 CI(GitHub Actions)でも green を確認済み）。
- **Linux (GNU ld/lld)**: ld64 の `force_load`/`dead_strip_dylibs` に相当する機能はないため、
  同じ方式は使えない。代わりに `-L<静的ビルドの prefix>/lib`（このディレクトリには `.so` を置かない）
  + `-Wl,-Bstatic -lSDL2 -Wl,-Bdynamic` で `-lSDL2` の解決先を静的アーカイブに固定し、
  `sdl2-config --static-libs` が返す ALSA/X11/Wayland/dbus 等のシステム動的ライブラリ一覧を
  追加で渡す（これらは意図的に動的のままで正しい。上記「開発=動的/配布=静的」の注記参照）。
  odin が組み立てる実際のリンカ呼び出しでは vendor:sdl2 の foreign import 由来の `-lSDL2` が
  `-extra-linker-flags` の内容より前に置かれるため、`-L` を渡すだけでは解決できない
  （`odin build ... -print-linker-flags` で実機確認済み）。`ld --verbose` の `SEARCH_DIR` から
  ld の既定検索ディレクトリを取得し、静的アーカイブをそこへ直接コピーすることで解決している
  （`scripts/build_linux.sh`。実際に build-linux.yml の CI で green を確認済み）。
- macOS/Linux とも実 CI(GitHub Actions)で green を確認済み（phase-10 検証ログ参照）。
  2026-07-16、ユーザー承認により Windows/Raspberry Pi OS/FreeBSD は対応対象から外した
  （経緯は phase-10-cicd.md 参照）。

## 型と表現の決定事項

| 項目 | 決定 |
|---|---|
| フレームバッファ | `[160*144]u32`、ARGB (0xAARRGGBB)、行優先（index = y*160 + x） |
| CGB 色変換 | RGB555 の各 5bit を `(c << 3) \| (c >> 2)` で 8bit へ拡張 |
| 音声サンプル | `i16` ステレオ interleaved、48000 Hz |
| サイクル単位 | **T-cycle（4194304 Hz）で数える**。M-cycle = 4 T-cycle。CPU はメモリアクセス毎に `bus_tick(bus, 4)` を呼ぶ |
| MBC 状態 | Odin の tagged union: `Mbc_State :: union { Mbc_None, Mbc1_State, Mbc2_State, Mbc3_State, Mbc5_State }` |
| バイト順 | セーブ/ステートファイルはリトルエンディアン固定 |
| エラー処理 | core は panic しない。ロード系は `(result, ok: bool)` か enum エラーを返し、app 側でメッセージ表示 |

## タイミングモデル（BubiBoy 実証済み方式の移植）

1. **CPU は M-cycle 粒度**: 命令実行中の各メモリアクセス（フェッチ含む）ごとに `bus_tick(bus, 4)` を呼び、
   Timer / PPU / APU / DMA を 4 T-cycle 前進させる。命令をアトミックに実行してから一括 tick する方式は
   Mooneye テストが落ちるので採らないこと。
2. **フレーム**: `emulator_run_frame` は累計サイクルが 70224 進むまで step を繰り返す。
3. **実行速度の同期はオーディオ駆動**（フェーズ 5 で導入）: 壁時計タイマーではなく、
   SDL2 オーディオのバッファ残量を見て「足りない間だけ次フレームを生成し、満杯なら数 ms 待つ」。
   これで映像 60fps と音声 48kHz のドリフトが構造的に発生しない。BubiBoy の実証済み設計。

## Odin 固有の指針

- 命名: 型は `Ada_Case`、プロシージャ/変数は `snake_case`（Odin 標準に従う）。
  プロシージャはモジュール接頭辞を付ける（`timer_tick`, `ppu_render_scanline`, `mbc_write`）。
- 固定サイズ配列を優先し、動的確保は ROM/外部 RAM のロード時のみ。フレーム毎のアロケーション禁止。
- `#partial switch` より網羅的 `switch` を優先（命令デコードなどで漏れをコンパイル時に検出）。
- テストは `core:testing` の `@(test)` プロシージャ + `testing.expect`。
- パスの扱い: 実際のユーザー名をコード・ログ・ドキュメントに残さない。`~` 展開は環境変数 `HOME` で行う。

## スコープ外（実装しないこと）

- 実 BIOS（ブート ROM）の読み込み（BluePrint 明記）。起動時は各モードのブート後レジスタ状態を直接セットする。
- スーパーゲームボーイ (SGB) 機能、MBC6/MBC7/HuC1/HuC3、RetroAchievements、GUI ツールキット。
