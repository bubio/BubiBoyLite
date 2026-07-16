#!/bin/bash
set -e

# 配布用 zip を作成する。CI もこのスクリプトを呼ぶ（ローカル/CI 共通）。
#
# 使い方: package_zip.sh <binary-path> <platform> <arch>
#   platform: macos, linux
#   arch:     x86_64, arm64, amd64
#
# 出力: bbl-<version>-<platform>-<arch>.zip (プロジェクトルート直下)
# 同梱物は bbl / LICENSE / README.md の 3 ファイルのみで、
# zip 内に余計なディレクトリ階層を作らない（展開したらファイルが直接出る）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ $# -ne 3 ]; then
	echo "使い方: $0 <binary-path> <platform> <arch>" >&2
	exit 1
fi

BINARY_PATH="$1"
PLATFORM="$2"
ARCH="$3"

if [ ! -f "$BINARY_PATH" ]; then
	echo "Error: バイナリが見つかりません: $BINARY_PATH" >&2
	exit 1
fi

case "$PLATFORM" in
macos | linux) ;;
*)
	echo "Error: 不正な platform '$PLATFORM'（macos, linux のいずれか）" >&2
	exit 1
	;;
esac

case "$ARCH" in
x86_64 | arm64 | amd64) ;;
*)
	echo "Error: 不正な arch '$ARCH'（x86_64, arm64, amd64 のいずれか）" >&2
	exit 1
	;;
esac

VERSION="$("$SCRIPT_DIR/get_version.sh")"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp "$BINARY_PATH" "$STAGE_DIR/bbl"
cp "$PROJECT_ROOT/LICENSE" "$STAGE_DIR/LICENSE"
cp "$PROJECT_ROOT/README.md" "$STAGE_DIR/README.md"
chmod +x "$STAGE_DIR/bbl"

ZIP_NAME="bbl-${VERSION}-${PLATFORM}-${ARCH}.zip"
ZIP_PATH="$PROJECT_ROOT/$ZIP_NAME"
rm -f "$ZIP_PATH"

(cd "$STAGE_DIR" && zip "$ZIP_PATH" bbl LICENSE README.md)

echo "$ZIP_PATH"
