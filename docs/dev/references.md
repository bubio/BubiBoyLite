# BubiBoyLite 参照早見表

実装時に BubiBoy を毎回 grep しなくて済むための静的な対応表。
BubiBoy（`~/dev/_Emu/BubiBoy`）は F#/.NET 製の前身プロジェクトで、**アルゴリズムはそのまま移植してよい**。
F# のイディオム（判別共用体、イミュータブルレコード更新）は Odin の tagged union / 構造体 + 手続きに読み替えること。

## BubiBoy ↔ BubiBoyLite モジュール対応表

| BubiBoyLite（予定） | BubiBoy 参照元 | 行数 | 備考 |
|---|---|---:|---|
| `src/core/hardware.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Hardware.fs` | 25 | 定数（160x144、4.19MHz、70224 cyc/frame） |
| `src/core/cpu.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cpu.fs` | 3903 | 最大モジュール。M-cycle 粒度の Machine モジュール構造に注目 |
| `src/core/bus.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs` | 1076 | メモリマップ、tick 駆動、DMA/HDMA、CGB レジスタ |
| `src/core/interrupt.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Interrupt.fs` | 26 | 割り込み定義 |
| `src/core/timer.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Timer.fs` | 136 | DIV 内部カウンタと落下エッジ検出 |
| `src/core/joypad.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Joypad.fs` | 70 | |
| `src/core/ppu.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Video.fs` + `Lcd.fs` | 390+73 | スキャンライン単位描画、CGB 色は Video.fs:289-366 |
| `src/core/apu.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Apu.fs` | 970 | 4ch + フレームシーケンサ、48kHz 出力 |
| `src/core/cartridge.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Cartridge.fs` | 154 | ヘッダ解析 |
| `src/core/mbc.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/CartridgeMemory.fs` | 677 | MBC1/2/3(RTC)/5、外部 RAM |
| `src/core/savestate.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/SaveState.fs` | 737 | バージョン付きバイナリ、全状態の網羅リストとして有用 |
| `src/core/emulator.odin` | `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Emulator.fs` | 165 | step / runFrame、起動時レジスタ設定 |
| `src/app/audio.odin`（ペーシング） | `~/dev/_Emu/BubiBoy/src/BubiBoy.App/RuntimePacing.fs` + `EmulationRunner.fs` | - | オーディオ駆動ペーシングの実証実装 |
| `.sav/.rtc 入出力` | `~/dev/_Emu/BubiBoy/src/BubiBoy.IO/SaveRam.fs` | - | アトミック書込（temp→bak→move）、.rtc 18 バイト形式 |
| CI/CD 全般 | `~/dev/_Emu/M88M/.github/workflows/` + `~/dev/_Emu/M88M/scripts/` | - | フェーズ 10/11 のテンプレート |

## 主要 I/O レジスタ早見表

