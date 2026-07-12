package main

import "core:fmt"
import "core:strings"
import core "bbl:core"

// statefile.odin: セーブステート(.state)の読み書き(T7-2)。
// BluePrint/CLAUDE.md「設定・セーブファイルの配置ルール」: セーブ/ステートファイルは
// 実行中のROMファイルと同じ場所がデフォルト(saveram.odin と同じ規約)。
// アトミック書き込みは saveram.odin の save_ram_write_atomic をそのまま再利用する
// (T7-2「.savと同じアトミック書き込みを流用」)。

// state_path_for_rom は ROM パスの拡張子を .state に置き換えたパスを返す。
// slot が 1 以外のときは ".state1"〜".state4" のように末尾に数字を付ける(T7-4のスロット機能)。
// save_ram_path_for_rom と同じ「パス区切りより後ろの最後の"."だけを拡張子とみなす」規則に従う。
state_path_for_rom :: proc(rom_path: string, slot: int) -> string {
	last_slash := strings.last_index(rom_path, "/")
	last_backslash := strings.last_index(rom_path, "\\")
	last_sep := max(last_slash, last_backslash)
	last_dot := strings.last_index(rom_path, ".")

	base: string
	if last_dot > last_sep {
		base = rom_path[:last_dot]
	} else {
		base = rom_path
	}

	if slot == 1 {
		return fmt.tprintf("%s.state", base)
	}
	return fmt.tprintf("%s.state%d", base, slot)
}

// state_save は emu の現在の状態をシリアライズし、rom_path から導出した .state パスへ
// アトミック書き込みする。成功時 ok=true。
state_save :: proc(emu: ^core.Emulator, rom_path: string, slot: int) -> bool {
	data := core.savestate_write(emu)
	defer delete(data)
	path := state_path_for_rom(rom_path, slot)
	return save_ram_write_atomic(path, data)
}

// state_load は rom_path から導出した .state パスを読み込み、emu へ復元する。
// ファイルが存在しない、または savestate_read がエラーを返した場合は emu を変更せず
// core.Load_Error を返す(呼び出し側でメッセージ表示に使う)。ファイル未存在は独立した
// ok=false で表現する(T4-6の save_ram_load と同じ「無ければ通常運転」の規約)。
state_load :: proc(emu: ^core.Emulator, rom_path: string, slot: int) -> (err: core.Load_Error, ok: bool) {
	path := state_path_for_rom(rom_path, slot)
	data, load_ok := save_ram_load(path)
	if !load_ok {
		return .None, false
	}
	defer delete(data)
	err = core.savestate_read(emu, data)
	return err, true
}

// state_load_error_message は core.Load_Error を app 側表示用の文字列に変換する
// (cartridge_error_message と同じ位置づけ)。
state_load_error_message :: proc(err: core.Load_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Bad_Magic:
		return "ステートファイルの形式が不正です(マジックバイト不一致)"
	case .Version_Mismatch:
		return "ステートファイルのバージョンが異なります"
	case .Rom_Checksum_Mismatch:
		return "ステートファイルが現在のROMと一致しません(ROMチェックサム不一致)"
	case .Too_Small:
		return "ステートファイルが壊れています(サイズ不足)"
	}
	return ""
}
