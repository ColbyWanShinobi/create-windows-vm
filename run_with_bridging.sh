#!/usr/bin/env bash
# Start a VM with a direct LAN connection through the project bridge.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/run.sh" "$@" --network bridge
