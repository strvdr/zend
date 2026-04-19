#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASM_DIR="$ROOT_DIR/packages/wasm"
WEB_PUBLIC_DIR="$ROOT_DIR/apps/web/public"
WASM_OUT="$WASM_DIR/zig-out/bin/zend_wasm.wasm"
WEB_WASM_OUT="$WEB_PUBLIC_DIR/zend_wasm.wasm"

echo "Building WASM package..."
cd "$WASM_DIR"
zig build -Doptimize=ReleaseFast

if [[ ! -f "$WASM_OUT" ]]; then
    echo "error: expected wasm output not found at:"
    echo "  $WASM_OUT"
    exit 1
fi

echo "Copying WASM artifact to web/public..."
mkdir -p "$WEB_PUBLIC_DIR"
cp "$WASM_OUT" "$WEB_WASM_OUT"

echo "Done:"
echo "  built:  $WASM_OUT"
echo "  copied: $WEB_WASM_OUT"
