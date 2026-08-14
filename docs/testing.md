# Testing

The reference baseline is the unmodified Blink submodule at
`f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580`.

On 2026-08-15, `scripts/check-upstream.sh` configured and built that revision,
then completed its original `make check` target successfully on x86-64 Debian.
The target downloaded and checksum-verified its pinned Cosmopolitan and
libc-test artifacts as defined by upstream Blink.

Local validation is split deliberately:

- `make check` runs zero-dependency Lua 5.2 unit and ELF end-to-end tests.
- `make check-differential` compares stdout, stderr, and exit status for
  generated x86-64 fixtures under native Linux, pinned native Blink, and the
  Lua port.
- `make check-craftos-pc` downloads and SHA-256 verifies CraftOS-PC 2.8.3,
  extracts the AppImage, mounts the checkout read-only, and runs the ELF smoke
  test in headless CraftOS before calling `os.shutdown(status)`.
- `make check-upstream` reproduces the pinned native Blink build and full
  upstream suite.

The generated compatibility registry is authoritative. Planned features are
not silently skipped and are not advertised as supported.
