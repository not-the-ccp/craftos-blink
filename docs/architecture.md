# Architecture and port boundary

CraftOS Blink ports Blink's userspace interpreter, instruction semantics, ELF
loader, and Linux ABI translations to Lua 5.2. The JIT, BIOS/real mode PC,
hardware emulation, and blinkenlights debugger UI are outside this project.

## Invariants

- Every guest integer is represented as normalized 32-bit words. A 64-bit
  value is `{lo, hi}` and a 128-bit value is two such pairs.
- Lua numbers are used for addresses only after proving the address is a
  canonical userspace value below `2^53`.
- Guest memory is a sparse table of 4096-byte pages. Permissions, shared
  backing, copy-on-write ownership, and executable-page generation are page
  metadata, never inferred from Lua tables.
- Decode and execution are separate. The opcode registry is the single source
  for dispatch and the generated compatibility document.
- Linux ABI errors are returned as negative errno values. Unsupported syscalls
  never report success.
- Host paths are resolved under one configured root and checked component by
  component. Sidecar metadata preserves POSIX fields missing from CraftOS.
- Scheduling is cooperative. The VM yields after an instruction or time slice,
  and never assumes native Lua threads.

## Profiles

`craftos-pc` defaults to 256 MiB guest memory, 1024 mappings, and 64 processes.
`ingame` defaults to 16 MiB guest memory, 256 mappings, and 8 processes. The
in-game profile requires external storage for a glibc root; normal computer
quotas are not sufficient.

