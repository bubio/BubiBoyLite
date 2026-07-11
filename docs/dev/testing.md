# BubiBoyLite テスト戦略

## 前提

architecture.md のとおり `src/core` は SDL2 非依存。テスト（`tests/` パッケージ）は core のみを import するため、
CI ではディスプレイもオーディオデバイスも不要でテスト ROM を実行できる。

## テスト ROM の入手

テスト ROM はリポジトリに**同梱しない**。`scripts/fetch_test_roms.sh` がピン止めしたコミット/リリースから取得して
`tests/roms/` に配置する（`tests/roms/` は .gitignore 対象）。

| スイート | 取得元 | 配置先 | 用途 |
|---|---|---|---|
| Blargg (cpu_instrs, instr_timing, dmg_sound ほか) | `retrio/gb-test-roms`（コミットをピン止め） | `tests/roms/blargg/` | CPU 命令・タイミング・APU |
| Mooneye acceptance | `~/dev/_Emu/BubiBoy/tests/BubiBoy.TestRoms/roms/mooneye/` からコピー（MIT、30 本選定済み）。無ければ Gekkio の mooneye-test-suite リリースから | `tests/roms/mooneye/` | タイマー・割り込み・DMA・MBC の正確性 |
| dmg-acid2 | `mattcurrie/dmg-acid2` リリース | `tests/roms/acid2/dmg-acid2.gb` | DMG PPU の網羅描画 |
| cgb-acid2 | `mattcurrie/cgb-acid2` リリース | `tests/roms/acid2/cgb-acid2.gbc` | CGB PPU の網羅描画 |

スクリプトの要件:
- 再実行して安全（取得済みならスキップ）。
- ダウンロード URL は必ずコミットハッシュ / リリースタグ付きで固定する。
- CI では `actions/cache` で `tests/roms/` をキャッシュする（キー = スクリプト自身のハッシュ）。

## 判定方式（`tests/rom_runner.odin` に実装する 3 種類）

すべての方式に共通: **タイムアウト = 120,000,000 T-cycle**（約 28.6 秒相当）。超過は FAIL。

### 1. Blargg 方式: シリアル出力

Blargg の ROM は結果をシリアルポートに書く。
- `0xFF01 (SB)` に書かれたバイトを、`0xFF02 (SC)` へ `0x81` が書かれたタイミングで文字列バッファに追記する
  （`src/core/serial.odin` のキャプチャ機能）。
- バッファに `"Passed"` が現れたら PASS、`"Failed"` が現れたら FAIL。

### 2. Mooneye 方式: `LD B,B` + レジスタ指紋

Mooneye の ROM は終了時に `LD B,B`（オペコード 0x40）を実行する。
- CPU が 0x40 を実行したら停止し、レジスタを検査:
  - **PASS**: B=3, C=5, D=8, E=13, H=21, L=34（フィボナッチ数列）
  - **FAIL**: 全レジスタ = 0x42
- rom_runner にデバッグフック（「次の 0x40 実行で停止」フラグ）を持たせる。

### 3. acid2 方式: フレームバッファハッシュ

- 規定フレーム数（ROM が安定画面に達する数。目安 100 フレーム）実行後、
  `framebuffer` の FNV-1a 64bit ハッシュを期待値と比較。
- **期待値の決め方**: 最初にパスさせるとき、レンダリング結果を参考画像
  （dmg-acid2 / cgb-acid2 リポジトリの reference PNG）と**目視比較**して正しいことを確認し、
  そのときのハッシュをテストコードに定数として固定する。以後はリグレッションガードとして機能する。

## `odin test` への統合

- `tests/` の各テストは `@(test)` プロシージャ。ROM テストは中から rom_runner を呼ぶ。
- 実行: `odin test tests -collection:bbl=src`
- **ROM 未取得時は skip 扱い**（`os.exists` で確認して `testing.expect` を呼ばずログだけ出して return）。
  fetch スクリプト未実行のローカル環境を壊さないため。
- **許可リスト方式**: 「まだ通らないことが分かっているテスト ROM」は
  `tests/expected_failures.odin` の一覧に列挙して FAIL でもテスト全体は成功にする。
  フェーズが進んで通るようになったら一覧から削除する（削除を忘れると通知される: 予期せぬ PASS も報告する）。
  これにより CI は常にグリーンを保ちつつ、パスした ROM の後退（リグレッション）は即検出できる。

## 単体テストの方針

- テスト ROM がカバーしない箇所を中心に書く: ヘッダ解析、MBC バンク計算の境界値、
  .sav/.state のラウンドトリップ、設定ファイルのパース、CLI 引数の丸め（--scale 9 → 8）。
- CPU 命令の網羅は Blargg に任せ、単体テストでは代表命令（DAA、ADC/SBC のフラグ）だけ固定する。

## CI での実行

- フェーズ 0 の最小 workflow: ubuntu + macos で `fetch_test_roms.sh` → ビルド → `odin test tests -collection:bbl=src`。
- パスするテスト ROM が増えるたび、許可リストから外すことで CI が自動的にリグレッションガードに育つ。
- フェーズ 10 で全プラットフォームのビルド matrix に拡張する（テスト実行は ubuntu/macos のみで十分）。