| アドレス | 名前 | 概要 |
|---|---|---|
| FF00 | JOYP | ジョイパッド（bit5=アクション選択, bit4=方向選択, bit3-0=入力・0=押下） |
| FF01/FF02 | SB/SC | シリアル転送データ/制御（Blargg テストの出力経路） |
| FF04 | DIV | 分周器（書き込みで内部 16bit カウンタ全体が 0 に） |
| FF05/FF06/FF07 | TIMA/TMA/TAC | タイマー計数/リロード値/制御（TAC bit2=有効, bit1-0=周波数） |
| FF0F / FFFF | IF / IE | 割り込み要求 / 許可（bit0=VBlank, 1=STAT, 2=Timer, 3=Serial, 4=Joypad） |
| FF10-FF14 | NR10-14 | ch1 矩形波（スイープ付き） |
| FF16-FF19 | NR21-24 | ch2 矩形波 |
| FF1A-FF1E | NR30-34 | ch3 波形メモリ |
| FF20-FF23 | NR41-44 | ch4 ノイズ |
| FF24/FF25/FF26 | NR50/51/52 | マスター音量 / パンニング / 電源 |
| FF30-FF3F | Wave RAM | ch3 波形データ 16 バイト |
| FF40 | LCDC | LCD 制御（bit7=LCD on, 6=Win map, 5=Win on, 4=BG/Win tiles, 3=BG map, 2=OBJ size, 1=OBJ on, 0=BG on/priority） |
| FF41 | STAT | LCD 状態（bit6=LYC int, 5=OAM int, 4=VBlank int, 3=HBlank int, 2=LYC==LY, 1-0=モード） |
| FF42/FF43 | SCY/SCX | BG スクロール |
| FF44 | LY | 現在のスキャンライン（0-153、読み取り専用） |
| FF45 | LYC | LY 比較 |
| FF46 | DMA | OAM DMA（値×0x100 から 160 バイト転送、160 M-cycle） |
| FF47/FF48/FF49 | BGP/OBP0/OBP1 | DMG パレット |
| FF4A/FF4B | WY/WX | ウィンドウ位置（WX は +7 オフセット） |
| FF4D | KEY1 | [CGB] ダブルスピード（bit7=現速度, bit0=切替準備。STOP で切替） |
| FF4F | VBK | [CGB] VRAM バンク（bit0 のみ有効、2 バンク × 8KiB） |
| FF51-FF55 | HDMA1-5 | [CGB] VRAM DMA（HDMA5 bit7: 0=GDMA 即時, 1=HBlank 毎 16 バイト） |
| FF68/FF69 | BCPS/BCPD | [CGB] BG パレット RAM（64 バイト、bit7=オートインクリメント） |
| FF6A/FF6B | OCPS/OCPD | [CGB] OBJ パレット RAM（64 バイト） |
| FF70 | SVBK | [CGB] WRAM バンク（1-7、0 指定は 1 扱い） |

## カートリッジヘッダ早見表

| アドレス | 内容 |
|---|---|
| 0x0134-0x0143 | タイトル |
| 0x0143 | CGB フラグ（0x80=CGB 対応/DMG 互換, 0xC0=CGB 専用） |
| 0x0147 | カートリッジ種別（0x00=ROM only, 0x01-03=MBC1, 0x05-06=MBC2, 0x0F-13=MBC3, 0x19-1E=MBC5。+RAM/+BATTERY の別あり） |
| 0x0148 | ROM サイズ（32KiB << n） |
| 0x0149 | RAM サイズ（0=なし, 2=8KiB, 3=32KiB, 4=128KiB, 5=64KiB） |

## ブート後レジスタ初期値（ブート ROM 非対応のため直接セット）

| モード | AF | BC | DE | HL | SP | PC |
|---|---|---|---|---|---|---|
| DMG | 0x01B0 | 0x0013 | 0x00D8 | 0x014D | 0xFFFE | 0x0100 |
| CGB | 0x1180 | 0x0000 | 0xFF56 | 0x000D | 0xFFFE | 0x0100 |

CGB 判定は A レジスタ = 0x11 で行うゲームが多い。ハードウェアレジスタの初期値は Pan Docs "Power Up Sequence" を参照。

## 外部資料

| 資料 | URL | 用途 |
|---|---|---|
| Pan Docs | https://gbdev.io/pandocs/ | 一次資料。タスク中の「Pan Docs: 章名」はここの章 |
| SM83 命令表 | https://gbdev.io/gb-opcodes/optables/ | オペコード全表（JSON もあり） |
| mooneye-test-suite | https://github.com/Gekkio/mooneye-test-suite | テスト ROM とその判定仕様 |
| gb-test-roms (Blargg) | https://github.com/retrio/gb-test-roms | Blargg ROM のミラー |
| dmg-acid2 / cgb-acid2 | https://github.com/mattcurrie/dmg-acid2 ほか | PPU 検証、reference PNG あり |
| Odin vendor:sdl2 | https://pkg.odin-lang.org/vendor/sdl2/ | SDL2 バインディング API |
| Odin core:testing | https://pkg.odin-lang.org/core/testing/ | テストフレームワーク |
