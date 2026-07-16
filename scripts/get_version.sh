#!/bin/bash
set -e

# src/app/version.odin の VERSION 定数を単一の源として抽出する。
# リリース zip のファイル名は Git タグではなくこの値から生成する（タグ名と独立）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$PROJECT_ROOT/src/app/version.odin"

VERSION="$(sed -n 's/^VERSION :: "\([0-9][0-9.]*\)"/\1/p' "$VERSION_FILE" | head -n 1)"

if [ -z "$VERSION" ]; then
	echo "Error: $VERSION_FILE から VERSION を抽出できませんでした。書式 'VERSION :: \"x.y.z\"' を確認してください。" >&2
	exit 1
fi

echo "$VERSION"
