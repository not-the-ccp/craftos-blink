# CraftOS Blink

CraftOS Blink is a pure Lua 5.2 x86-64 Linux userspace emulator for
ComputerCraft. It is a direct port of the interpreter design and behavior in
[Blink](https://github.com/jart/blink), pinned at
`f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580`.

The primary target is CraftOS-PC 2.8.3. A constrained `ingame` profile uses
the same CPU and kernel implementation with smaller resource limits and only
standard CC:Tweaked APIs.

> **Development status:** the port is being built subsystem by subsystem.
> Consult `docs/compatibility.md` for the generated, exact support boundary;
> do not assume an unlisted instruction or syscall is implemented.

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

## Planned interface

```text
craftos-blink [options] PROGRAM [ARG...]
```

The Lua API is `require("craftos_blink").run(config)`. See
`docs/architecture.md` for the port boundary and invariants.

## License

CraftOS Blink is ISC licensed. Blink attribution and its original ISC license
are preserved in `NOTICE`, `LICENSES/Blink-ISC.txt`, and the pinned upstream
submodule.

