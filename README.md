# CraftOS Blink

CraftOS Blink is a pure Lua 5.2 x86-64 Linux userspace emulator for
ComputerCraft. It is a direct port of the interpreter design and behavior in
[Blink](https://github.com/jart/blink), pinned at
`f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580`.

The primary target is CraftOS-PC 2.8.3. A constrained `ingame` profile uses
the same CPU and kernel implementation with smaller resource limits and only
standard CC:Tweaked APIs.

> **Alpha status:** static ELF64 syscall fixtures run end to end, and ELF64 PIE,
> `PT_INTERP`, System V stack/auxv, sparse memory, and the initial Linux ABI are
> implemented. Dynamic glibc execution, complete Blink ISA coverage, processes,
> signals, futexes, and AF_UNIX are not complete. Consult
> `docs/compatibility.md`; do not assume an unlisted or planned facility works.

## Reproducible setup

```sh
git clone --recurse-submodules https://github.com/not-the-ccp/craftos-blink.git
cd craftos-blink
./scripts/bootstrap-host.sh
./scripts/bootstrap-craftos-pc.sh
./scripts/check-upstream.sh
```

Downloaded binaries, extracted AppImages, generated root filesystems, and
test artifacts are stored below ignored `.cache/`, `build/`, and `rootfs/`
directories.

## Interface

```text
craftos-blink [options] PROGRAM [ARG...]
```

The Lua API is `require("craftos_blink").run(config)`. See
`docs/architecture.md` for the port boundary and invariants.

```lua
local blink = require("craftos_blink")
local result = blink.run {
  root = "guest-root",
  program = "/bin/program",
  argv = { "/bin/program", "argument" },
  environment = { LANG = "C" },
  profile = "craftos-pc",
}
```

The result contains `exit_code`, `signal`, `instructions`, `syscalls`, and
`elapsed_ms`. Malformed ELF, host configuration, guest fault, and resource
limit failures have distinct structured error classes.

## Tests and release assets

See `docs/testing.md` for native Blink, differential, and CraftOS-PC commands.
`make package` creates standalone API and CLI Lua files, SHA-256 checksums, and
an `.tar.xz` archive containing exactly one top-level directory.

## License

CraftOS Blink is ISC licensed. Blink attribution and its original ISC license
are preserved in `NOTICE`, `LICENSES/Blink-ISC.txt`, and the pinned upstream
submodule.
