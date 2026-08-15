#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: tools/inventory-elf.sh ELF [ELF ...]" >&2
  exit 2
fi

for binary in "$@"; do
  test -f "$binary" || { echo "inventory-elf: not found: $binary" >&2; exit 1; }
done

objdump -d -M intel --no-show-raw-insn "$@" |
  awk '
    /^[[:space:]]*[0-9a-f]+:/ {
      for (i = 2; i <= NF; i++) {
        word = $i
        if (word ~ /^(addr32|bnd|cs|data16|ds|es|fs|gs|lock|notrack|rep|repz|repnz|ss)$/) continue
        sub(/[^a-zA-Z0-9_.].*$/, "", word)
        if (word != "") print word
        break
      }
    }
  ' | LC_ALL=C sort -u
