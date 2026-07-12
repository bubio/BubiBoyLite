package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// saveram.odin: バッテリーバックアップRAM(.sav)の読み書き(T4-6)。
// BluePrint/CLAUDE.md「設定・セーブファイルの配置ルール」: セーブファイルは実行中のROM
// ファイルと同じ場所がデフォルト。ここではデフォルト配置(拡張子だけ.savに置き換え)のみを
// 実装する(設定ファイルによる変更はフェーズ8)。
// アトミック書き込みは BubiBoy SaveRam.fs の writeBytesWithBackup 方式を移植:
// 一時ファイルに書く → 既存.savを.sav.bakにリネーム → 一時ファイルを.savにリネーム。

// save_ram_path_for_rom は ROM パスの拡張子を .sav に置き換えたパスを返す
// (例: "game.gbc" -> "game.sav")。パス区切り文字より後ろの最後の "." だけを拡張子とみなす
// (ディレクトリ名に "." が含まれていても誤動作しないため)。
save_ram_path_for_rom :: proc(rom_path: string) -> string {
	last_slash := strings.last_index(rom_path, "/")
	last_backslash := strings.last_index(rom_path, "\\")
	last_sep := max(last_slash, last_backslash)
	last_dot := strings.last_index(rom_path, ".")

	if last_dot > last_sep {
		return fmt.tprintf("%s.sav", rom_path[:last_dot])
	}
	return fmt.tprintf("%s.sav", rom_path)
}

// save_ram_write_atomic は data を save_path へアトミックに書き込む(T4-6の落とし穴対策:
// 書き込み中のクラッシュで既存セーブを壊さないため)。
// 手順: 一時ファイルに書く → 既存の save_path があれば .bak にリネーム(退避)
// → 一時ファイルを save_path にリネーム。バックアップへのリネームに失敗しても
// (例: .bak が存在せず初回セーブ)本体の保存は続行する。
save_ram_write_atomic :: proc(save_path: string, data: []u8) -> bool {
	tmp_path := fmt.tprintf("%s.tmp", save_path)
	if err := os.write_entire_file(tmp_path, data); err != nil {
		fmt.eprintfln("saveram: 一時ファイルへの書き込みに失敗: %s (%v)", tmp_path, err)
		return false
	}

	if os.exists(save_path) {
		bak_path := fmt.tprintf("%s.bak", save_path)
		_ = os.remove(bak_path) // 既存の.bakがあれば上書きのため先に削除(renameの上書き挙動はOS依存なので明示的に消す)
		if err := os.rename(save_path, bak_path); err != nil {
			fmt.eprintfln("saveram: 既存セーブのバックアップに失敗(続行): %s -> %s (%v)", save_path, bak_path, err)
		}
	}

	if err := os.rename(tmp_path, save_path); err != nil {
		fmt.eprintfln("saveram: 一時ファイルのリネームに失敗: %s -> %s (%v)", tmp_path, save_path, err)
		return false
	}
	return true
}

// save_ram_load は save_path が存在すれば内容を読み込む。存在しなければ ok=false
// (「セーブファイルが無い」は通常の初回起動であってエラーではない)。
save_ram_load :: proc(save_path: string) -> (data: []u8, ok: bool) {
	if !os.exists(save_path) {
		return nil, false
	}
	d, err := os.read_entire_file(save_path, context.allocator)
	if err != nil {
		fmt.eprintfln("saveram: セーブファイルの読み込みに失敗: %s (%v)", save_path, err)
		return nil, false
	}
	return d, true
}

// --- RTC永続化(.rtc、T7-3) ---
// MBC3 の RTC(core.emulator_set_wall_clock 経由で供給する方式、T4-4)をプロセス終了を
// またいで進めるための固定24バイトフォーマット:
// マジック"BBLR"(4B) + バージョンu8(=1) + RTCレジスタ5B(S/M/H/DL/DH) + ラッチ済み5B +
// latch_prepared 1B + 基準UNIX時刻i64(8B、リトルエンディアン) = 24バイト。
// .sav と同じアトミック書き込み(save_ram_write_atomic)を再利用する。

