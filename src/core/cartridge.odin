package core

// カートリッジヘッダ解析(0x0134-0x014D)。BubiBoy Cartridge.fs のアルゴリズムを移植
// (references.md「BubiBoy ↔ BubiBoyLite モジュール対応表」)。
// このファイルはヘッダ解析のみを扱う。ROM/RAM/MBC 状態の実体は mbc.odin(T4-2 以降)。

HEADER_TITLE_START :: 0x0134
HEADER_TITLE_LEN :: 16
HEADER_CGB_FLAG_ADDR :: 0x0143
HEADER_TYPE_ADDR :: 0x0147
HEADER_ROM_SIZE_ADDR :: 0x0148
HEADER_RAM_SIZE_ADDR :: 0x0149
HEADER_MIN_LEN :: 0x0150 // ヘッダ全体(タイトル〜チェックサム)を読める最小サイズ

// MBC2 は 0x0149(RAM サイズコード)に関わらず常に内蔵 512x4bit RAM を持つ(落とし穴、T4-1)。
MBC2_INTERNAL_RAM_BYTES :: 512

Mbc_Kind :: enum {
	Rom_Only,
	Mbc1,
	Mbc2,
	Mbc3,
	Mbc5,
}

Cgb_Flag :: enum {
	Dmg_Only,
	Cgb_Enhanced,
	Cgb_Only,
}

// Cartridge_Parse_Error: core は panic しない方針(architecture.md「エラー処理」)。
// app 側はこの enum を見て「未対応カートリッジ (type=0xNN)」等のメッセージを表示する
// (Cartridge_Info.type_code に生の 0x0147 値を残しておく)。
Cartridge_Parse_Error :: enum {
	None,
	Header_Too_Small, // rom が HEADER_MIN_LEN バイト未満
	Unsupported_Type, // 0x0147 が ROM only/MBC1/2/3/5 以外(MBC6/7, HuC 系, MMM01 等)
	Unsupported_Rom_Size, // 0x0148 が既知の範囲外
	Unsupported_Ram_Size, // 0x0149 が既知の範囲外
	Rom_Smaller_Than_Header, // ファイルサイズがヘッダの申告する ROM サイズより小さい
}

Cartridge_Info :: struct {
	mbc_kind:    Mbc_Kind,
	rom_banks:   int,
	ram_size:    int, // バイト数。MBC2 は内蔵 512 バイト固定(0x0149 に頼らず種別で判定)
	has_battery: bool,
	has_rtc:     bool,
	cgb_flag:    Cgb_Flag,
	title:       string, // rom スライスを直接参照する借用文字列(コピーしない)
	type_code:   u8, // 0x0147 の生値。Unsupported_Type 時のエラー表示に使う
}

// cartridge_parse_header は ROM 全体のバイト列からヘッダを解析する。
// rom の所有権は呼び出し側に残る(title は rom を指す借用スライスなので、
// Cartridge_Info を使う間は rom を解放しないこと)。
cartridge_parse_header :: proc(rom: []u8) -> (info: Cartridge_Info, err: Cartridge_Parse_Error) {
	if len(rom) < HEADER_MIN_LEN {
		return {}, .Header_Too_Small
	}

	type_code := rom[HEADER_TYPE_ADDR]
	info.type_code = type_code

	kind, has_ram_flag, has_battery, has_rtc, kind_ok := classify_cartridge_type(type_code)
	if !kind_ok {
		return info, .Unsupported_Type
	}
	info.mbc_kind = kind
	info.has_battery = has_battery
	info.has_rtc = has_rtc

	rom_banks, rom_bytes, rom_size_ok := rom_size_from_code(rom[HEADER_ROM_SIZE_ADDR])
	if !rom_size_ok {
		return info, .Unsupported_Rom_Size
	}
	info.rom_banks = rom_banks

	ram_bytes, ram_size_ok := ram_size_from_code(rom[HEADER_RAM_SIZE_ADDR])
	if !ram_size_ok {
		return info, .Unsupported_Ram_Size
	}

	switch {
	case kind == .Mbc2:
		info.ram_size = MBC2_INTERNAL_RAM_BYTES
	case has_ram_flag:
		info.ram_size = ram_bytes
	case:
		info.ram_size = 0
	}

	if len(rom) < rom_bytes {
		return info, .Rom_Smaller_Than_Header
	}

	info.cgb_flag = classify_cgb_flag(rom[HEADER_CGB_FLAG_ADDR])
	info.title = parse_title(rom[HEADER_TITLE_START:HEADER_TITLE_START + HEADER_TITLE_LEN])

	return info, .None
}

