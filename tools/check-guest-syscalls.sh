#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root_dir=${1:-"$project_dir/build/guest-root"}
status_file="$project_dir/config/guest-syscall-status.tsv"
applets_file="$project_dir/config/busybox-applets.list"

command -v strace >/dev/null 2>&1 || {
  echo "check-guest-syscalls: missing required command: strace" >&2
  exit 1
}

if [ ! -d "$root_dir" ]; then
  echo "check-guest-syscalls: run make guest-root first" >&2
  exit 1
fi
root_dir=$(CDPATH= cd -- "$root_dir" && pwd)
if [ ! -x "$root_dir/bin/dash" ]; then
  echo "check-guest-syscalls: run make guest-root first (missing bin/dash)" >&2
  exit 1
fi
while IFS= read -r applet_name; do
  case "$applet_name" in ''|'#'*) continue ;; esac
  if [ ! -x "$root_dir/bin/$applet_name" ]; then
    echo "check-guest-syscalls: run make guest-root first (missing bin/$applet_name)" >&2
    exit 1
  fi
done < "$applets_file"

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT HUP INT TERM
work_dir="$temporary_dir/work"
mkdir "$work_dir"

# Keep command names and files inside the pinned guest root and temporary
# scenario directory. Every applet in busybox-applets.list is invoked through
# dash by its copied BusyBox pathname, so changing that list requires extending
# this deterministic scenario too.
LC_ALL=C TZ=UTC strace -f -qq -o "$temporary_dir/trace" -- "$root_dir/bin/dash" -c '
  set -e
  umask 022

  mkdir "$2/directory"
  "$1/bin/printf" "first\\nsecond\\n" > "$2/directory/source"
  "$1/bin/echo" inventory >> "$2/directory/source"
  "$1/bin/cat" "$2/directory/source" > "$2/cat-copy"
  "$1/bin/cp" "$2/cat-copy" "$2/directory/copy"
  "$1/bin/mv" "$2/directory/copy" "$2/directory/moved"
  "$1/bin/touch" "$2/directory/moved"

  "$1/bin/printf" "stream\\n" | "$1/bin/cat" > "$2/stream"
  "$1/bin/env" -i PATH="$1/bin" "$1/bin/true"
  if "$1/bin/false"; then exit 1; fi
  "$1/bin/head" -n 1 "$2/directory/source" >/dev/null
  "$1/bin/tail" -n 1 "$2/directory/source" >/dev/null
  "$1/bin/test" -f "$2/directory/moved"
  (cd "$2" && "$1/bin/pwd" >/dev/null)
  "$1/bin/ls" "$2/directory" >/dev/null
  "$1/bin/ls" -ld "$2/directory" >/dev/null
  "$1/bin/uname" -s >/dev/null
  "$1/bin/wc" -l "$2/directory/source" >/dev/null

  "$1/bin/rm" "$2/cat-copy" "$2/stream" "$2/directory/source" "$2/directory/moved"
  "$1/bin/rmdir" "$2/directory"
' dash "$root_dir" "$work_dir"

awk '
  {
    line = $0
    sub(/^[[:space:]]*(\[pid [[:digit:]]+\]|[[:digit:]]+)[[:space:]]+/, "", line)
    if (line ~ /^[[:alpha:]_][[:alnum:]_]*\(/) {
      sub(/\(.*/, "", line)
      print line
    }
  }
' "$temporary_dir/trace" | LC_ALL=C sort -u > "$temporary_dir/observed"

if ! awk -F '\t' '
  NF != 2 || $1 !~ /^[[:alpha:]_][[:alnum:]_]*$/ || $2 == "" {
    printf "check-guest-syscalls: invalid status entry at line %d\\n", NR > "/dev/stderr"
    invalid = 1
  }
  END { exit invalid }
' "$status_file"; then
  exit 1
fi

cut -f1 "$status_file" | LC_ALL=C sort > "$temporary_dir/classified"
if [ "$(wc -l < "$temporary_dir/classified")" -ne "$(LC_ALL=C sort -u "$temporary_dir/classified" | wc -l)" ]; then
  echo "check-guest-syscalls: duplicate syscall status entries" >&2
  exit 1
fi

comm -23 "$temporary_dir/observed" "$temporary_dir/classified" > "$temporary_dir/unclassified"
comm -13 "$temporary_dir/observed" "$temporary_dir/classified" > "$temporary_dir/stale"
if [ -s "$temporary_dir/unclassified" ] || [ -s "$temporary_dir/stale" ]; then
  echo "check-guest-syscalls: syscall inventory and status table differ" >&2
  if [ -s "$temporary_dir/unclassified" ]; then
    echo "unclassified:" >&2
    sed 's/^/  /' "$temporary_dir/unclassified" >&2
  fi
  if [ -s "$temporary_dir/stale" ]; then
    echo "not present in native scenario:" >&2
    sed 's/^/  /' "$temporary_dir/stale" >&2
  fi
  exit 1
fi

printf 'check-guest-syscalls: %s native scenario syscalls classified\n' \
  "$(wc -l < "$temporary_dir/observed")"
