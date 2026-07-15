#!/bin/sh
set -e

# BubiBoyLite Linux/FreeBSD ビルドスクリプト。POSIX sh のみ使用（bash 拡張禁止）。
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

if [ "$RELEASE" = "1" ]; then
	# 配布用: SDL2 を静的リンクする（architecture.md「開発=動的/配布=静的」の二段構え）。
	# macOS と異なり ld64 の force_load/dead_strip_dylibs は使えない（GNU ld/lld）。
	# 代わりに「静的ビルドの prefix にだけ -L を通し、動的 libSDL2.so を
	# 探索パスに置かない（apt に libsdl2-dev を入れない）」ことで
	# -lSDL2（vendor:sdl2 の foreign import 由来）が .a に解決されるようにする。
	# オーディオ/ビデオドライバのシステムライブラリ（ALSA, X11/Wayland, dbus 等）は
	# SDL2 静的ライブラリが依存する動的ライブラリのままで正しい（architecture.md 参照）。
	ARCH="$(uname -m)"
	case "$(uname -s)" in
	Linux) PLATFORM="linux" ;;
	FreeBSD) PLATFORM="freebsd" ;;
	*)
		echo "Error: 未対応の OS です（検出: $(uname -s)）"
		exit 1
		;;
	esac
	"$SCRIPT_DIR/build_sdl2_static.sh" "$PLATFORM" "$ARCH"

	SDL2_DIR="$PROJECT_ROOT/build/sdl2/$PLATFORM-$ARCH"
	SDL2_LIB="$SDL2_DIR/lib/libSDL2.a"
	if [ ! -f "$SDL2_LIB" ]; then
		echo "Error: 静的 SDL2 のビルドに失敗しました: $SDL2_LIB が見つかりません"
		exit 1
	fi

	# sdl2-config --static-libs は静的リンクに必要な System 依存ライブラリ一覧
	# （ALSA/X11/Wayland/dbus/pthread/dl/m 等）を教えてくれるので、それをそのまま使う。
	# 先頭の -L<prefix>/lib と -lSDL2 -lSDL2 は自前の EXTRA_LINKER_FLAGS 側と
	# 重複するため、-L 検索パスだけ差し替えて foreign import の -lSDL2 解決先を
	# 静的ライブラリへ向ける（このディレクトリには .so を置かないので曖昧さがない）。
	SDL2_SYS_LIBS="$("$SDL2_DIR/bin/sdl2-config" --static-libs 2>/dev/null | sed "s#-L$SDL2_DIR/lib##; s#-lSDL2##g")"

	EXTRA_LINKER_FLAGS="-L$SDL2_DIR/lib -Wl,-Bstatic -lSDL2 -Wl,-Bdynamic $SDL2_SYS_LIBS"

	set -- "$@" "-extra-linker-flags:$EXTRA_LINKER_FLAGS"
fi

echo "=== BubiBoyLite Linux/FreeBSD build ==="
echo "odin build src/app $*"
odin build src/app "$@"

if [ "$RUN_TEST" = "1" ]; then
	echo "=== odin test tests ==="
	odin test tests -collection:bbl=src
fi

echo "Build complete: $PROJECT_ROOT/bbl"
