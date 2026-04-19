#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$ROOT_DIR/apps/relay"
OPT_DIR="/opt/zend-relay"
RELAY_OUT="$RELAY_DIR/zig-out/bin/zend-relay"
OPT_OUT="$OPT_DIR/zend-relay"
SERVICE_NAME="zend-relay.service"

echo "Building relay..."
cd "$RELAY_DIR"
zig build -Doptimize=ReleaseFast

if [[ ! -f "$RELAY_OUT" ]]; then
    echo "error: expected relay output not found at:"
    echo "  $RELAY_OUT"
    exit 1
fi

echo "Stopping $SERVICE_NAME..."
sudo systemctl stop "$SERVICE_NAME"

echo "Creating install directory..."
sudo mkdir -p "$OPT_DIR"

echo "Copying relay binary..."
sudo cp "$RELAY_OUT" "$OPT_OUT"
sudo chmod +x "$OPT_OUT"

echo "Starting $SERVICE_NAME..."
sudo systemctl start "$SERVICE_NAME"

echo "Service status:"
sudo systemctl --no-pager --full status "$SERVICE_NAME"

echo "Done:"
echo "  built:  $RELAY_OUT"
echo "  copied: $OPT_OUT"
