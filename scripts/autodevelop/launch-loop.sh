#!/usr/bin/env bash
# Detached-session entry point with repository-confined launch diagnostics.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

exec /bin/bash "$HERE/loop.sh" >> "$AUTODEVELOP_LOG_DIR/launch.log" 2>&1
