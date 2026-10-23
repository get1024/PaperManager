#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_BUILD_DIR="$PROJECT_DIR/dist"
APP_PATH="$APP_BUILD_DIR/PaperManager.app/Contents/MacOS/PaperManager"
if [[ ! -x "$APP_PATH" ]]; then
  PAPERMANAGER_BUILD_DIR="$APP_BUILD_DIR" "$PROJECT_DIR/scripts/build-app.sh"
fi
# Honor the same active library as Finder/Launchpad. Legacy local data is only
# a fallback when no valid preference has been chosen for this installation.
PREFERRED_LIBRARY="$(/usr/bin/defaults read com.aurelian.PaperManager PaperManager.PreferredLibraryPath 2>/dev/null || true)"
if [[ -z "${PAPERMANAGER_LIBRARY_PATH:-}" && ! ( "$PREFERRED_LIBRARY" == /* && -f "$PREFERRED_LIBRARY" && -r "$PREFERRED_LIBRARY" ) && -f "$PROJECT_DIR/LocalData/Library/library.json" ]]; then
  export PAPERMANAGER_LIBRARY_PATH="$PROJECT_DIR/LocalData/Library/library.json"
fi
exec "$APP_PATH"
