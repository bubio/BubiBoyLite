#!/bin/sh
set -e

# tests/roms/ にテスト ROM (Blargg / Mooneye / acid2 など) を配置するスクリプト。
# ライセンス上、テスト ROM をリポジトリにコミットしないため CI・ローカルの両方で
# このスクリプトを通して都度取得する想定（tests/roms/ は .gitignore 対象）。
# 再実行しても安全（取得済みファイルはスキップ）。
#
# フェーズ1で実装したのは Blargg (cpu_instrs, instr_timing) のみ。
# Mooneye はフェーズ2 (T2-6) で追加。acid2 は該当フェーズ (3, 6) で追加する。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
ROMS_DIR="$PROJECT_ROOT/tests/roms"
BLARGG_DIR="$ROMS_DIR/blargg"
MOONEYE_DIR="$ROMS_DIR/mooneye"

# 実際のユーザー名をスクリプトに残さないため $HOME 経由で表現する(CLAUDE.md の注意事項)。
LOCAL_MOONEYE_SRC="$HOME/dev/_Emu/BubiBoy/tests/BubiBoy.TestRoms/roms/mooneye"

# testing.md: retrio/gb-test-roms をコミット固定で取得する。
BLARGG_COMMIT="c240dd7d700e5c0b00a7bbba52b53e4ee67b5f15"
BLARGG_BASE_URL="https://raw.githubusercontent.com/retrio/gb-test-roms/$BLARGG_COMMIT"

mkdir -p "$BLARGG_DIR/cpu_instrs/individual" "$BLARGG_DIR/instr_timing"

fetch() {
	# fetch <remote-relative-path> <local-path>
	remote_path="$1"
	local_path="$2"

	if [ -f "$local_path" ]; then
		echo "fetch_test_roms.sh: 取得済み、スキップ: $local_path"
		return 0
	fi

	echo "fetch_test_roms.sh: 取得中: $remote_path"
	tmp_path="$local_path.tmp"
	# ファイル名にスペースを含むものがあるため URL エンコードする。
	encoded_path=$(printf '%s' "$remote_path" | sed 's/ /%20/g')
	if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp_path" "$BLARGG_BASE_URL/$encoded_path"; then
		rm -f "$tmp_path"
		echo "fetch_test_roms.sh: 取得失敗: $remote_path" >&2
		return 1
	fi
	mv "$tmp_path" "$local_path"
}

# cpu_instrs 個別 ROM（ROM-only、フェーズ1でパスさせる対象）
fetch "cpu_instrs/individual/01-special.gb" "$BLARGG_DIR/cpu_instrs/individual/01-special.gb"
fetch "cpu_instrs/individual/02-interrupts.gb" "$BLARGG_DIR/cpu_instrs/individual/02-interrupts.gb"
fetch "cpu_instrs/individual/03-op sp,hl.gb" "$BLARGG_DIR/cpu_instrs/individual/03-op sp,hl.gb"
fetch "cpu_instrs/individual/04-op r,imm.gb" "$BLARGG_DIR/cpu_instrs/individual/04-op r,imm.gb"
fetch "cpu_instrs/individual/05-op rp.gb" "$BLARGG_DIR/cpu_instrs/individual/05-op rp.gb"
fetch "cpu_instrs/individual/06-ld r,r.gb" "$BLARGG_DIR/cpu_instrs/individual/06-ld r,r.gb"
fetch "cpu_instrs/individual/07-jr,jp,call,ret,rst.gb" "$BLARGG_DIR/cpu_instrs/individual/07-jr,jp,call,ret,rst.gb"
fetch "cpu_instrs/individual/08-misc instrs.gb" "$BLARGG_DIR/cpu_instrs/individual/08-misc instrs.gb"
fetch "cpu_instrs/individual/09-op r,r.gb" "$BLARGG_DIR/cpu_instrs/individual/09-op r,r.gb"
fetch "cpu_instrs/individual/10-bit ops.gb" "$BLARGG_DIR/cpu_instrs/individual/10-bit ops.gb"
fetch "cpu_instrs/individual/11-op a,(hl).gb" "$BLARGG_DIR/cpu_instrs/individual/11-op a,(hl).gb"

# cpu_instrs 統合版（MBC1 が必要。フェーズ4まで許可リストに残す）
fetch "cpu_instrs/cpu_instrs.gb" "$BLARGG_DIR/cpu_instrs/cpu_instrs.gb"

# instr_timing（フェーズ1でパスさせる対象。DIV の最小実装が必要）
fetch "instr_timing/instr_timing.gb" "$BLARGG_DIR/instr_timing/instr_timing.gb"

