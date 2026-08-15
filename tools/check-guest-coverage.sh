#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root_dir=${1:-"$project_dir/build/guest-root"}
release_gate=${2:-classify}

if [ ! -x "$root_dir/bin/dash" ] || [ ! -x "$root_dir/bin/busybox" ]; then
  echo "check-guest-coverage: run make guest-root first" >&2
  exit 1
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT HUP INT TERM

"$project_dir/tools/inventory-elf.sh" "$root_dir/bin/dash" "$root_dir/bin/busybox" > "$temporary_dir/isa"
cut -f1 "$project_dir/config/guest-isa-status.tsv" | LC_ALL=C sort > "$temporary_dir/isa-status"

if ! test "$(wc -l < "$temporary_dir/isa-status")" -eq "$(sort -u "$temporary_dir/isa-status" | wc -l)"; then
  echo "check-guest-coverage: duplicate ISA status entries" >&2
  exit 1
fi

comm -23 "$temporary_dir/isa" "$temporary_dir/isa-status" > "$temporary_dir/unclassified"
comm -13 "$temporary_dir/isa" "$temporary_dir/isa-status" > "$temporary_dir/stale"
if [ -s "$temporary_dir/unclassified" ] || [ -s "$temporary_dir/stale" ]; then
  echo "check-guest-coverage: ISA inventory and status table differ" >&2
  if [ -s "$temporary_dir/unclassified" ]; then
    echo "unclassified:" >&2; sed 's/^/  /' "$temporary_dir/unclassified" >&2
  fi
  if [ -s "$temporary_dir/stale" ]; then
    echo "not present in pinned binaries:" >&2; sed 's/^/  /' "$temporary_dir/stale" >&2
  fi
  exit 1
fi

if [ "$release_gate" = release ]; then
  awk -F '\t' '$2 != "implemented" && $2 != "fault" { print $1 "\t" $2 }' \
    "$project_dir/config/guest-isa-status.tsv" > "$temporary_dir/isa-blockers"
  awk -F '\t' '$2 != "implemented" { print $1 "\t" $2 }' \
    "$project_dir/config/guest-syscall-status.tsv" > "$temporary_dir/syscall-blockers"
  if [ -s "$temporary_dir/isa-blockers" ] || [ -s "$temporary_dir/syscall-blockers" ]; then
    echo "check-guest-coverage: release blockers remain" >&2
    sed 's/^/  ISA: /' "$temporary_dir/isa-blockers" >&2
    sed 's/^/  syscall: /' "$temporary_dir/syscall-blockers" >&2
    exit 1
  fi
fi

printf 'check-guest-coverage: %s ISA mnemonics and %s scenario syscalls classified\n' \
  "$(wc -l < "$temporary_dir/isa")" "$(wc -l < "$project_dir/config/guest-syscall-status.tsv")"
