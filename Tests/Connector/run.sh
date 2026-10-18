#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_WORK_DIR=$(mktemp -d /tmp/papermanager-connector.XXXXXX)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT
. "$TASK_ROOT/scripts/lib/toolchain.sh"
NODE_BIN=${PAPERMANAGER_NODE:-$(command -v node || true)}
if [[ -z "$NODE_BIN" ]]; then
  for candidate in "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin/node /opt/homebrew/bin/node /usr/local/bin/node; do
    if [[ -x "$candidate" ]] && [[ $("$candidate" -p 'Number(process.versions.node.split(".")[0]) >= 18') == true ]]; then
      NODE_BIN=$candidate
      break
    fi
  done
fi
if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  printf '%s\n' 'Node.js 18+ is required for connector tests.' >&2
  exit 1
fi
PAPERMANAGER_CLI_BUILD_DIR="$TEST_WORK_DIR/cli" "$TASK_ROOT/scripts/build-cli.sh" >/dev/null
mkdir "$TEST_WORK_DIR/Sources"
cp "$TASK_ROOT"/Sources/PaperManager/Models/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT"/Sources/PaperManager/Services/*.swift "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Sources/PaperManager/Views/ViewUtilities.swift" "$TEST_WORK_DIR/Sources/"
cp "$TASK_ROOT/Tests/Connector/FixtureServer.swift" "$TEST_WORK_DIR/Sources/"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization \
  -sdk "$TEST_SDK" -target "$PM_TARGET" \
  -module-cache-path "$TASK_ROOT/.build/test-module-cache" "$TEST_WORK_DIR"/Sources/*.swift -o "$TEST_WORK_DIR/FixtureServer"
"$NODE_BIN" "$TASK_ROOT/Tests/Connector/connector-tests.mjs" "$TEST_WORK_DIR/cli/PaperManagerCLI" "$TEST_WORK_DIR/FixtureServer"
