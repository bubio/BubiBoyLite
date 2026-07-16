# BubiBoyLite

Odin + SDL2 で実装する Game Boy Color エミュレーター（実行ファイル名 `bbl`）。
仕様の唯一の源は [docs/dev/BluePrint.md](docs/dev/BluePrint.md)。
開発計画は [docs/dev/PLAN.md](docs/dev/PLAN.md) を参照。

<!--
  バッジの参照先リポジトリ (OWNER/REPO) はこのリポジトリに GitHub remote が
  設定されてから実 URL に差し替える（phase-10-cicd.md T10-6 参照。
  現時点では GitHub remote 未設定のためリンク切れ）。
-->

[![Build Linux](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-linux.yml/badge.svg)](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-linux.yml)
[![Build macOS](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-macos.yml/badge.svg)](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-macos.yml)
[![Build Windows](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-windows.yml/badge.svg)](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-windows.yml)
[![Build FreeBSD](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-freebsd.yml/badge.svg)](https://github.com/OWNER/BubiBoyLite/actions/workflows/build-freebsd.yml)

## ビルド方法

```sh
mise install
./scripts/build_macos.sh   # Linux/FreeBSD なら build_linux.sh、Windows なら build_win.ps1
```

`--debug` でデバッグビルド、`--test` でビルド後に `odin test tests -collection:bbl=src` も実行する。

## 使用法

```
使用法: bbl [options] game.gbc

  -h, --help        コマンドラインの使い方を表示
  -v, --version     バージョンを表示
  --scale N         表示倍率 (1-8、9以上は8に丸める、デフォルト 4)
  --fullscreen      フルスクリーン表示 (--scale は無視される)
  --shader KIND     シェーダー: nearest, smooth (デフォルト nearest)
  --recent          最近使ったファイルを表示して選択
```

ライセンス: [MIT](LICENSE)
