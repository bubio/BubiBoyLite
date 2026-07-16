#!/bin/bash
set -e

# BubiBoyLite macOS ビルドスクリプト。
# CI もこのスクリプトを呼ぶ（scripts 以外にビルドコマンドを二重管理しない）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

if [ "$RELEASE" = "1" ]; then
	# 配布用ビルド。SDL2 はシステムにインストール済みのもの（`brew install sdl2`）に
	# 動的リンクする（2026-07-16、ユーザー承認により静的リンク方針から変更。経緯は
	# docs/dev/phases/phase-10-cicd.md 参照）。vendor:sdl2 の foreign import が渡す
	# 暗黙の `-lSDL2` は、odin が既定で追加する `-L/opt/homebrew/lib -L/usr/local/lib`
	# で自然に解決されるため、追加のリンカフラグは不要（実機確認済み）。
	MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.5}"
	export MACOSX_DEPLOYMENT_TARGET

	# odin のデフォルトは -minimum-os-version:11.0.0 で、指定しないとリンカが
	# ホストの OS バージョンをそのまま LC_BUILD_VERSION の minos に埋め込んでしまう
	# （実機確認: 指定なしでビルドすると minos がビルドホストの OS バージョンになった）。
	# BluePrint の macOS 13.5+ 要件を満たすため明示する。
	set -- "$@" "-minimum-os-version:$MACOSX_DEPLOYMENT_TARGET"
fi

echo "=== BubiBoyLite macOS build ==="
echo "odin build src/app $*"
odin build src/app "$@"

if [ "$RUN_TEST" = "1" ]; then
	echo "=== odin test tests ==="
	odin test tests -collection:bbl=src
fi

echo "Build complete: $PROJECT_ROOT/bbl"
