#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root_dir=${1:-"$project_dir/build/guest-root"}
status_file="$project_dir/config/guest-syscall-status.tsv"

command -v strace >/dev/null 2>&1 || {
  echo "check-guest-syscalls: missing required command: strace" >&2
  exit 1
}

if [ ! -d "$root_dir" ]; then
  echo "check-guest-syscalls: run make guest-root first" >&2
  exit 1
fi
root_dir=$(CDPATH= cd -- "$root_dir" && pwd)
for program in dash busybox cat mkdir ls uname; do
  if [ ! -x "$root_dir/bin/$program" ]; then
    echo "check-guest-syscalls: run make guest-root first (missing bin/$program)" >&2
    exit 1
  fi
done

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT HUP INT TERM
work_dir="$temporary_dir/work"
mkdir "$work_dir"

# Keep command names and files inside the pinned guest root and temporary
# scenario directory. The shell builtin echo exercises the pipe; the remaining
# commands are the copied BusyBox applets created by build-guest-root.sh.
LC_ALL=C TZ=UTC strace -f -qq -o "$temporary_dir/trace" -- "$root_dir/bin/dash" -c '
  PATH=$1/bin
  export PATH
  umask 022
  echo inventory | cat > "$2/message"
  mkdir "$2/directory"
  cat < "$2/message" > "$2/directory/copy"
  ls "$2/directory" >/dev/null
  uname >/dev/null
' dash "$root_dir" "$work_dir"

awk '
  {
    line = $0
    sub(/^\[pid [0-9]+\] /, "", line)
    sub(/^[0-9]+ /, "", line)
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
