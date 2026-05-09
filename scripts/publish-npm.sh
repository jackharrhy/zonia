#!/usr/bin/env bash
# Publish all npm packages staged in dist/npm/.
# Per-platform binary holders publish first; the unscoped launcher
# (which depends on them via optionalDependencies) goes last.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NPM_DIR="$ROOT/dist/npm"

if [ ! -d "$NPM_DIR" ]; then
  echo "✗ dist/npm/ not found. Run scripts/prepare-npm.ts first."
  exit 1
fi

# Per-platform binary holders: @zonia-world/zonia-<platform>-<arch>/
for d in "$NPM_DIR/@zonia-world/"*/; do
  name="$(node -p "require('$d/package.json').name")"
  version="$(node -p "require('$d/package.json').version")"
  echo "==> Publishing $name@$version"
  (cd "$d" && npm publish --access public)
done

# Unscoped launcher (must publish AFTER its optionalDependencies are live)
echo "==> Publishing zonia (launcher)"
(cd "$NPM_DIR/zonia" && npm publish --access public)

echo
echo "Done. Try:  npx zonia"
