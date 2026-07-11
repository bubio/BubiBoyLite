# フェーズ 3: PPU (DMG)・画面統合

## 前提

- 依存フェーズ: 2（STAT/VBlank 割り込みの基盤）
- 描画は **スキャンライン単位**（BubiBoy 方式）。FIFO/ピクセルパイプラインは実装しない（dmg-acid2 にはスキャンライン方式で十分）。

## ゴール

DMG の PPU を実装して SDL2 ウィンドウにゲーム画面を表示し、dmg-acid2 をパス、ROM-only ゲーム（Tetris 等）を遊べる状態にする。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src      # dmg_acid2 テストが PASS
./bbl <ROM-onlyゲーム>.gb                # 起動して操作できる（目視）
```

---

### T3-1: LCD レジスタ群

- [x] 完了

**目的**: PPU のレジスタと VRAM/OAM アクセスの土台を作る。
**作るもの**: `src/core/ppu.odin`:
- レジスタ: LCDC(FF40), STAT(FF41), SCY/SCX(FF42/43), LY(FF44, 読み取り専用), LYC(FF45), BGP(FF47), OBP0/1(FF48/49), WY/WX(FF4A/4B)。ビット定義は references.md の表どおり
- STAT: bit7 は常に 1、bit2 (LYC==LY) と bit1-0 (モード) は PPU が更新。書き込みは bit6-3 のみ反映
- bus.odin の IO 分岐から接続
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Lcd.fs`、Pan Docs "LCD Control" / "LCD Status"
**完了条件 (DoD)**: 単体テストでレジスタの読み書きマスク（STAT bit7、LY 書き込み無効）を確認。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: LY への書き込みは無視（リセットではない）。
**依存**: なし

---

### T3-2: モードタイミングと割り込み

- [x] 完了

**目的**: PPU のステートマシン（モード 2→3→0 → 次ライン、144 行目から VBlank）を bus_tick 駆動で回す。
**作るもの**: ppu.odin:
- 1 ライン = 456 T-cycle。モード 2 (OAM scan) = 80、モード 3 (描画) = 172 固定（可変長は実装しない）、残りモード 0 (HBlank)
- LY 0-143 が可視、144 で VBlank 割り込み (IF bit0) + モード 1、LY 153 の後 LY=0 へ
- STAT 割り込み (IF bit1): bit6 (LYC==LY)、bit5 (モード2)、bit4 (モード1)、bit3 (モード0) の条件成立の**立ち上がりエッジ**で発火（STAT blocking: 既にいずれかの条件が真なら新たな割り込みは出ない）
- LCDC bit7=0 (LCD off) 中は LY=0・モード0 固定、tick しない。再有効化でライン先頭から
- `ppu_tick(ppu, t_cycles)` を bus_tick から呼ぶ。モード 3→0 遷移時に `ppu_render_scanline`（T3-3）を呼ぶ
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Bus.fs`（PPU 駆動部）+ `Video.fs`、Pan Docs "Rendering" / "STAT modes"
**完了条件 (DoD)**: 単体テスト: 70224 T-cycle で LY が一巡し VBlank 割り込みが 1 回。LYC 一致で STAT bit2。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: STAT blocking（複数条件の OR の立ち上がりだけで発火）を実装しないと実ゲームで STAT 割り込みが二重発火する。
**依存**: なし

---

### T3-3: BG スキャンライン描画

- [x] 完了

**目的**: 背景 1 ラインをフレームバッファに描く。
**作るもの**: ppu.odin の `ppu_render_scanline`:
- タイルマップ: LCDC bit3 で 0x9800/0x9C00。タイルデータ: LCDC bit4 で 0x8000 (unsigned index) / 0x8800 (signed index, 基点 0x9000)
- SCX/SCY による 256×256 マップ内のラップアラウンド
- 2bpp デコード: 各行 2 バイト、bit7 が左端ピクセル。カラー番号 → BGP でパレット変換 → DMG 4 階調（0xFFE0F8D0 系ではなく素直なグレー: 0xFFFFFFFF, 0xFFAAAAAA, 0xFF555555, 0xFF000000 とする）
- LCDC bit0=0 なら BG は白
- 各ピクセルの**パレット適用前カラー番号**をライン内バッファに保持（スプライト優先度判定で使う）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Video.fs`（renderScanline）、Pan Docs "Tile Data" / "Tile Maps"
**完了条件 (DoD)**: 単体テスト: VRAM に既知のタイルを書き、1 ライン描画後の framebuffer ピクセルを検証（signed/unsigned 両モード、SCX ラップ）。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: signed インデックスモード（LCDC bit4=0）の基点は 0x9000。`i8` キャストで計算する。
**依存**: T3-2

