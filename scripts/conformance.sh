#!/usr/bin/env bash
# Run the official toml-test conformance suite against our decoder (and, once it
# exists, encoder), pinned to TOML 1.0.0.
#
# The toml-test runner is a Go program that EMBEDS the corpus, so there is
# nothing to vendor — install it once and run. CI does the same (see ci.yml).
#
#   ./scripts/conformance.sh            # decoder (+ encoder if built)
#
# Requirements: a Swift toolchain and `toml-test` on PATH. To install the
# runner (pinned): go install github.com/toml-lang/toml-test/v2/cmd/toml-test@v2.2.0
# (this drops the binary in "$(go env GOPATH)/bin", which you may need on PATH).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v toml-test >/dev/null 2>&1; then
  echo "error: toml-test not found on PATH." >&2
  echo "install: go install github.com/toml-lang/toml-test/v2/cmd/toml-test@v2.2.0" >&2
  echo "then add \"\$(go env GOPATH)/bin\" to PATH." >&2
  exit 127
fi

echo "==> building conformance binaries (release)"
PRODUCTS=(--product toml-decode)
HAVE_ENCODE=0
if swift build -c release --product toml-encode >/dev/null 2>&1; then
  PRODUCTS+=(--product toml-encode)
  HAVE_ENCODE=1
fi
swift build -c release "${PRODUCTS[@]}"

DEC="$PWD/.build/release/toml-decode"

# -toml=1.0 is LOAD-BEARING: the v2 runner defaults to TOML 1.1, which includes
# draft tests a 1.0-only parser must reject (spurious failures otherwise).
echo "==> decoder conformance (TOML 1.0.0)"
toml-test test -toml=1.0 -decoder="$DEC"

if [ "$HAVE_ENCODE" = "1" ]; then
  echo "==> encoder conformance (TOML 1.0.0)"
  toml-test test -toml=1.0 -encoder="$PWD/.build/release/toml-encode"
fi
