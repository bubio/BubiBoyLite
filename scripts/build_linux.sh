#!/bin/sh
set -e

# BubiBoyLite Linux ビルドスクリプト。POSIX sh のみ使用（bash 拡張禁止）。
# CI もこのスクリプトを呼ぶ（scripts 以外にビルドコマンドを二重管理しない）。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if ! command -v odin >/dev/null 2>&1; then
	echo "Error: odin コマンドが見つかりません。'mise install' を実行してください。"
	exit 1
fi

DEBUG=0
RUN_TEST=0
RELEASE=0

for arg in "$@"; do
	case "$arg" in
	--debug)
		DEBUG=1
		;;
	--test)
		RUN_TEST=1
		;;
	--release)
		RELEASE=1
		;;
	*)
		echo "Error: 不明な引数です: $arg"
		exit 1
		;;
	esac
done

# odin のフラグは set -- で位置パラメータに積む（$VAR の素朴な展開は
# -extra-linker-flags:"..." のように内部に空白を含む値を壊すため使わない）。
set -- -collection:bbl=src -out:bbl

if [ "$DEBUG" = "1" ]; then
	set -- "$@" -debug
else
	set -- "$@" -o:speed
fi

# 配布用も含め SDL2 はシステムにインストール済みのもの（`apt install libsdl2-dev` 等）に
# 動的リンクする（2026-07-16、ユーザー承認により静的リンク方針から変更。経緯は
# docs/dev/phases/phase-10-cicd.md 参照）。vendor:sdl2 の foreign import が渡す暗黙の
# `-lSDL2` は ld の既定検索パス（`/usr/lib/<triple>` 等）で自然に解決されるため、
# 追加のリンカフラグは不要。

echo "=== BubiBoyLite Linux build ==="
echo "odin build src/app $*"
odin build src/app "$@"

if [ "$RUN_TEST" = "1" ]; then
	echo "=== odin test tests ==="
	odin test tests -collection:bbl=src
fi

echo "Build complete: $PROJECT_ROOT/bbl"