---

### T3-4: ウィンドウ描画

- [x] 完了

**目的**: ウィンドウレイヤを実装する。
**作るもの**: ppu.odin:
- LCDC bit5 有効時、`LY >= WY` かつ `x >= WX-7` の領域でウィンドウを BG の代わりに描画。タイルマップは LCDC bit6
- **ウィンドウ内部ラインカウンタ**: ウィンドウの行はスクリーン LY ではなく「ウィンドウが実際に描画されたライン数」で数える（フレーム開始時 0 リセット、ウィンドウを描いたラインでのみ +1）
**参照**: Pan Docs "Window"
**完了条件 (DoD)**: 単体テスト: WY/WX 指定でウィンドウ切り替わり位置のピクセル検証。途中で WY を跨いだ場合の内部カウンタ挙動。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 内部ラインカウンタを LY で代用すると dmg-acid2 が落ちる（acid2 の主要検査項目の 1 つ）。WX=7 が画面左端。
**依存**: T3-3

---

### T3-5: スプライト描画

- [x] 完了

**目的**: OAM のスプライト（8x8 / 8x16）を優先度込みで描画する。
**作るもの**: ppu.odin:
- OAM エントリ 4 バイト: Y(+16), X(+8), tile, attr（bit7=BG 優先, bit6=Y flip, bit5=X flip, bit4=パレット）
- ライン毎に OAM を先頭から走査し**最初の 10 個**まで。LCDC bit2 で 8x16（tile 下位 bit 無視）
- DMG の描画優先: **X 座標が小さいスプライトが勝つ**（同 X なら OAM 順）。attr bit7=1 なら BG カラー 1-3 の上には描かない。スプライトのカラー 0 は透明
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/Video.fs`（スプライト部）、Pan Docs "OAM"
**完了条件 (DoD)**: 単体テスト: 10 個制限、X 優先度、透明色、8x16 の tile index マスク。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 「ライン 10 個制限」は X 座標に関係なく **OAM 順で先着 10 個**（画面外 X でも枠を消費する）。X 優先はその 10 個の描画順の話。
**依存**: T3-3

---

### T3-6: SDL2 画面統合と暫定ペーシング

- [x] 完了

**目的**: エミュレータのフレームバッファを SDL2 で表示し、実機速度で回す（暫定: 壁時計 60fps。オーディオ駆動はフェーズ 5 で置換）。
**作るもの**: `src/app/main.odin` / `video.odin`:
- ROM 指定時のメインループ: `emulator_run_frame` → `SDL_UpdateTexture` → `SDL_RenderCopy` → `SDL_RenderPresent`
- 暫定ペーシング: フレーム所要 16.74ms（70224 / 4194304 秒）に合わせて `SDL_Delay`。**このコードには「フェーズ 5 でオーディオ駆動に置換」のコメントを付ける**
- Esc / クローズで終了
**参照**: architecture.md「タイミングモデル」
**完了条件 (DoD)**: dmg-acid2 を GUI 起動して参照 PNG（リポジトリ同梱）と目視一致。
**検証方法**:
```sh
./bbl tests/roms/acid2/dmg-acid2.gb   # 目視で reference PNG と比較
```
**落とし穴**: VSync に頼らない（240Hz モニタで 4 倍速になる）。SDL_Delay の分解能は粗いので誤差の蓄積を `SDL_GetPerformanceCounter` で補正する。
**依存**: T3-2〜T3-5

---

### T3-7: キーボード入力

- [x] 完了

**目的**: キーボードを joypad に接続してゲームを操作可能にする。
**作るもの**: `src/app/input.odin`:
- デフォルト割当: 矢印キー=十字キー、Z=B、X=A、Enter=Start、右Shift=Select（キーコンフィグはフェーズ 8）
- SDL_KEYDOWN/KEYUP → `joypad_set_button`
- 追加ショートカット: Esc=終了。（ステートセーブ用の F5/F7 などはフェーズ 7 で予約）
**参照**: BluePrint.md「キーボードショートカットで操作」
**完了条件 (DoD)**: ROM-only ゲームでメニュー操作・ゲームプレイができる（目視）。
**検証方法**: `./bbl <ゲーム>.gb` で十字キーとボタンの動作確認。
**落とし穴**: キーリピートイベント（`event.key.repeat != 0`）は無視する。
**依存**: T3-6

---

### T3-8: dmg-acid2 ハッシュ固定 + 実ゲーム確認

- [ ] 完了

**目的**: フェーズ 3 のマイルストーン。PPU の正しさを自動テストに固定する。
**作るもの**:
- `scripts/fetch_test_roms.sh` に dmg-acid2 取得を追加
- `tests/acid2_test.odin`: 100 フレーム実行後の framebuffer FNV-1a 64bit ハッシュを比較（testing.md「acid2 方式」。**目視で reference PNG と一致確認してからハッシュを固定**）
- フェーズ 2 で持ち越した PPU 依存 Mooneye テスト（di_timing 等）があれば再挑戦し、通ったら許可リストから外す
**参照**: testing.md
**完了条件 (DoD)**: `odin test tests` で dmg_acid2 が PASS。ROM-only の市販ゲーム 1 本がタイトル→プレイまで動作（目視、検証ログにゲーム名を記録）。
**検証方法**:
```sh
odin test tests -collection:bbl=src
./bbl <ゲーム>.gb
```
**落とし穴**: acid2 は「10 スプライト制限」「ウィンドウ内部カウンタ」「8x16 タイルマスク」を検査する。顔の絵が崩れている場合、崩れ方から原因を特定できる（acid2 リポジトリの failure examples 参照）。
**依存**: T3-4, T3-5, T3-6

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-11 T3-1 完了: `src/core/ppu.odin` を新規作成し LCDC/STAT/SCY/SCX/LY/LYC/BGP/OBP0/OBP1/WY/WX を実装。
bus.odin の IO 分岐(bus_io_read/bus_io_write)から接続。STAT は bit7 常時1・書き込みは bit6-3 のみ反映、
bit2(LYC==LY)/bit1-0(モード)はPPU管理値から合成、LY 書き込みは無視。
`odin test tests -collection:bbl=src` で新規 tests/ppu_test.odin 4本を含む全133本PASS。
`odin build src/app -collection:bbl=src` もビルド成功を確認。
副作用として mooneye timer/tim00_div_trigger・tim01_div_trigger・tim10_div_trigger・tim11_div_trigger の
4本が新たに expected_failures.odin 行き(理由はファイル内コメント参照。disable_ppu_safe が LY=$90 到達待ちで
無限ループするようになったため。以前はLCDC/LY未実装で固定0xFFを返しており偶然ポーリングを素通りしていた)。
T3-2でppu_tickを接続しLYが進むようになった時点で再検証し許可リストから外すこと。

2026-07-11 T3-2 完了: ppu.odin にモードタイミング(1ライン456T、モード2=80/モード3=172固定/
残りモード0)、LY0-143可視・144でVBlank割り込み+モード1・LY153後LY=0、STAT blocking(条件ORの
立ち上がりエッジでのみ発火、STAT/LYC/LCDC書き込み後にも再評価)、LCDC bit7 OFF中はtickしない
実装を追加。`ppu_tick`をbus_tickから呼ぶよう配線(BGスキャンライン描画は仮実装、白一色。T3-3で置換)。
新規単体テスト3本(tests/ppu_timing_test.odin): 70224 T-cycleでLYが一巡しVBlank割り込みが立つこと、
LYC一致でSTAT bit2が立つこと、STAT割り込みが条件が真のまま変化しない間は再発火しないこと(blocking)。
`odin test tests -collection:bbl=src` で全136本PASS。`odin build src/app -collection:bbl=src` もビルド成功。
副作用: LYが実際に進むようになったため disable_ppu_safe 待ちで停止していた mooneye
interrupts/ie_push・oam_dma/basic・oam_dma_start・timer/tim00_div_trigger・tim01_div_trigger・
tim10_div_trigger・tim11_div_trigger の計7本がPASSするようになり expected_failures.odin から除外。
halt_ime0_ei・halt_ime0_nointr_timing(TIMEOUT)・oam_dma/reg_read(FAIL)はT3-2後も未解決のため許可リストに残す
(理由は tests/expected_failures.odin のコメント参照、T3-8等で再調査予定)。

2026-07-11 T3-3 完了: ppu_render_scanline にBG描画を実装(タイルマップLCDC bit3で0x9800/0x9C00選択、
タイルデータLCDC bit4でunsigned 0x8000起点/signed 0x9000起点、SCX/SCYの256x256ラップアラウンド、
2bppデコード、BGPパレット変換、DMG_SHADE_0-3への変換)。LCDC bit0=0時はBG白一色(bg_color_indexも0、
T3-5のスプライト優先度判定用)。パレット適用前カラー番号をbg_color_indexに保持。
新規単体テスト4本(tests/ppu_bg_test.odin): unsignedタイルモード、SCXの256境界ラップ(tile_col31→0)、
signedタイルモード(基点0x9000、インデックス0xFFで0x8FF0)、BG無効時の白塗り。
`odin test tests -collection:bbl=src` で全140本PASS。`odin build src/app -collection:bbl=src` もビルド成功。

2026-07-11 T3-4 完了: ppu_render_scanline にウィンドウ描画を追加。LCDC bit5有効時、
LY>=WYかつx>=WX-7の領域でBGの代わりにウィンドウ(タイルマップLCDC bit6)を描画。
ウィンドウ内部ラインカウンタ(window_line)を導入: フレーム開始時0リセット(LY153後の
ラップ、およびLCDC bit7の0→1再有効化時)、ウィンドウを実際に描画したライン(有効かつ
LY>=WYかつ画面内に1ピクセル以上表示される)だけで+1。ウィンドウ画素もbg_color_indexへ
書き込む(T3-5のスプライト優先度判定でBG扱いにするため)。LCDC bit0=0のときはBG同様
ウィンドウも白(DMGの仕様どおりbit0がBG&ウィンドウ全体を無効化)。
新規単体テスト2本(tests/ppu_window_test.odin): WY/WX境界でのBG↔ウィンドウ切り替わり、
および「ウィンドウを一時的に無効化してから再度有効化」した際に内部カウンタが
LY-WYの直接代用にならず、実際に描画したライン数だけを反映することを確認するテスト
(落とし穴の直接的な再現・検出)。
`odin test tests -collection:bbl=src` で全142本PASS。`odin build src/app -collection:bbl=src` もビルド成功。

2026-07-11 T3-5 完了: ppu_render_scanline の末尾から ppu_render_sprites を呼ぶ形でスプライト
描画を追加。OAM(4バイト: Y+16, X+8, tile, attr)をindex0から走査し、このラインに掛かる
最初の10個を収集(X座標に関係なくOAM順、画面外Xでも枠を消費)。DMG優先度(X座標が
小さいスプライトが勝つ、同Xなら小さいOAM indexが勝つ)で並べ替え、pixel_owned配列で
「最初にそのXを確定したスプライトが勝つ」形でX優先度を実装。attr bit7(BG優先)は
ピクセルの所有権(どのスプライトが勝つか)には影響させず、勝ったスプライトがBGカラー
1-3の上に描くかどうかだけを左右する(独立した判定であることをテストで明示的に確認)。
スプライトのカラー0は透明(所有権も取らない)。8x16(LCDC bit2)ではタイルindex下位bit
を無視し、Y-flip後の行から上半分/下半分を選択。落とし穴として、LCDC bit0=0(BG/ウィンドウ
無効)でもスプライトはbit1が有効なら独立して描画され続けることを確認して実装した
(Pan Docs "LCDC.0")。
新規単体テスト5本(tests/ppu_sprite_test.odin): 透明色(カラー0)、X優先度(重なり領域は
X座標の小さい方が勝つ)、10個制限(11番目以降はOAM順で描画されない、画面外Xも枠を消費)、
8x16のtile indexマスク(奇数indexでも偶数に丸められる)、BG優先度ビット(所有権とは独立)。
`odin test tests -collection:bbl=src` で全147本PASS。`odin build src/app -collection:bbl=src` もビルド成功。

2026-07-11 T3-6 完了: src/core/emulator.odin の Emulator に cpu: Cpu / bus: Bus を追加し、
emulator_load_rom(ROM-onlyロード+cpu_reset)・emulator_step・emulator_run_frame(累計サイクル
基準でフレーム境界の余剰を次フレームへ持ち越す方式、ドリフト防止)を実装。
src/app/main.odin に run_rom_window を追加: ROM読み込み→emulator_run_frame→
emu.bus.ppu.framebuffer を video_present、Esc/クローズで終了。暫定ペーシングは
SDL_GetPerformanceCounter基準でフレーム所要時間(70224/4194304秒)を待ち、SDL_Delayの粗い
分解能による誤差蓄積を毎フレーム補正(TODOコメントでフェーズ5のオーディオ駆動置換を明記)。
scripts/fetch_test_roms.sh に dmg-acid2 ROM(mattcurrie/dmg-acid2 v1.0リリースアセット)と
参照PNG(同リポジトリのimg/reference-dmg.png、コミット8a98ce7固定)の取得を追加。
視覚検証: 実際に `bbl tests/roms/acid2/dmg-acid2.gb` をGUI起動し、macOSの`screencapture`で
ウィンドウをスクリーンショットしてReadツールで画像として確認。参照PNG(img/reference-dmg.png)
と目視比較し、顔の輪郭・目の三日月装飾・鼻(ダイヤ形)・口・"HELLO WORLD!"/"dmg-acid2 by Matt
Currie"のテキストが一致することを確認した(崩れなし)。スクリーンショットは一時ディレクトリに
保存し、リポジトリには含めていない。
`odin test tests -collection:bbl=src` で全147本PASS(既存回帰なし)。`odin build src/app -collection:bbl=src` ビルド成功。

2026-07-11 T3-7 完了: `src/app/input.odin` を新規作成。`input_key_to_button`(矢印キー=十字キー、
Z=B、X=A、Enter/KP_ENTER=Start、右Shift=Select、割当外は ok=false)と `input_handle_key_event`
(event.repeat!=0のキーリピートは無視して`joypad_set_button`へ委譲)を実装し、main.odinの
run_rom_windowのKEYDOWN/KEYUPケースから呼ぶよう配線。`odin test tests -collection:bbl=src`で
全147本PASS(既存回帰なし)。`odin build src/app -collection:bbl=src`ビルド成功。
自作のROM-onlyホームブリューROM(input_demo.gb、RGBDS 1.0.1でこのセッション用に自作。
d-padでスプライトを1px/フレーム移動させるだけの最小デモ、パブリックドメイン相当、
検証用途のみでリポジトリには含めない)で確認:
(1) headless(`emulator_load_rom`+`emulator_run_frame`+`core.joypad_set_button`を直接呼ぶ
検証プログラム)でRight長押し30フレーム相当でOAM Xが88→118(+30)へ正確に移動することを
数値確認(joypad→bus→ROM→OAM書き換えのコアパイプラインが正しく動作)。
(2) OS合成キーイベント(`osascript`経由の`System Events key down/up`)を実ウィンドウへ送る方式を
試みたが、この実行環境ではSDLウィンドウにキーイベントが届かなかった(bbl側にKEYDOWNログを
一時的に仕込んでも0件)。切り分けのため無関係なTextEditへも同様の合成キー操作を試したところ
AppleEventタイムアウトで失敗しており、bbl固有の問題ではなく本サンドボックス環境のGUI自動化
(Accessibility権限等)の制約と判断した。
(3) (2)の代わりに、main.odinのイベントループへ一時的なデバッグコード(`sdl.PushEvent`で
KEYDOWN(.RIGHT)をSDLイベントキューへ直接注入)を仕込んで再ビルドし実行、スクリーンショットで
確認した。これは`input.odin`の実コード(`sdl.PollEvent`→`input_handle_key_event`→
`input_key_to_button`→`joypad_set_button`)を実際に実行させる経路であり、(1)のような
コア直接呼び出しのバイパスではない。起動直後(スプライトは画面中央、input_before.pngで確認済み)
から約0.9秒後のスクリーンショットで、スプライトが画面中央から右へ明確に移動している画像を確認した
(input_synth_early.png、Readツールで目視確認)。確認後、デバッグ用の`sdl.PushEvent`注入コードは
`git diff`で意図した差分(input_handle_key_event呼び出しの配線のみ)に戻したことを確認して削除した。
結論: input.odin自体のロジックとイベント配線は実コード実行込みで動作確認済み。実OSキーボードの
物理入力がSDLへ届く経路(この環境のosascript/Accessibility制約)のみ「未確認」として正直に記録する
(この部分はSDL側の責務でありinput.odinのコードの正しさとは別軸)。