# --- Mooneye acceptance (T2-6) ---
# testing.md: 「~/dev/_Emu/BubiBoy/tests/BubiBoy.TestRoms/roms/mooneye/ からコピー。
# 無ければ Gekkio の mooneye-test-suite リリースから」が原則の取得順。
# 2026-07 時点で Gekkio/mooneye-test-suite には GitHub Release が存在しない
# (ビルド済み ROM を配布していない。ソースからのアセンブルが必要)。
# そのため未取得分は c-sp/game-boy-test-roms のタグ付きリリース(mooneye-test-suite を
# ビルド済みで同梱する第三者アグリゲータ、MIT 系)から取得する。この乖離は
# docs/dev/phases/phase-02-timing.md の検証ログに理由を記録済み。
MOONEYE_FALLBACK_ZIP_URL="https://github.com/c-sp/game-boy-test-roms/releases/download/v7.0/game-boy-test-roms-v7.0.zip"
MOONEYE_FALLBACK_ZIP_CACHE="$ROMS_DIR/.cache/game-boy-test-roms-v7.0.zip"
MOONEYE_FALLBACK_ZIP_READY=0

ensure_mooneye_fallback_zip() {
	if [ "$MOONEYE_FALLBACK_ZIP_READY" = "1" ]; then
		return 0
	fi
	if [ -f "$MOONEYE_FALLBACK_ZIP_CACHE" ]; then
		MOONEYE_FALLBACK_ZIP_READY=1
		return 0
	fi
	mkdir -p "$(dirname "$MOONEYE_FALLBACK_ZIP_CACHE")"
	echo "fetch_test_roms.sh: Mooneye フォールバック zip を取得中: $MOONEYE_FALLBACK_ZIP_URL"
	tmp_zip="$MOONEYE_FALLBACK_ZIP_CACHE.tmp"
	if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp_zip" "$MOONEYE_FALLBACK_ZIP_URL"; then
		rm -f "$tmp_zip"
		echo "fetch_test_roms.sh: Mooneye フォールバック zip の取得失敗" >&2
		return 1
	fi
	mv "$tmp_zip" "$MOONEYE_FALLBACK_ZIP_CACHE"
	MOONEYE_FALLBACK_ZIP_READY=1
}

fetch_mooneye() {
	# fetch_mooneye <acceptance/以下の相対パス、例: acceptance/timer/tim00.gb>
	relative_path="$1"
	local_path="$MOONEYE_DIR/$relative_path"

	if [ -f "$local_path" ]; then
		echo "fetch_test_roms.sh: 取得済み、スキップ: $local_path"
		return 0
	fi

	mkdir -p "$(dirname "$local_path")"

	if [ -f "$LOCAL_MOONEYE_SRC/$relative_path" ]; then
		echo "fetch_test_roms.sh: ローカルコピー元から取得: $relative_path"
		cp "$LOCAL_MOONEYE_SRC/$relative_path" "$local_path"
		return 0
	fi

	if ! ensure_mooneye_fallback_zip; then
		echo "fetch_test_roms.sh: 取得失敗(ローカルコピー元・フォールバック zip 共になし): $relative_path" >&2
		return 1
	fi

	tmp_path="$local_path.tmp"
	if ! unzip -p "$MOONEYE_FALLBACK_ZIP_CACHE" "mooneye-test-suite/$relative_path" >"$tmp_path" 2>/dev/null || [ ! -s "$tmp_path" ]; then
		rm -f "$tmp_path"
		echo "fetch_test_roms.sh: フォールバック zip 内に見つからない: $relative_path" >&2
		return 1
	fi
	mv "$tmp_path" "$local_path"
	echo "fetch_test_roms.sh: フォールバック zip から取得: $relative_path"
}

# timer/ 全13本(T2-3/T2-7 の対象)
fetch_mooneye "acceptance/timer/div_write.gb"
fetch_mooneye "acceptance/timer/rapid_toggle.gb"
fetch_mooneye "acceptance/timer/tim00.gb"
fetch_mooneye "acceptance/timer/tim00_div_trigger.gb"
fetch_mooneye "acceptance/timer/tim01.gb"
fetch_mooneye "acceptance/timer/tim01_div_trigger.gb"
fetch_mooneye "acceptance/timer/tim10.gb"
fetch_mooneye "acceptance/timer/tim10_div_trigger.gb"
fetch_mooneye "acceptance/timer/tim11.gb"
fetch_mooneye "acceptance/timer/tim11_div_trigger.gb"
fetch_mooneye "acceptance/timer/tima_reload.gb"
fetch_mooneye "acceptance/timer/tima_write_reloading.gb"
fetch_mooneye "acceptance/timer/tma_write_reloading.gb"

# intr 系(T2-1/T2-2/T2-7 の対象)
fetch_mooneye "acceptance/interrupts/ie_push.gb"
fetch_mooneye "acceptance/if_ie_registers.gb"
fetch_mooneye "acceptance/intr_timing.gb"
fetch_mooneye "acceptance/rapid_di_ei.gb"
fetch_mooneye "acceptance/ei_timing.gb"

# halt 系(T2-2/T2-7 の対象)
fetch_mooneye "acceptance/halt_ime0_ei.gb"
fetch_mooneye "acceptance/halt_ime0_nointr_timing.gb"
fetch_mooneye "acceptance/halt_ime1_timing.gb"

# oam_dma 系(T2-5/T2-7 の対象)
fetch_mooneye "acceptance/oam_dma/basic.gb"
fetch_mooneye "acceptance/oam_dma/reg_read.gb"
fetch_mooneye "acceptance/oam_dma_start.gb"

echo "fetch_test_roms.sh: 完了。配置先: $ROMS_DIR"
exit 0
