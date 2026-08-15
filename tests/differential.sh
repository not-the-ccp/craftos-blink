#!/bin/sh
set -eu

./tests/build-fixtures.sh
blink=vendor/blink/o/blink/blink
if [ ! -x "$blink" ]; then
  echo "differential: run scripts/check-upstream.sh first" >&2
  exit 1
fi

run_status() {
  output=$1
  shift
  set +e
  "$@" >"$output" 2>"$output.err"
  status=$?
  set -e
  echo "$status"
}

for fixture in hello arithmetic; do
  native_status=$(run_status "build/$fixture.native" "./build/fixtures/$fixture")
  blink_status=$(run_status "build/$fixture.blink" "$blink" "build/fixtures/$fixture")
  lua_status=$(run_status "build/$fixture.lua" lua5.2 bin/craftos-blink.lua --root . "/build/fixtures/$fixture")
  test "$native_status" = "$blink_status"
  test "$native_status" = "$lua_status"
  cmp "build/$fixture.native" "build/$fixture.blink"
  cmp "build/$fixture.native" "build/$fixture.lua"
done

# CPU state fixtures write a masked register/flags snapshot rather than text.
for fixture in cpu_flags; do
  native_status=$(run_status "build/$fixture.native" "./build/fixtures/$fixture")
  blink_status=$(run_status "build/$fixture.blink" "$blink" "build/fixtures/$fixture")
  lua_status=$(run_status "build/$fixture.lua" lua5.2 bin/craftos-blink.lua --root . "/build/fixtures/$fixture")
  test "$native_status" = "$blink_status"
  test "$native_status" = "$lua_status"
  cmp "build/$fixture.native" "build/$fixture.blink"
  cmp "build/$fixture.native" "build/$fixture.lua"
done

echo "differential: native Linux, pinned Blink, and Lua results match"
