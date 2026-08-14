#!/bin/sh
set -eu

./tests/build-fixtures.sh
apprun=$(./scripts/bootstrap-craftos-pc.sh)
data=$(mktemp -d)
trap 'rm -rf "$data"' EXIT INT TERM

"$apprun" --headless --directory "$data" \
  --mount-ro blink="$PWD" --script "$PWD/tests/craftos/runner.lua"
