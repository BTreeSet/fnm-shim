#!/usr/bin/env bash
# End-to-end validation of fnm-shim on Unix-like runners.
#
# Steps mirror the spec in DESIGN §3:
#   1. fnm install 18 & 20; default 18
#   2. Hardlink node/npm/npx → built shim; prepend to PATH
#   3. node -v matches 18
#   4. npm -v exits 0
#   5. fnm default 20; node -v matches 20 (cache invalidation)
#   6. invalid-shim hardlink fails with non-zero exit and clear error
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building fnm-shim (release)"
cargo build --release --bin fnm-shim

SHIM="$ROOT/target/release/fnm-shim"
test -x "$SHIM"

echo "==> Verifying fnm is available"
command -v fnm >/dev/null 2>&1 || { echo "FATAL: fnm not on PATH"; exit 1; }

# Ensure FNM_DIR is set to a writable, isolated location.
export FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
mkdir -p "$FNM_DIR"

eval "$(fnm env --shell bash)"

echo "==> fnm install 18 / 20"
fnm install 18
fnm install 20

echo "==> fnm default 18"
fnm default 18

# Clear any prior cache so step 3 verifies fresh-creation.
rm -f "${TMPDIR:-/tmp}/fnm-shim-cache.json"

SHIM_BIN="$(mktemp -d)"
ln -sf "$SHIM" "$SHIM_BIN/node"
ln -sf "$SHIM" "$SHIM_BIN/npm"
ln -sf "$SHIM" "$SHIM_BIN/npx"
ln -sf "$SHIM" "$SHIM_BIN/invalid-shim"
export PATH="$SHIM_BIN:$PATH"

echo "==> [3] node -v (expect v18.*)"
NODE_V="$(node -v)"
echo "    got: $NODE_V"
case "$NODE_V" in
  v18.*) echo "    OK" ;;
  *) echo "FAIL: expected v18.*, got $NODE_V"; exit 1 ;;
esac

echo "==> [4] npm -v"
NPM_V="$(npm -v)"
echo "    got: $NPM_V"
[[ -n "$NPM_V" ]] || { echo "FAIL: empty npm version"; exit 1; }

echo "==> [5] fnm default 20 → node -v should now be v20.*"
fnm default 20
NODE_V2="$(node -v)"
echo "    got: $NODE_V2"
case "$NODE_V2" in
  v20.*) echo "    OK (cache invalidated)" ;;
  *) echo "FAIL: expected v20.*, got $NODE_V2"; exit 1 ;;
esac

echo "==> [6] invalid-shim should fail with non-zero exit and clear error"
set +e
ERR_OUT="$("$SHIM_BIN/invalid-shim" 2>&1)"
ERR_CODE=$?
set -e
echo "    exit=$ERR_CODE output=$ERR_OUT"
[[ $ERR_CODE -ne 0 ]] || { echo "FAIL: invalid-shim returned 0"; exit 1; }
echo "$ERR_OUT" | grep -qi "unsupported invocation" || {
  echo "FAIL: missing 'unsupported invocation' error"; exit 1;
}

echo "==> ALL E2E STEPS PASSED"
