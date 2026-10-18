#!/bin/zsh
set -euo pipefail
exec "${0:A:h}/scripts/run-reconstruction.command" "$@"
