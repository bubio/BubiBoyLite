package main

import "core:fmt"
import "core:os"
import "core:strings"

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
