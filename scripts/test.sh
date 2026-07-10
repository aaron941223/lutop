#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
DEVELOPER_LIB="$DEVELOPER_DIR/Library/Developer/usr/lib"

swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker "-F$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$DEVELOPER_LIB"