RTC_MAGIC :: "BBLR"
RTC_FORMAT_VERSION :: u8(1)
RTC_FILE_SIZE :: 4 + 1 + 5 + 5 + 1 + 8 // 24

// Rtc_Snapshot は core.mbc_export_rtc/mbc_import_rtc とやり取りする値をそのまま保持する
// (core側のMbc3_State型をapp側に持ち込まないための橋渡し、statefile.odinのLoad_Errorと同じ位置づけ)。
Rtc_Snapshot :: struct {
	rtc:            [5]u8,
	latched_rtc:    [5]u8,
	latch_prepared: bool,
	rtc_base_unix:  i64,
}

// rtc_path_for_rom は ROM パスの拡張子を .rtc に置き換えたパスを返す
// (save_ram_path_for_rom と同じ「最後の"."だけを拡張子とみなす」規則)。
rtc_path_for_rom :: proc(rom_path: string) -> string {
	last_slash := strings.last_index(rom_path, "/")
	last_backslash := strings.last_index(rom_path, "\\")
	last_sep := max(last_slash, last_backslash)
	last_dot := strings.last_index(rom_path, ".")

	if last_dot > last_sep {
		return fmt.tprintf("%s.rtc", rom_path[:last_dot])
	}
	return fmt.tprintf("%s.rtc", rom_path)
}

@(private = "file")
rtc_encode :: proc(s: Rtc_Snapshot) -> [RTC_FILE_SIZE]u8 {
	buf: [RTC_FILE_SIZE]u8
	copy(buf[0:4], transmute([]u8)string(RTC_MAGIC))
	buf[4] = RTC_FORMAT_VERSION
	for i in 0 ..< 5 {
		buf[5 + i] = s.rtc[i]
		buf[10 + i] = s.latched_rtc[i]
	}
	buf[15] = s.latch_prepared ? 1 : 0
	v := u64(s.rtc_base_unix)
	for i in 0 ..< 8 {
		buf[16 + i] = u8(v >> uint(i * 8))
	}
	return buf
}

@(private = "file")
rtc_decode :: proc(data: []u8) -> (s: Rtc_Snapshot, ok: bool) {
	if len(data) != RTC_FILE_SIZE {
		return {}, false
	}
	if string(data[0:4]) != RTC_MAGIC {
		return {}, false
	}
	if data[4] != RTC_FORMAT_VERSION {
		return {}, false
	}
	copy(s.rtc[:], data[5:10])
	copy(s.latched_rtc[:], data[10:15])
	s.latch_prepared = data[15] != 0
	v: u64 = 0
	for i in 0 ..< 8 {
		v |= u64(data[16 + i]) << uint(i * 8)
	}
	s.rtc_base_unix = i64(v)
	return s, true
}

// rtc_save は s を rtc_path へアトミック書き込みする。
rtc_save :: proc(rtc_path: string, s: Rtc_Snapshot) -> bool {
	buf := rtc_encode(s)
	return save_ram_write_atomic(rtc_path, buf[:])
}

// rtc_load は rtc_path が存在し、マジック/バージョンが一致すれば内容を読み込む。
// 存在しない、または壊れている(マジック不一致・バージョン不一致・サイズ不一致)場合は
// ok=false (「.rtcが無い」は初回起動であって停止すべきエラーではない。壊れている場合も
// 「RTCは0から」に倒すだけで致命的ではないため、ここでは詳細なエラー種別を区別しない)。
rtc_load :: proc(rtc_path: string) -> (s: Rtc_Snapshot, ok: bool) {
	data, load_ok := save_ram_load(rtc_path)
	if !load_ok {
		return {}, false
	}
	defer delete(data)
	return rtc_decode(data)
}

// wall_clock_now は core.emulator_set_wall_clock へ供給する現在のUNIX秒を返す
// (core は時計を直接読まない方針(architecture.md)なので、壁時計の取得はここapp側の責務)。
wall_clock_now :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}
