# BubiBoyLite

Odin + SDL2 で実装する Game Boy Color エミュレーター（実行ファイル名 `bbl`）。
仕様の唯一の源は [docs/dev/BluePrint.md](docs/dev/BluePrint.md)。
開発計画は [docs/dev/PLAN.md](docs/dev/PLAN.md) を参照。

[![Build Linux](https://github.com/bubio/BubiBoyLite/actions/workflows/build-linux.yml/badge.svg)](https://github.com/bubio/BubiBoyLite/actions/workflows/build-linux.yml)
[![Build macOS](https://github.com/bubio/BubiBoyLite/actions/workflows/build-macos.yml/badge.svg)](https://github.com/bubio/BubiBoyLite/actions/workflows/build-macos.yml)

## 動作要件

SDL2 がシステムにインストールされている必要がある（ビルド時・実行時とも動的リンク）。

```sh
brew install sdl2       # macOS
sudo apt install libsdl2-2.0-0   # Linux（ビルドする場合は libsdl2-dev）
```

## ビルド方法

```sh
mise install
./scripts/build_macos.sh   # Linux なら build_linux.sh
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
