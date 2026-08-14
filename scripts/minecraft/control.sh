#!/bin/sh
set -eu

base=${CRAFTOS_BLINK_CONTROL_URL:-http://127.0.0.1:8765}
action=${1:-state}
shift || true

case "$action" in
  health|state) curl -fsS "$base/$action" ;;
  command) curl -fsS -X POST --data-binary "$*" "$base/command" ;;
  use)
    test "$#" -eq 3
    curl -fsS -X POST "$base/use?x=$1&y=$2&z=$3"
    ;;
  screenshot) curl -fsS -X POST "$base/screenshot" ;;
  *) echo "usage: $0 {health|state|command CMD|use X Y Z|screenshot}" >&2; exit 2 ;;
esac
