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

The generated compatibility registry is a public claim boundary. Differential
and focused syscall tests are required in addition to a registry entry; planned
and partial features are not advertised as implemented.
