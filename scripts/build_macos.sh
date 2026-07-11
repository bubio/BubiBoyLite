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

for arg in "$@"; do
	case "$arg" in
	--debug)
		DEBUG=1
		;;
	--test)
		RUN_TEST=1
		;;
	*)
		echo "Error: 不明な引数です: $arg"
		exit 1
		;;
	esac
done

if [ "$DEBUG" = "1" ]; then
	BUILD_FLAGS="-collection:bbl=src -out:bbl -debug"
else
	BUILD_FLAGS="-collection:bbl=src -out:bbl -o:speed"
fi

echo "=== BubiBoyLite macOS build ==="
echo "odin build src/app $BUILD_FLAGS"
odin build src/app $BUILD_FLAGS

if [ "$RUN_TEST" = "1" ]; then
	echo "=== odin test tests ==="
	odin test tests -collection:bbl=src
fi

echo "Build complete: $PROJECT_ROOT/bbl"
