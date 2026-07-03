#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

INSTALL_DIR="${LUTOP_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/Lutop.app"
LAUNCH_AGENT="${LUTOP_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/dev.yiminglu.lutop.login.plist}"

if pgrep -x Lutop >/dev/null 2>&1; then
  pkill -x Lutop || true
  for _ in {1..20}; do
    pgrep -x Lutop >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

if [[ -x "$INSTALL_APP/Contents/MacOS/Lutop" ]]; then
  "$INSTALL_APP/Contents/MacOS/Lutop" --lutop-claude-disconnect || true
fi

rm -rf "$INSTALL_APP"
rm -f "$LAUNCH_AGENT"

echo "Removed $INSTALL_APP"
echo "Removed $LAUNCH_AGENT"
