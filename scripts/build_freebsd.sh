#!/bin/sh
set -e

# FreeBSD 向けの薄いラッパー。build_linux.sh は POSIX sh のみで書かれており
# uname -s で Linux/FreeBSD を判別するため、実体はそのまま流用する
# （architecture.md・phase-10-cicd.md T10-5 の方針どおり）。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/build_linux.sh" "$@"
