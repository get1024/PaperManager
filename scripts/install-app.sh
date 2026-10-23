#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DIST_APP="$PROJECT_DIR/dist/PaperManager.app"
SOURCE_APP="$DIST_APP"
LINK_DIST=auto
SOURCE_SET=0
for ARG in "$@"; do
  case "$ARG" in
    --link-dist) LINK_DIST=1 ;;
    --no-link-dist) LINK_DIST=0 ;;
    *)
      if [[ "$SOURCE_SET" == 1 ]]; then
        print -u2 -- 'Usage: install-app.sh [source.app] [--link-dist|--no-link-dist]'
        exit 1
      fi
      SOURCE_APP="$ARG"
      SOURCE_SET=1
      ;;
  esac
done
SOURCE_APP="${SOURCE_APP:a}"
if [[ "$LINK_DIST" == auto ]]; then
  LINK_DIST=0
  [[ "$SOURCE_APP" != "$DIST_APP" ]] || LINK_DIST=1
fi
INSTALL_DIR="${PAPERMANAGER_INSTALL_DIR:-$HOME/Applications}"
INSTALL_DIR="${INSTALL_DIR:a}"
TARGET_APP="$INSTALL_DIR/PaperManager.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BACKUP_DIR="$PROJECT_DIR/LocalData/Backups/Applications"

if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 -- "Build the app first: $PROJECT_DIR/scripts/build-app.sh"
  exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist")" != com.aurelian.PaperManager ]]; then
  print -u2 -- "Refusing to install a different application: $SOURCE_APP"
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$INSTALL_DIR"

if [[ "${SOURCE_APP:A}" == "${TARGET_APP:A}" ]]; then
  "$LSREGISTER" -f "$TARGET_APP"
  print -r -- "$TARGET_APP"
  exit 0
fi

STAGING_DIR="$(/usr/bin/mktemp -d "$INSTALL_DIR/.papermanager-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/PaperManager.app"
PREVIOUS_APP="$STAGING_DIR/previous/PaperManager.app"
PREVIOUS_DIST="$STAGING_DIR/previous-dist/PaperManager.app"
DIST_LINK="$PROJECT_DIR/dist/.PaperManager.install-$$"
INSTALL_COMPLETE=0
TARGET_CHANGED=0
DIST_CHANGED=0
cleanup() {
  if [[ "$INSTALL_COMPLETE" == 0 ]]; then
    if [[ "$DIST_CHANGED" == 1 ]]; then
      [[ ! -e "$DIST_APP" && ! -L "$DIST_APP" ]] || /bin/rm -rf "$DIST_APP"
      if [[ -e "$PREVIOUS_DIST" || -L "$PREVIOUS_DIST" ]]; then
        /bin/mv -h "$PREVIOUS_DIST" "$DIST_APP"
        [[ -L "$DIST_APP" ]] || "$LSREGISTER" -f "$DIST_APP" >/dev/null 2>&1 || true
      fi
    fi
    if [[ "$TARGET_CHANGED" == 1 ]]; then
      [[ ! -e "$TARGET_APP" ]] || /bin/rm -rf "$TARGET_APP"
      if [[ -d "$PREVIOUS_APP" ]]; then
        /bin/mv "$PREVIOUS_APP" "$TARGET_APP"
        "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
      fi
    fi
  fi
  [[ ! -L "$DIST_LINK" ]] || /bin/rm "$DIST_LINK"
  /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

archive_app() {
  local APP_PATH="$1"
  local LABEL="$2"
  mkdir -p "$BACKUP_DIR"
  local BACKUP_PATH="$BACKUP_DIR/PaperManager-$LABEL-$(/bin/date +%Y%m%d-%H%M%S)-$$.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$BACKUP_PATH"
  /usr/bin/unzip -tq "$BACKUP_PATH" >/dev/null
  local ORIGINAL_HASH="$(/usr/bin/shasum -a 256 "$APP_PATH/Contents/MacOS/PaperManager" | /usr/bin/awk '{print $1}')"
  local ARCHIVED_HASH="$(/usr/bin/unzip -p "$BACKUP_PATH" PaperManager.app/Contents/MacOS/PaperManager | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$ORIGINAL_HASH" == "$ARCHIVED_HASH" ]]
}

/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
SOURCE_HASH="$(/usr/bin/shasum -a 256 "$SOURCE_APP/Contents/MacOS/PaperManager" | /usr/bin/awk '{print $1}')"
STAGED_HASH="$(/usr/bin/shasum -a 256 "$STAGED_APP/Contents/MacOS/PaperManager" | /usr/bin/awk '{print $1}')"
[[ "$SOURCE_HASH" == "$STAGED_HASH" ]]

if [[ -e "$TARGET_APP" ]]; then
  if [[ -L "$TARGET_APP" || "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$TARGET_APP/Contents/Info.plist")" != com.aurelian.PaperManager ]]; then
    print -u2 -- "Refusing to replace an unexpected application or symlink: $TARGET_APP"
    exit 1
  fi
  archive_app "$TARGET_APP" before-install
  mkdir -p "$STAGING_DIR/previous"
  # A newly built bundle may not have a Launch Services record yet.
  "$LSREGISTER" -u "$TARGET_APP" >/dev/null 2>&1 || true
  /bin/mv "$TARGET_APP" "$PREVIOUS_APP"
fi
TARGET_CHANGED=1
/bin/mv "$STAGED_APP" "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"
INSTALLED_HASH="$(/usr/bin/shasum -a 256 "$TARGET_APP/Contents/MacOS/PaperManager" | /usr/bin/awk '{print $1}')"
[[ "$SOURCE_HASH" == "$INSTALLED_HASH" ]]

# Only the repository's conventional output is replaced with a link by default.
# An arbitrary source path is never removed merely because it was installed.
if [[ "$LINK_DIST" == 1 ]]; then
  mkdir -p "$PROJECT_DIR/dist" "$STAGING_DIR/previous-dist"
  if [[ -e "$DIST_APP" || -L "$DIST_APP" ]]; then
    if [[ ! -L "$DIST_APP" ]]; then
      if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$DIST_APP/Contents/Info.plist")" != com.aurelian.PaperManager ]]; then
        print -u2 -- "Refusing to replace an unexpected build output: $DIST_APP"
        exit 1
      fi
      archive_app "$DIST_APP" before-link
    fi
    "$LSREGISTER" -u "$DIST_APP" >/dev/null 2>&1 || true
    /bin/mv -h "$DIST_APP" "$PREVIOUS_DIST"
  fi
  DIST_CHANGED=1
  /bin/ln -s "$TARGET_APP" "$DIST_LINK"
  /bin/mv -fh "$DIST_LINK" "$DIST_APP"
  [[ "${DIST_APP:A}" == "${TARGET_APP:A}" ]]
fi

"$LSREGISTER" -f "$TARGET_APP"
INSTALL_COMPLETE=1
print -r -- "$TARGET_APP"
