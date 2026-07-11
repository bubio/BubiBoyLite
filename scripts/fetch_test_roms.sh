#!/bin/sh
set -e

# tests/roms/ にテスト ROM (Blargg / Mooneye / acid2 など) を配置するスクリプト。
# フェーズ 1 で中身を実装する。現時点では ROM を取得せず正常終了するだけの雛形。
# ライセンス上、テスト ROM をリポジトリにコミットしないため CI・ローカルの両方で
# このスクリプトを通して都度取得する想定（tests/roms/ は .gitignore 対象）。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
ROMS_DIR="$PROJECT_ROOT/tests/roms"

mkdir -p "$ROMS_DIR"

echo "fetch_test_roms.sh: まだテスト ROM の取得は未実装です (フェーズ 1 で追加予定)。"
echo "tests/roms/ を確認: $ROMS_DIR"

exit 0
