#!/usr/bin/env bash
# Publish the staged zonia-world launcher to npm.
# Run scripts/prepare-npm.ts first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/dist/npm/zonia-world"

if [ ! -d "$PKG_DIR" ]; then
  echo "✗ dist/npm/zonia-world/ not found. Run scripts/prepare-npm.ts first."
  exit 1
fi

name="$(node -p "require('$PKG_DIR/package.json').name")"
version="$(node -p "require('$PKG_DIR/package.json').version")"
echo "==> Publishing $name@$version"
(cd "$PKG_DIR" && npm publish --access public)

echo
echo "Done. Try:  npx zonia-world"