// classify_cartridge_type は 0x0147 の値を分類する(references.md「カートリッジヘッダ早見表」)。
// has_ram は「ヘッダの RAM サイズコードに従って外部 RAM を持つか」、MBC2 の内蔵 RAM は含まない
// (呼び出し側で種別により上書きする)。
@(private)
classify_cartridge_type :: proc(
	code: u8,
) -> (
	kind: Mbc_Kind,
	has_ram: bool,
	has_battery: bool,
	has_rtc: bool,
	ok: bool,
) {
	switch code {
	case 0x00:
		return .Rom_Only, false, false, false, true
	case 0x01:
		return .Mbc1, false, false, false, true
	case 0x02:
		return .Mbc1, true, false, false, true
	case 0x03:
		return .Mbc1, true, true, false, true
	case 0x05:
		return .Mbc2, false, false, false, true
	case 0x06:
		return .Mbc2, false, true, false, true
	case 0x0F: // MBC3+TIMER+BATTERY(RAM無し)
		return .Mbc3, false, true, true, true
	case 0x10: // MBC3+TIMER+RAM+BATTERY
		return .Mbc3, true, true, true, true
	case 0x11:
		return .Mbc3, false, false, false, true
	case 0x12:
		return .Mbc3, true, false, false, true
	case 0x13:
		return .Mbc3, true, true, false, true
	case 0x19:
		return .Mbc5, false, false, false, true
	case 0x1A:
		return .Mbc5, true, false, false, true
	case 0x1B:
		return .Mbc5, true, true, false, true
	case 0x1C: // MBC5+RUMBLE(RAM無し。振動機能自体は未実装スコープ外)
		return .Mbc5, false, false, false, true
	case 0x1D: // MBC5+RUMBLE+RAM
		return .Mbc5, true, false, false, true
	case 0x1E: // MBC5+RUMBLE+RAM+BATTERY
		return .Mbc5, true, true, false, true
	case:
		// MBC6/7, MMM01, HuC1/HuC3, ポケットカメラ等はスコープ外(architecture.md「スコープ外」)。
		return .Rom_Only, false, false, false, false
	}
}

// rom_size_from_code は 0x0148 を解釈する。ROM サイズ = 32KiB << code(コード 0x00-0x08 のみ既知)。
@(private)
rom_size_from_code :: proc(code: u8) -> (banks: int, bytes: int, ok: bool) {
	if code > 0x08 {
		return 0, 0, false
	}
	banks = 2 << uint(code) // 16KiB バンク数
	bytes = banks * 16 * 1024
	return banks, bytes, true
}

// ram_size_from_code は 0x0149 を解釈する。コード 0x01(未使用として予約)は既知の範囲外扱い。
@(private)
ram_size_from_code :: proc(code: u8) -> (bytes: int, ok: bool) {
	switch code {
	case 0x00:
		return 0, true
	case 0x02:
		return 8 * 1024, true
	case 0x03:
		return 32 * 1024, true
	case 0x04:
		return 128 * 1024, true
	case 0x05:
		return 64 * 1024, true
	case:
		return 0, false
	}
}

@(private)
classify_cgb_flag :: proc(code: u8) -> Cgb_Flag {
	switch code {
	case 0x80:
		return .Cgb_Enhanced
	case 0xC0:
		return .Cgb_Only
	case:
		return .Dmg_Only
	}
}

// parse_title は 0x0134-0x0143 の16バイトを最初の 0x00 で打ち切って文字列化する。
// 返り値は bytes を指す借用スライス(コピーしない。呼び出し側の rom 所有権規約に従う)。
@(private)
parse_title :: proc(bytes: []u8) -> string {
	length := 0
	for b in bytes {
		if b == 0 {
			break
		}
		length += 1
	}
	return string(bytes[:length])
}
