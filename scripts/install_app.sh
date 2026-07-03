#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP="$ROOT_DIR/dist/Lutop.app"
INSTALL_DIR="${LUTOP_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/Lutop.app"

"$ROOT_DIR/scripts/build_app.sh"

mkdir -p "$INSTALL_DIR"

if pgrep -x Lutop >/dev/null 2>&1; then
  pkill -x Lutop || true
  for _ in {1..20}; do
    pgrep -x Lutop >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"
codesign --force --deep --sign - "$INSTALL_APP" >/dev/null

if [[ "${LUTOP_SKIP_OPEN:-0}" != "1" ]]; then
  open -n "$INSTALL_APP"
fi

echo "$INSTALL_APP"
