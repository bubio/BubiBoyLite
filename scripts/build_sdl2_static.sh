#!/bin/sh
set -e

# SDL2 をソースからビルドし、静的ライブラリ (libSDL2.a) を build/sdl2/<platform>-<arch>/ に
# 生成・キャッシュするヘルパー。scripts/build_macos.sh / build_linux.sh の --release から呼ばれる。
# POSIX sh のみ使用。
#
# 使い方: build_sdl2_static.sh <platform> <arch> [cmake 追加オプション...]
#   platform: macos | linux
#   arch:     x86_64 | arm64 など、キャッシュディレクトリ名の区別にのみ使う

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

# バージョンをピン止め（testing.md / fetch_test_roms.sh と同じ方針: 常にコミット/タグ固定）。
SDL2_VERSION="2.30.9"
SDL2_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz"

if [ $# -lt 2 ]; then
	echo "Usage: $0 <platform> <arch> [extra cmake args...]" >&2
	exit 1
fi

PLATFORM="$1"
ARCH="$2"
shift 2

CACHE_DIR="$PROJECT_ROOT/build/sdl2/${PLATFORM}-${ARCH}"
SRC_DIR="$PROJECT_ROOT/build/sdl2/src/SDL2-${SDL2_VERSION}"
BUILD_DIR="$PROJECT_ROOT/build/sdl2/build-${PLATFORM}-${ARCH}"

if [ -f "$CACHE_DIR/lib/libSDL2.a" ]; then
	echo "build_sdl2_static.sh: キャッシュ済み、スキップ: $CACHE_DIR"
	exit 0
fi

mkdir -p "$PROJECT_ROOT/build/sdl2/src"

if [ ! -d "$SRC_DIR" ]; then
	TARBALL="$PROJECT_ROOT/build/sdl2/src/SDL2-${SDL2_VERSION}.tar.gz"
	if [ ! -f "$TARBALL" ]; then
		echo "build_sdl2_static.sh: SDL2 ${SDL2_VERSION} を取得中..."
		curl -fsSL --retry 3 --retry-delay 2 -o "$TARBALL" "$SDL2_URL"
	fi
	tar -xzf "$TARBALL" -C "$PROJECT_ROOT/build/sdl2/src"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# HIDAPI(生HIDデバイスアクセス)のlibusbバックエンドを切る。コントローラー対応は
# SDL2 GameController APIで足りるため生HIDアクセスは不要で、余分なlibusb依存を避ける。
echo "build_sdl2_static.sh: cmake configure ($PLATFORM/$ARCH)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$CACHE_DIR" \
	-DSDL_STATIC=ON \
	-DSDL_SHARED=OFF \
	-DSDL_TEST=OFF \
	-DSDL_HIDAPI_LIBUSB=OFF \
	"$@"

echo "build_sdl2_static.sh: build"
cmake --build "$BUILD_DIR" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

echo "build_sdl2_static.sh: install -> $CACHE_DIR"
cmake --install "$BUILD_DIR" --config Release

if [ ! -f "$CACHE_DIR/lib/libSDL2.a" ]; then
	echo "build_sdl2_static.sh: Error: libSDL2.a が生成されませんでした" >&2
	exit 1
fi

echo "build_sdl2_static.sh: 完了: $CACHE_DIR/lib/libSDL2.a"
