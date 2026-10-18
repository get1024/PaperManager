#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_BUILD_DIR="$PROJECT_DIR/dist"
APP_PATH="$APP_BUILD_DIR/PaperManager.app/Contents/MacOS/PaperManager"
if [[ ! -x "$APP_PATH" ]]; then
  PAPERMANAGER_BUILD_DIR="$APP_BUILD_DIR" "$PROJECT_DIR/scripts/build-app.sh"
fi
# This isolated library can be inspected and edited without replacing either
# Lattice's database or an existing PaperManager library.
if [[ -z "${PAPERMANAGER_LIBRARY_PATH:-}" && -f "$PROJECT_DIR/LocalData/Library/library.json" ]]; then
  export PAPERMANAGER_LIBRARY_PATH="$PROJECT_DIR/LocalData/Library/library.json"
fi
exec "$APP_PATH"
