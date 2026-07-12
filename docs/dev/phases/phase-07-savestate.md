# フェーズ 7: セーブステート・RTC 永続化

## 前提

- 依存フェーズ: 6（保存すべき状態が全部揃ってから作る。それ以前に作るとフィールド追加のたびに壊れる）

## ゴール

任意時点の完全な状態保存/復元 (.state) と MBC3 RTC の永続化 (.rtc) を実装する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # ラウンドトリップテスト PASS
# ゲーム中に F5 保存 → 進める → F7 復元 → 保存時点に完全に戻る（目視）
```

---

### T7-1: ステートのシリアライズ

- [x] 完了

**目的**: エミュレータ全状態をバージョン付きバイナリに書き出す。
**作るもの**: `src/core/savestate.odin`:
- フォーマット: マジック `"BBLS"` (4B) + フォーマットバージョン u32 (=1) + ROM チェックサム（ヘッダ 0x014E-0x014F のグローバルチェックサム 2B）+ 本体
- 本体: CPU 全レジスタ/ime/halted、バス（VRAM 全バンク、WRAM 全バンク、OAM、HRAM、IO、IE、DMA/HDMA 状態、double_speed、パレット RAM、各バンクレジスタ）、Timer 内部カウンタ、PPU 状態（モード、ライン内サイクル、ウィンドウ内部カウンタ）、APU 状態（各 ch のタイマー/LFSR/エンベロープ、フレームシーケンサ位置）、MBC 状態（union の種別タグ + 中身）、外部 RAM、RTC、累計サイクル、framebuffer
- **すべてリトルエンディアン**（architecture.md）。`savestate_write(emu) -> []u8` / `savestate_read(emu, data) -> Load_Error`
- 網羅漏れ防止: BubiBoy SaveState.fs（version 7）の保存項目リストと突き合わせる
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.Core/SaveState.fs:351-675`（保存項目の網羅リストとして最重要）
**完了条件 (DoD)**: 単体テスト: write → read → 再 write でバイト列が一致（決定性）。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: リングバッファのインデックスや「次の 0x40 で停止」等のデバッグ状態は保存しない。ROM 本体も保存しない（チェックサムで同一カートリッジを確認するのみ）。
**依存**: なし

---

### T7-2: 復元と検証

- [x] 完了

