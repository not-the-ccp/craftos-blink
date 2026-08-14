#!/bin/sh
set -eu

expected=f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580
actual=$(git -C vendor/blink rev-parse HEAD)
if [ "$actual" != "$expected" ]; then
  echo "check-upstream: expected Blink $expected, found $actual" >&2
  exit 1
fi

make -C vendor/blink -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
make -C vendor/blink check

