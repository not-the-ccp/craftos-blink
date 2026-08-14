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
  input)
    mode=${1:-}
    shift || true
    case "$mode" in
      type) query= ;;
      clear) query='?clear=true' ;;
      submit) query='?submit=true' ;;
      run) query='?clear=true&submit=true' ;;
      *) echo "input mode must be type, clear, submit, or run" >&2; exit 2 ;;
    esac
    curl -fsS -X POST --data-binary "$*" "$base/input$query"
    ;;
  screenshot) curl -fsS -X POST "$base/screenshot" ;;
  *) echo "usage: $0 {health|state|command CMD|use X Y Z|input MODE TEXT|screenshot}" >&2; exit 2 ;;
esac
