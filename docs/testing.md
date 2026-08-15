# Testing

The reference baseline is the unmodified Blink submodule at
`f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580`.

On 2026-08-15, `scripts/check-upstream.sh` configured and built that revision,
then completed its original `make check` target successfully on x86-64 Debian.
The target downloaded and checksum-verified its pinned Cosmopolitan and
libc-test artifacts as defined by upstream Blink.

Local validation is split deliberately:

- `make check` runs zero-dependency Lua 5.2 unit and ELF end-to-end tests.
- `make check-differential` compares stdout, stderr, exit status, and masked
  register/flags snapshots for generated x86-64 fixtures under native Linux,
  pinned native Blink, and the Lua port. Undefined flags are excluded per
  instruction rather than accidentally treated as stable state.
- `make check-craftos-pc` downloads and SHA-256 verifies CraftOS-PC 2.8.3,
  extracts the AppImage, mounts the checkout read-only, and runs the ELF smoke
  test in headless CraftOS before calling `os.shutdown(status)`.
- `make check-upstream` reproduces the pinned native Blink build and full
  upstream suite.

`make guest-root` reproducibly builds the pinned static dash/BusyBox target.
`tools/inventory-elf.sh build/guest-root/bin/{dash,busybox}` inventories the
complete statically disassembled mnemonic envelope before runtime testing.
`make check-guest-filesystem` copies that root into a private temporary
directory, then checks the supported single-process dash builtin filesystem
path: `cd`/`pwd`, `test`, redirection, builtin `read`, append, and a failed
`cd`. It verifies both exact guest stdout and the resulting host file. It
deliberately does **not** execute BusyBox applets, pipelines, or other external
commands; those require the still-incomplete process/exec layer.
`make check-guest-processes` is the corresponding end-to-end gate for the
current cooperative process path. In another private copy of the root, real
dash runs external BusyBox `true`, a pipe to external `cat`, `mkdir`, a
redirection followed by external `cat`, `ls`, `uname`, and external `false`.
It requires exact stdout, empty stderr, a zero top-level exit status, and exact
persisted file bytes. This gate specifically exercises fork/vfork, `execve`,
pipe, `dup2`, `wait4`, and descriptor inheritance. It is intentionally **not**
a claim of complete POSIX process support; signals, job control, blocking and
error edge cases, and broader process semantics need separate focused tests.
`make check-guest-syscalls` runs a deterministic native `strace` scenario over
dash and BusyBox applets, then requires its syscall inventory to match the
guest syscall status registry exactly.

Focused kernel tests drive the x86-64 syscall ABI, rather than only internal
helpers. They cover persistent regular-file writes and sparse gaps; shared
offsets after `dup`/`dup2`; the implemented `fcntl` descriptor/status flag
subset; `O_CREAT`, `O_TRUNC`, `O_APPEND`, `O_DIRECTORY`, and `O_CLOEXEC` state;
relative `openat`; synthetic `stat` fields; bounded `read`/`write`/`writev`;
directory `getdents64`; and `/dev/null` and `/dev/zero`. These tests do not
claim pipe, process, or exec semantics, which remain outside the current
milestone.

The generated compatibility registry is a public claim boundary. Differential
and focused syscall tests are required in addition to a registry entry; planned
and partial features are not advertised as implemented.
