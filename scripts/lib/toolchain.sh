# Shared by build, migration and test entry points. Source this file.
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  if [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  else
    printf '%s\n' 'A working Xcode or Command Line Tools installation is required.' >&2
    return 1
  fi
fi

if [ -n "${PAPERMANAGER_SDK:-}" ]; then
  BUILD_SDK=$PAPERMANAGER_SDK
elif [ "${DEVELOPER_DIR:-}" = /Library/Developer/CommandLineTools ] &&
     [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  # This installed CLT toolchain needs the stable SDK's SwiftUI plugins.
  BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  BUILD_SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
fi
TEST_SDK=${PAPERMANAGER_TEST_SDK:-$BUILD_SDK}
PM_TARGET="$(uname -m)-apple-macosx14.0"
if [ ! -d "$BUILD_SDK" ] || [ ! -d "$TEST_SDK" ]; then
  printf '%s\n' "macOS SDK not found: $BUILD_SDK / $TEST_SDK" >&2
  return 1
fi
