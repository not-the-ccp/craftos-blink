#!/bin/sh
# End-to-end gate for the current cooperative fork/exec descriptor path.
#
# This is deliberately a small, deterministic shell scenario. It proves the
# release-critical combination of fork/vfork, execve, pipe, dup2, wait4, and
# inherited descriptors without claiming complete POSIX process semantics.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guest_root=${1:-"$project_dir/build/guest-root"}
lua=${LUA:-lua5.2}
instruction_limit=${CRAFTOS_BLINK_PROCESS_INSTRUCTION_LIMIT:-50000000}

case $instruction_limit in
  ''|*[!0-9]*)
    echo "guest-process: instruction limit must be a positive decimal integer" >&2
    exit 2
    ;;
esac

if [ "$instruction_limit" -eq 0 ]; then
  echo "guest-process: instruction limit must be greater than zero" >&2
  exit 2
fi

if [ ! -x "$guest_root/bin/dash" ]; then
  "$project_dir/scripts/build-guest-root.sh" "$guest_root"
fi
for program in true cat mkdir ls uname false; do
  if [ ! -x "$guest_root/bin/$program" ]; then
    echo "guest-process: guest root is missing bin/$program" >&2
    exit 2
  fi
done

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/craftos-blink-guest-process.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

work_root="$tmp_dir/root"
mkdir "$work_root"
# Do not mutate the reproducible fixture; every guest-visible write is made in
# this private root that is removed after the assertions complete.
cp -a "$guest_root/." "$work_root/"

dash_program='PATH=/bin
export PATH
/bin/true
echo hello | /bin/cat
/bin/mkdir /tmp/process-gate
printf "persistent payload\\n" > /tmp/process-gate/message
/bin/cat /tmp/process-gate/message
/bin/ls /tmp/process-gate
/bin/uname
if /bin/false; then
  printf "false-status=unexpected-success\\n"
  exit 1
else
  false_status=$?
  printf "false-status=%s\\n" "$false_status"
fi
test "$false_status" -eq 1'

set +e
"$lua" "$project_dir/bin/craftos-blink.lua" --root "$work_root" --cwd / --env PATH=/bin \
  --instruction-limit "$instruction_limit" /bin/dash -c "$dash_program" \
  >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
guest_status=$?
set -e
if [ "$guest_status" -ne 0 ]; then
  echo "guest-process: dash scenario exited with status $guest_status" >&2
  sed -n '1,160p' "$tmp_dir/stderr" >&2
  exit 1
fi

expected_stdout="$tmp_dir/expected.stdout"
printf '%s\n' \
  'hello' \
  'persistent payload' \
  'message' \
  'Linux' \
  'false-status=1' >"$expected_stdout"
if ! cmp -s "$expected_stdout" "$tmp_dir/stdout"; then
  echo "guest-process: unexpected dash stdout" >&2
  diff -u "$expected_stdout" "$tmp_dir/stdout" >&2 || true
  exit 1
fi

if [ -s "$tmp_dir/stderr" ]; then
  echo "guest-process: unexpected dash stderr" >&2
  sed -n '1,160p' "$tmp_dir/stderr" >&2
  exit 1
fi

expected_file="$tmp_dir/expected.message"
printf '%s\n' 'persistent payload' >"$expected_file"
if ! cmp -s "$expected_file" "$work_root/tmp/process-gate/message"; then
  echo "guest-process: redirection did not persist expected bytes" >&2
  diff -u "$expected_file" "$work_root/tmp/process-gate/message" >&2 || true
  exit 1
fi

echo "guest-process: fork/exec/pipe/descriptor scenario passes"
