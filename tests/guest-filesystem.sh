#!/bin/sh
# End-to-end guard for the explicitly supported single-process dash builtins.
# This test intentionally does not execute BusyBox or any other external guest
# program: process creation and guest exec are separate release blockers.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guest_root=${1:-"$project_dir/build/guest-root"}
lua=${LUA:-lua5.2}

if [ ! -x "$guest_root/bin/dash" ]; then
  "$project_dir/scripts/build-guest-root.sh" "$guest_root"
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/craftos-blink-guest-filesystem.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

work_root="$tmp_dir/root"
mkdir "$work_root"
# Keep the reproducible fixture immutable: all guest writes below target only
# this private copy.
cp -a "$guest_root/." "$work_root/"

dash_program='cd /tmp
pwd
if test -f /bin/dash; then
  printf "dash-present\n"
else
  printf "dash-missing\n"
  exit 1
fi
printf "first line\n" > note
IFS= read -r line < note
printf "read=<%s>\n" "$line"
printf "second line\n" >> note
if cd /definitely-missing 2>/dev/null; then
  printf "missing-cd=unexpected-success\n"
  exit 1
else
  printf "missing-cd-status=%s\n" "$?"
fi'

"$lua" "$project_dir/bin/craftos-blink.lua" --root "$work_root" --cwd / \
  /bin/dash -c "$dash_program" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"

expected_stdout="$tmp_dir/expected.stdout"
printf '%s\n' \
  '/tmp' \
  'dash-present' \
  'read=<first line>' \
  'missing-cd-status=2' >"$expected_stdout"
if ! cmp -s "$expected_stdout" "$tmp_dir/stdout"; then
  echo "guest-filesystem: unexpected dash stdout" >&2
  diff -u "$expected_stdout" "$tmp_dir/stdout" >&2 || true
  exit 1
fi

if [ -s "$tmp_dir/stderr" ]; then
  echo "guest-filesystem: unexpected dash stderr" >&2
  sed -n '1,80p' "$tmp_dir/stderr" >&2
  exit 1
fi

expected_note="$tmp_dir/expected.note"
printf '%s\n' 'first line' 'second line' >"$expected_note"
if ! cmp -s "$expected_note" "$work_root/tmp/note"; then
  echo "guest-filesystem: redirection/append did not persist expected data" >&2
  diff -u "$expected_note" "$work_root/tmp/note" >&2 || true
  exit 1
fi

echo "guest-filesystem: dash builtins and persistent filesystem path pass"