**目的**: .state からの復元を安全にする。
**作るもの**: savestate.odin:
- 復元前検証: マジック不一致 / バージョン不一致 / ROM チェックサム不一致 / サイズ不足 → それぞれ別のエラー enum を返し、**現在の状態を壊さない**（一時 Emulator に読み込んでから swap する等）
- app 側 (`src/app/statefile.odin`): `<ROM名>.state` の読み書き（.sav と同じアトミック書き込みを流用）
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.IO/SaveStateFile.fs`
**完了条件 (DoD)**: 単体テスト: 破損データ（各種）で適切なエラー + 元状態が無傷。正常データで全フィールド復元。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: バージョン不一致は「読めるだけ読む」をせず明確に拒否する（フォーマット進化はバージョン番号を上げて対応）。
**依存**: T7-1

---

### T7-3: RTC 永続化 (.rtc)

- [x] 完了

**目的**: MBC3 の RTC を電源断（プロセス終了）をまたいで進める。
**作るもの**: `src/app/saveram.odin` 拡張:
- `<ROM名>.rtc`: マジック `"BBLR"` + バージョン u8 (=1) + RTC レジスタ 5B + ラッチ済み 5B + latch_prepared 1B + 基準 UNIX 時刻 i64 = 24 バイト固定
- ロード時: 保存時からの経過秒を現在時刻との差で計算し RTC に加算（DH bit6 停止中は加算しない）
- .sav と同タイミングで保存
**参照**: `~/dev/_Emu/BubiBoy/src/BubiBoy.IO/SaveRam.fs:51-86`（BBRTC 18 バイト形式。同じ考え方で BBL 用に再定義）
**完了条件 (DoD)**: 単体テスト: 保存 → 「1 時間後」を注入してロード → RTC が 1 時間進んでいる。停止ビット時は進まない。
**検証方法**: `odin test tests -collection:bbl=src`
**落とし穴**: 時刻は T4-4 で導入した `emulator_set_wall_clock` 経由で注入可能にしておくとテストが書ける。日カウンタの桁あふれ（bit7）も忘れず計算。
**依存**: T7-1（不要なら T4-4 のみでも可）

---

### T7-4: キーボードショートカット

- [x] 完了

**目的**: ステート操作を BluePrint の「キーボードショートカットで操作」に沿って割り当てる。
**作るもの**: `src/app/input.odin`:
- F5=保存、F7=復元、F1-F4=スロット選択（`<ROM名>.state1` 〜 `.state4`、デフォルトスロット 1）
- 実行結果（"State saved to slot 1" 等）を stderr とウィンドウタイトルに表示
- ショートカット一覧を `bbl -h` に追記
**参照**: BluePrint.md「特徴」
**完了条件 (DoD)**: GUI でスロット切替・保存・復元が操作でき、フィードバックが表示される。
**検証方法**: `./bbl <ゲーム>` で F1-F7 操作（目視）。
**落とし穴**: 保存はメインループのフレーム境界で行う（フレーム途中の状態を書かない — run_frame の外でフラグ処理）。
**依存**: T7-2

---

### T7-5: 完全再現の統合検証

- [x] 完了

**目的**: フェーズ 7 のマイルストーン。
**作るもの**: 統合テスト `tests/savestate_test.odin`:
- テスト ROM（Blargg のいずれか）を N フレーム実行 → 保存 → さらに M フレーム → framebuffer ハッシュ記録 → 復元 → 同じ M フレーム → **ハッシュ完全一致**を確認（決定性テスト）
- 実ゲームでも目視確認（音の連続性含む）
**参照**: testing.md
**完了条件 (DoD)**: 決定性テスト PASS。実ゲームで save→load 後に音・映像・入力すべて正常（検証ログに記録）。
**検証方法**:
```sh
odin test tests -collection:bbl=src
./bbl <ゲーム>   # F5 → プレイ → F7
```
**落とし穴**: ハッシュ不一致の場合、保存漏れフィールドがある。二分探索的に「復元直後の全フィールド dump 比較」で漏れを特定する。
**依存**: T7-2, T7-4

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-12 T7-1 完了: `src/core/savestate.odin` 新規作成(マジック"BBLS"+バージョンu32+ROMグローバルチェックサム2B+本体、全項目リトルエンディアン)。本体サイズを`savestate_expected_size`で事前計算し書き込みバッファをちょうどのサイズで確保する方式(範囲外アクセスを構造的に防止)。CPU全レジスタ/ime/halted/halt_bug/ime_delay/stopped/illegal_opcode_hit、VRAM全2バンク、WRAM全8バンク、OAM、HRAM、IO、IE、パレットRAM、HDMA状態、double_speed、Timer内部状態、PPU状態(レジスタ+モード+dot+window_line+framebuffer)、Joypad、DMA、APU(ch毎のタイマー/LFSR/エンベロープ/スイープ、フレームシーケンサ位置、NRレジスタ生値、wave RAM)、MBC状態(unionタグ+中身、MBC3のRTC含む)、外部RAMを保存。オーディオリングバッファ(apu.ring*)とMooneye判定用デバッグフラグ(cpu.debug_break_on_ld_b_b/ld_b_b_hit)、シリアル出力キャプチャは意図的に除外(落とし穴欄のとおり)。`tests/savestate_test.odin`新規作成、write→write決定性テストと外部RAM込みのround-tripテストで検証: `odin test tests -collection:bbl=src` 310 tests 全パス(304→310、既存テストの後退無し)。
2026-07-12 T7-2 完了: savestate.odinの`savestate_read`は「マジック→バージョン→ROMチェックサム→本体サイズ充足」の順に検証し、いずれかで失敗したら emu へは一切書き込まず別々の`Load_Error`(.Bad_Magic/.Version_Mismatch/.Rom_Checksum_Mismatch/.Too_Small)を返す設計(全読み取りが本体サイズの事前一括チェックで保証されるため、一時Emulator+swapは不要。advisorでも「validate-before-mutateで十分」と確認済み)。`savestate_write`末尾に書き込みバイト数とサイズ計算の一致を検証する`assert`を追加(フォーマット変更時のサイズ計算更新漏れを即検出)。`src/app/statefile.odin`新規作成: `<ROM名>.state`(スロット2-4は`.state2`-`.state4`)の読み書きを`save_ram_write_atomic`/`save_ram_load`(saveram.odinの既存アトミック書き込み)で実装。`tests/statefile_test.odin`新規作成、パス導出・save/loadラウンドトリップ・破損データ別エラー・元状態無傷を検証: `odin test tests -collection:bbl=src` 315 tests 全パス(310→315)。
2026-07-12 T7-3 完了: `src/core/mbc.odin`に`mbc_export_rtc`/`mbc_import_rtc`を追加(MBC3のRTCライブレジスタ・ラッチ済み・ラッチ準備フラグ・基準UNIX時刻を単純に入出力するだけで、経過時間の加算自体はしない設計)。`src/app/saveram.odin`拡張: `<ROM名>.rtc`(マジック"BBLR"+バージョンu8+RTC5B+ラッチ済み5B+latch_prepared1B+基準UNIX時刻i64=24バイト固定)を`save_ram_write_atomic`で書き込む`rtc_save`/`rtc_load`、パス導出`rtc_path_for_rom`、壁時計取得`wall_clock_now`(core:time)を追加。`src/app/main.odin`を配線: ROM読み込み直後に.rtcがあれば`core.mbc_import_rtc`でインポートし、直後に`core.emulator_set_wall_clock`を呼んで既存のテスト済み`mbc3_advance_rtc`(DH bit6停止中は加算しない・512日での桁あふれ処理込み)に経過秒の反映を委譲する(advisor助言どおり「ロード済みロジックの再利用」)。.savの自動保存(アイドル60フレーム)と終了時に合わせて`save_rtc_now`(直前に壁時計を反映してから書き出し)を呼ぶことで、プロセスの生存期間中に経過した実時間もセッションをまたいで蓄積される。`tests/rtc_persist_test.odin`新規作成: .rtcファイルのラウンドトリップ・破損マジック拒否・DoD本体(1時間後を注入してのRTC進行)・停止ビット時の非進行を検証: `odin test tests -collection:bbl=src` 322 tests 全パス(315→322)。
2026-07-12 T7-4 完了: `src/app/input.odin`拡張: `Input_State`(state_slot、デフォルト1)と`input_handle_shortcut_key`(F1-F4=スロット選択、F5=保存要求、F7=復元要求を返す純粋関数、SDLウィンドウ/オーディオ非依存でテスト可能)を追加。`src/app/main.odin`のメインループのKEYDOWN処理内(=次の`emulator_run_frame`呼び出しより前、落とし穴欄の「run_frameの外でフラグ処理」を「イベント処理はrun_frame呼び出し前に一度だけ起きる」という既存のループ構造でそのまま満たす形)で`handle_shortcut_action`を呼び、`state_save`/`state_load`(T7-2のstatefile.odin)を実行。保存/復元はオーディオコールバックスレッドとの直列化のためSDL_Lock/UnlockAudioDeviceで挟む(T5-6の`audio_run_frame_locked`と同じ理由)。実行結果は`show_status`でstderr(`fmt.eprintln`)とウィンドウタイトル(新設の`video_set_title`)の両方に表示。`src/app/cli.odin`の`-h`使用法にキーボードショートカット一覧を追記。`tests/input_shortcut_test.odin`新規作成、スロット選択・保存/復元要求・キーリピート無視を検証: `odin test tests -collection:bbl=src` 328 tests 全パス(322→328)。**未確認**: 実際にSDLウィンドウでF1-F7を押してタイトルバー表示や保存/復元が目視で正しく動くかは確認できていない(画面を見る手段が無いため)。ビルド成功・`-h`出力目視・ショートカット判定ロジックの単体テストまでで代替した。
2026-07-12 T7-5 完了: `tests/savestate_test.odin`に`test_savestate_deterministic_replay_after_restore`を追加(フェーズ7のマイルストーン)。Blargg cpu_instrs個別テスト`01-special.gb`を使用: 事前にscratchpadでフレーム毎のframebufferハッシュを調査し(検証ログのこの行の直前のコミット作業で確認)、frame0-3は無地・frame4-8でタイトル文字が実際に描画される(=保存漏れフィールドがあれば検出できる「静止していない」区間)ことを確認した上でN=2(まだ無地の時点)で保存、M=6(frame2→8、画面が動いている区間)を「保存直後に1回実行してハッシュ記録」→「同じ保存データから復元してもう一度同じMフレームを実行」で比較し、完全一致(FNV-1a 64bit)を確認。テスト内に「区間内で実際に画面が変化していること」自体を検査するアサーションも追加し、advisor指摘の「静止画面を選ぶと何も検証しないテストになる」落とし穴を自己検出できるようにした。`odin test tests -collection:bbl=src` 329 tests 全パス(328→329)。フェーズ全体の検証コマンド(`odin test tests -collection:bbl=src`)は完全パス。**未確認(正直な申告)**: 「ゲーム中にF5保存→進める→F7復元→保存時点に完全に戻る」の目視確認、および実際の音の連続性の聴覚確認は本セッションでは実施できない(画面を見る/音を聴く手段が無いため)。自動化された決定性テスト(フレームバッファハッシュ完全一致)を最も重要な代替検証として実施し、市販ゲームの代わりにBlarggテストROMでのsave→load往復を追加の結合確認として使った(testing.md/タスク指示のとおり)。市販ゲームでの動作確認は未実施。
2026-07-12 T7-5 追加確認: advisor指摘(01-special.gbはDMGモード起動のため、パレットRAM・VRAMバンク1・WRAMバンク2-7・BCPS/OCPS等のCGB専用フィールドが常にデフォルト値のままで、書き込み/読み出しの順序ずれがあっても両writeが偶然一致して検出できない死角がある)を受け、`test_savestate_deterministic_replay_after_restore_cgb`を追加。cgb-acid2.gbc(Cgbモード起動をアサートで確認)を使い、同じ手順(scratchpadでのフレーム毎ハッシュ調査でframe0-12無地→frame13で変化開始→frame14で確定を確認した上でN=10・M=6でframe13の変化を跨ぐ区間を選定)で決定性を検証。`odin test tests -collection:bbl=src` 330 tests 全パス(329→330)。**残る未検証(inspection-onlyのまま)**: double_speedとHDMA状態は、これらを使いながら早期フレームでアニメーションするテストROM/ホームブリューが見つからなかったため、コードレビュー(write_bus_state/read_bus_stateへの網羅確認)のみで、実行テストでの往復検証はできていない。
