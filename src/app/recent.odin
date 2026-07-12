package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// recent.odin: 最近使ったファイル履歴(T9-3)。
// BluePrint「--recent : 最近使ったファイルを表示して選択できる。ROMファイルの指定がある場合は、
// そちらを優先」。履歴ファイルは設定ファイル(bbl.ini)と同じ場所に置く(config_dir_path を共有、
// CLAUDE.md「設定ファイルの配置ルール」に準拠)。
//
// フォーマット: 1行1パス(絶対パス)、最新が先頭、最大 RECENT_MAX_ENTRIES 件、
// 重複するパスは既存分を消して先頭へ移動する。
//
// このファイルの関数は「純粋なリスト操作(recent_parse/recent_render/recent_add)」と
// 「ファイルI/O(recent_load/recent_save)」を分離してある(config.odin の config_parse_ini と
// 同じ流儀。単体テストしやすくするため)。

RECENT_FILE_NAME :: "bbl_recent.txt"
RECENT_MAX_ENTRIES :: 20

// recent_file_path は履歴ファイルのフルパスを返す(config_dir は config_dir_path() の戻り値)。
recent_file_path :: proc(config_dir: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/%s", config_dir, RECENT_FILE_NAME, allocator = allocator)
}

// recent_parse は履歴ファイルのテキストを1行1パスとして解釈する純粋関数。空行は無視する。
// 戻り値の各文字列は所有権付き(呼び出し側が recent_list_delete で解放する)。
recent_parse :: proc(text: string, allocator := context.allocator) -> []string {
	lines := strings.split_lines(text, context.temp_allocator)
	result := make([dynamic]string, 0, len(lines), allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		append(&result, strings.clone(trimmed, allocator))
	}
	return result[:]
}

// recent_render は recent_parse の逆(パス一覧 → 1行1パスのテキスト)。純粋関数。
recent_render :: proc(list: []string, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	for p in list {
		strings.write_string(&b, p)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// recent_add は new_path を list の先頭へ追加した新しいリストを返す純粋関数
// (list 自体は変更しない、呼び出し側が別途解放すること)。
// 重複除去(既存の同じパスは除いてから先頭に置く = 実質「先頭へ移動」)、
// 上限 RECENT_MAX_ENTRIES 件を超えた分は切り捨てる。
recent_add :: proc(list: []string, new_path: string, allocator := context.allocator) -> []string {
	result := make([dynamic]string, 0, min(len(list) + 1, RECENT_MAX_ENTRIES), allocator)
	append(&result, strings.clone(new_path, allocator))
	for p in list {
		if len(result) >= RECENT_MAX_ENTRIES {
			break
		}
		if p == new_path {
			continue // 重複は除去(直前で先頭に追加済み)
		}
		append(&result, strings.clone(p, allocator))
	}
	return result[:]
}

// recent_filter_existing は list のうち実在するパスだけを残した新しいリストを返す純粋寄りの
// 関数(os.exists のみファイルI/O)。表示直前に呼ぶ想定(T9-3「存在しなくなったパスは表示時に
// スキップ」。履歴ファイル自体からは削除しない)。
recent_filter_existing :: proc(list: []string, allocator := context.allocator) -> []string {
	result := make([dynamic]string, 0, len(list), allocator)
	for p in list {
		if os.exists(p) {
			append(&result, strings.clone(p, allocator))
		}
	}
	return result[:]
}

recent_list_delete :: proc(list: []string) {
	for p in list {
		delete(p)
	}
	delete(list)
}

// recent_load は path を読み込んで recent_parse する。ファイルが無ければ空リストを返す
// (T4-6 の save_ram_load 等と同じ「無ければ通常運転」規約)。
recent_load :: proc(path: string) -> []string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil
	}
	defer delete(data)
	return recent_parse(string(data))
}

// recent_save は list を path へアトミック書き込みする(saveram.odin の save_ram_write_atomic
// を再利用、T9-3落とし穴「実ユーザー名を含むパスをログや画面に出すのは可だが、
// リポジトリのテストフィクスチャに残さない」を守るため、書き込み先は常に呼び出し側が
// config_dir_path() 等から渡す実行時パスであり、リポジトリには残らない)。
recent_save :: proc(path: string, list: []string) -> bool {
	content := recent_render(list)
	defer delete(content)
	return save_ram_write_atomic(path, transmute([]u8)content)
}

// filepath_abs_or_clone は rom_path を絶対パス化する。失敗時(稀: カレントディレクトリの
// 取得に失敗する等)は rom_path をそのまま clone して返す(履歴を諦めるより相対パスのまま
// 記録する方がまし、という判断)。戻り値は常に所有権付き。
@(private = "file")
filepath_abs_or_clone :: proc(rom_path: string) -> string {
	abs_path, err := filepath.abs(rom_path)
	if err != nil {
		return strings.clone(rom_path)
	}
	return abs_path
}

// recent_record_launch は ROM 起動成功のたびに main.odin から呼ぶ(T9-3「ROM起動成功のたびに
// 更新」)。rom_path は絶対パスへ変換してから記録する(T9-3落とし穴「履歴のパスは絶対パスで
// 保存」)。config_dir の解決に失敗している場合は何もしない(呼び出し側で判定済みの前提)。
recent_record_launch :: proc(config_dir: string, rom_path: string) -> bool {
	abs_path := filepath_abs_or_clone(rom_path)
	defer delete(abs_path)

	path := recent_file_path(config_dir)
	defer delete(path)

	old := recent_load(path)
	defer recent_list_delete(old)

	updated := recent_add(old, abs_path)
	defer recent_list_delete(updated)

	return recent_save(path, updated)
}
