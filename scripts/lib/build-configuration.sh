# Shared by the app and standalone CLI builds. Source after toolchain.sh.
PM_BUILD_CONFIGURATION=${PAPERMANAGER_BUILD_CONFIGURATION:-release}
case "$PM_BUILD_CONFIGURATION" in
  release) PM_OPTIMIZATION_FLAGS=(-Osize -whole-module-optimization) ;;
  debug) PM_OPTIMIZATION_FLAGS=(-Onone -g) ;;
  *) printf '%s\n' 'PAPERMANAGER_BUILD_CONFIGURATION must be release or debug' >&2; return 2 ;;
esac
