#!/usr/bin/env bash
# Plan step S0.2: the app and the AlgorithmKit package must evaluate byte-identical JavaScript.
# Fails if any file under Trio/Resources/javascript differs from the package's copy.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=Trio/Resources/javascript
PKG=AlgorithmKit/Sources/JSOrefCore/Resources/javascript
status=0
while IFS= read -r rel; do
  if [ ! -f "$PKG/$rel" ]; then echo "MISSING in package: $rel"; status=1; continue; fi
  a=$(shasum -a 256 "$APP/$rel" | cut -d' ' -f1)
  b=$(shasum -a 256 "$PKG/$rel" | cut -d' ' -f1)
  if [ "$a" != "$b" ]; then echo "DIFFERS: $rel"; status=1; fi
done < <(cd "$APP" && find . -type f -name '*.js' | sed 's#^\./##' | sort)
while IFS= read -r rel; do
  [ -f "$APP/$rel" ] || { echo "EXTRA in package: $rel"; status=1; }
done < <(cd "$PKG" && find . -type f -name '*.js' | sed 's#^\./##' | sort)
[ $status -eq 0 ] && echo "bundle parity OK" || echo "bundle parity FAILED"
exit $status
