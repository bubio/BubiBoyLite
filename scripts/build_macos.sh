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
	# 配布用: SDL2 を静的リンクする（architecture.md「開発=動的/配布=静的」の二段構え）。
	ARCH="$(uname -m)"
	case "$ARCH" in
	arm64 | x86_64) ;;
	*)
		echo "Error: --release は arm64/x86_64 のみ対応です（検出: $ARCH）"
		exit 1
		;;
	esac

	MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.5}"
	export MACOSX_DEPLOYMENT_TARGET

	"$SCRIPT_DIR/build_sdl2_static.sh" macos "$ARCH" \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
		-DCMAKE_OSX_ARCHITECTURES="$ARCH"

	SDL2_LIB="$PROJECT_ROOT/build/sdl2/macos-$ARCH/lib/libSDL2.a"
	if [ ! -f "$SDL2_LIB" ]; then
		echo "Error: 静的 SDL2 のビルドに失敗しました: $SDL2_LIB が見つかりません"
		exit 1
	fi

	# force_load で libSDL2.a のシンボルを全て取り込み、dead_strip_dylibs で
	# vendor:sdl2 の foreign import が要求する -lSDL2（動的解決）由来の未使用
	# dylib 参照を除去する。これにより system:SDL2 の import 文はそのままに
	# リンク先だけ静的ライブラリへ差し替えられる（architecture.md 参照）。
	EXTRA_LINKER_FLAGS="-Wl,-force_load,$SDL2_LIB -Wl,-dead_strip_dylibs"
	EXTRA_LINKER_FLAGS="$EXTRA_LINKER_FLAGS -framework CoreVideo -framework Cocoa -framework IOKit"
	EXTRA_LINKER_FLAGS="$EXTRA_LINKER_FLAGS -framework ForceFeedback -framework Carbon -framework CoreAudio"
	EXTRA_LINKER_FLAGS="$EXTRA_LINKER_FLAGS -framework AudioToolbox -framework AVFoundation -framework Foundation"
	EXTRA_LINKER_FLAGS="$EXTRA_LINKER_FLAGS -weak_framework GameController -weak_framework Metal"
	EXTRA_LINKER_FLAGS="$EXTRA_LINKER_FLAGS -weak_framework QuartzCore -weak_framework CoreHaptics"

	set -- "$@" "-extra-linker-flags:$EXTRA_LINKER_FLAGS"
fi

echo "=== BubiBoyLite macOS build ==="
echo "odin build src/app $*"
odin build src/app "$@"

if [ "$RUN_TEST" = "1" ]; then
	echo "=== odin test tests ==="
	odin test tests -collection:bbl=src
fi

echo "Build complete: $PROJECT_ROOT/bbl"
