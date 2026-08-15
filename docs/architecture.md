# Architecture and port boundary

CraftOS Blink ports Blink's userspace interpreter, instruction semantics, ELF
loader, and Linux ABI translations to Lua 5.2. The JIT, BIOS/real mode PC,
hardware emulation, and blinkenlights debugger UI are outside this project.

## Enforced invariants

- Every guest integer is represented as normalized 32-bit words. A 64-bit
  value is `{lo, hi}` and a 128-bit value is two such pairs.
- Lua numbers are used for addresses only after proving the address is a
  canonical userspace value below `2^53`.
- Guest memory is a sparse table of 4096-byte pages. Permissions, shared
  backing, copy-on-write ownership, and executable-page generation are page
  metadata, never inferred from Lua tables.
- Decode and execution are separate. The compatibility registry generates the
  public matrix, while differential fixtures verify the executable decoder.
- Linux ABI errors are returned as negative errno values. Unsupported syscalls
  never report success.
- The POSIX adapter canonicalizes paths and rejects resolved host-symlink
  escapes. ComputerCraft uses its native, symlink-free filesystem adapter.
- File descriptors refer to open-file descriptions. `dup`/`dup2` and the
  supported `fcntl` duplication operations share an offset and status flags;
  descriptor-local close-on-exec flags remain separate.
- Regular-file writes are committed to the guest VFS before `write`/`writev`
  returns. Live descriptions of the same path consequently observe truncation
  and writes immediately.
- The single-process VM yields after an instruction or time slice and never
  assumes native Lua threads.

## Alpha gaps

The VFS has a deliberately small metadata model: `stat`/`fstat`/`newfstatat`
report synthetic device, inode, mode, size, block-size, and block-count fields.
Creation modes and `umask` state are accepted but are not yet enforced, and
timestamps, ownership, links, and durable sidecar POSIX metadata are absent.

`open`/`openat` support access mode plus `O_CREAT`, `O_EXCL`, `O_TRUNC`,
`O_APPEND`, `O_DIRECTORY`, and `O_CLOEXEC`; the final flag is recorded for the
future `execve` implementation. Relative `openat` requires an open directory
descriptor. Directory reads use bounded `getdents64` records, while `/dev/null`
and `/dev/zero` have their normal discard/EOF and zero-read behavior. Guest I/O
requests are bounded to prevent a single syscall from exhausting host memory.

There is no pipe, `fork`/`clone`, `execve`, `wait`, or cooperative process model
yet, so descriptor inheritance and close-on-exec behavior are not active. REP
instructions are not yet chunked within a single CPU step. The POSIX adapter
prevents ordinary resolved symlink escapes, but it is not a race-proof native
`openat(2)` sandbox and cannot close races caused by a concurrently mutating
host filesystem. Do not expose an untrusted host tree as the guest root.

The compatibility registry distinguishes complete, partial, planned, and
faulting facilities. Only `implemented` entries are release claims.

## Profiles

`craftos-pc` defaults to 256 MiB guest memory and a 10,000-instruction outer
slice. `ingame` defaults to 16 MiB and a 2,000-instruction outer slice. Process
limits are reserved by the profiles but are not active until the cooperative
process scheduler lands. The in-game profile requires attached storage for the
dash/BusyBox root; normal computer quotas are not sufficient.
