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
  - **システムにインストール済みのものへ動的リンクする**（macOS: `brew install sdl2`、
    Ubuntu: `libsdl2-dev`）。開発時・配布時とも同じで区別しない
    （2026-07-16、ユーザー承認により「配布時は静的リンク」の方針から変更。
    経緯は phase-10-cicd.md 参照）。
  - 実行には SDL2 のインストールが前提条件になる（BluePrint に明記）。

### SDL2 動的リンクの実現方法

`vendor:sdl2` の `sdl2.odin` は非 Windows で `foreign import lib "system:SDL2"` と書かれており、
これは最終的にリンカへ `-lSDL2` を渡す。この import 文自体は変更せず（vendor コードは変更禁止）。

- **macOS**: Odin 本体が既定でリンカに渡す `-L/opt/homebrew/lib -L/usr/local/lib`
  （`odin` バイナリに埋め込まれている）により、`brew install sdl2` 済みの環境では
  追加のリンカフラグ無しで `-lSDL2` が解決される（実機確認済み）。CI では
  `brew install sdl2` を明示的なステップとして実行する。
  検証: `otool -L ./bbl` に `SDL2` の動的依存が含まれること（`build-macos.yml` で自動化、
  実 CI(GitHub Actions)でも green を確認済み）。
- **Linux**: `libsdl2-dev`（apt）をインストール済みの環境では、ld の既定検索パス
  （`/usr/lib/<triple>` 等）により追加のリンカフラグ無しで `-lSDL2` が解決される。
  検証: `ldd ./bbl` に `libSDL2` の動的依存が含まれること（`build-linux.yml` で自動化、
  実 CI(GitHub Actions)でも green を確認済み）。
- macOS/Linux とも実 CI(GitHub Actions)で green を確認済み（phase-10 検証ログ参照）。
  2026-07-16、ユーザー承認により Windows/Raspberry Pi OS/FreeBSD は対応対象から外した
  （経緯は phase-10-cicd.md 参照）。
- **過去の経緯（参考）**: T10-1〜T10-3 では当初 BluePrint の「静的リンク」要求どおり、
  SDL2 をソースからビルドして静的リンクする方式（`build_sdl2_static.sh`、macOS の
  `force_load`/`dead_strip_dylibs`、Linux の `ld` 既定検索パスへの静的アーカイブ配置等）を
  実装し、実 CI で green にまで到達していた。その後、静的ビルドの複雑さ（プラットフォーム毎の
  リンカ挙動の違い、HIDAPI/libusb 等の依存関係）とユーザー判断により、システムインストール前提の
  動的リンクへ方針転換した。当時の詳細な調査記録は phase-10-cicd.md の検証ログに残っている。

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
