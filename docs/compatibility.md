# Compatibility

This file is generated from `src/craftos_blink/registry.lua`. A feature is supported only when its status is `implemented`; planned entries are not advertised by CPUID.

## Instructions

| Instruction | Encoding | Class | Status |
|---|---|---|---|
| ADD | `01/03/81.0/83.0` | integer | **implemented** |
| AND | `21/23/81.4/83.4` | integer | **implemented** |
| BSF/BSWAP | `0F BC/0F C8-CF` | integer | **implemented** |
| CALL | `E8/FF.2` | control | **implemented** |
| CMP | `39/3B/81.7/83.7` | integer | **implemented** |
| CMPXCHG/XADD/XCHG | `0F B0-B1/0F C0-C1/86-87/90-97` | atomic | **implemented** |
| CPUID | `0F A2` | system | **implemented** |
| ENDBR64 | `F3 0F 1E FA` | control | **implemented** |
| IMUL | `0F AF/69/6B` | integer | **implemented** |
| Jcc | `70-7F/0F 80-8F` | control | **implemented** |
| JMP | `E9/EB/FF.4` | control | **implemented** |
| LEA | `8D` | integer | **implemented** |
| LEAVE | `C9` | control | **implemented** |
| MOV | `88-8B/B0-BF/C6/C7` | integer | **implemented** |
| MOVAPS/MOVDQA | `0F 28/29, 66 0F 6F/7F` | vector | **implemented** |
| MOVDQU | `F3 0F 6F/7F` | vector | **implemented** |
| MOVHLPS | `0F 12 C0-FF` | vector | **implemented** |
| MOVSX/MOVSXD/MOVZX | `0F BE/BF/B6/B7/63` | integer | **implemented** |
| NOP | `90/0F 1F` | control | **implemented** |
| PAUSE | `F3 90` | control | **implemented** |
| OR | `09/0B/81.1/83.1` | integer | **implemented** |
| PADDQ/POR/PSUBQ | `66 0F D4/EB/FB` | vector | **implemented** |
| POP | `58-5F` | stack | **implemented** |
| PUSH | `50-57/68/6A/FF.6` | stack | **implemented** |
| PSRLDQ | `66 0F 73 /3 ib` | vector | **implemented** |
| PUNPCKLDQ | `66 0F 62` | vector | **implemented** |
| RET | `C3` | control | **implemented** |
| SHLD/SHRD | `0F A4-A5/0F AC-AD` | integer | **implemented** |
| SUB | `29/2B/81.5/83.5` | integer | **implemented** |
| SYSCALL | `0F 05` | system | **implemented** |
| TEST | `85/F7.0` | integer | **implemented** |
| XOR | `31/33/81.6/83.6` | integer | **implemented** |
| XORPS | `0F 57` | vector | **implemented** |
| x87 | `D8-DF` | floating-point | **planned** |
| SSE2/SSE3/SSSE3 | `0F maps` | vector | **planned** |
| CLMUL/POPCNT/ADX/BMI2 | `0F maps` | extended | **planned** |
| privileged instructions | `system` | system | **fault** |

## Linux x86-64 syscalls

| Number | Name | Status |
|---:|---|---|
| 0 | `read` | **bounded-fd-subset** |
| 1 | `write` | **bounded-fd-subset** |
| 2 | `open` | **filesystem-subset** |
| 3 | `close` | **implemented** |
| 4 | `stat` | **metadata-subset** |
| 5 | `fstat` | **metadata-subset** |
| 6 | `lstat` | **metadata-subset** |
| 8 | `lseek` | **regular-file-subset** |
| 9 | `mmap` | **anonymous-subset** |
| 10 | `mprotect` | **mapping-subset** |
| 11 | `munmap` | **mapping-subset** |
| 12 | `brk` | **implemented** |
| 13 | `rt_sigaction` | **state-only** |
| 14 | `rt_sigprocmask` | **state-only** |
| 16 | `ioctl` | **terminal-subset** |
| 17 | `pread64` | **planned** |
| 20 | `writev` | **bounded-fd-subset** |
| 21 | `access` | **path-subset** |
| 22 | `pipe` | **cooperative-subset** |
| 32 | `dup` | **implemented** |
| 33 | `dup2` | **implemented** |
| 39 | `getpid` | **implemented** |
| 110 | `getppid` | **implemented** |
| 41 | `socket` | **local-only** |
| 53 | `socketpair` | **planned** |
| 56 | `clone` | **planned** |
| 57 | `fork` | **cooperative-subset** |
| 58 | `vfork` | **fork-semantics** |
| 59 | `execve` | **ELF-subset** |
| 60 | `exit` | **implemented** |
| 61 | `wait4` | **child-subset** |
| 62 | `kill` | **planned** |
| 63 | `uname` | **implemented** |
| 72 | `fcntl` | **descriptor-subset** |
| 79 | `getcwd` | **implemented** |
| 80 | `chdir` | **implemented** |
| 83 | `mkdir` | **metadata-subset** |
| 89 | `readlink` | **planned** |
| 95 | `umask` | **state-only** |
| 107 | `geteuid` | **implemented** |
| 158 | `arch_prctl` | **implemented** |
| 186 | `gettid` | **implemented** |
| 202 | `futex` | **planned** |
| 217 | `getdents64` | **filesystem-subset** |
| 218 | `set_tid_address` | **state-only** |
| 228 | `clock_gettime` | **clock-subset** |
| 231 | `exit_group` | **implemented** |
| 257 | `openat` | **filesystem-subset** |
| 262 | `newfstatat` | **metadata-subset** |
| 273 | `set_robust_list` | **state-only** |
| 302 | `prlimit64` | **planned** |
| 318 | `getrandom` | **deterministic-subset** |
| other | `unknown` | **ENOSYS** |
| AF_INET | `external networking` | **EAFNOSUPPORT** |

## Deliberate boundaries

- AF_INET and AF_INET6 are unavailable because standard CC:Tweaked exposes no raw TCP/UDP socket API. AF_UNIX remains planned.
- JIT, BIOS, real mode, PC hardware, and the blinkenlights debugger UI are not part of this userspace port.
- x87 and vector/extended instruction families are listed as planned until their differential suites pass. Blink's reduced x87 long-double precision boundary will be retained and documented when enabled.
- The in-game profile uses only standard ComputerCraft APIs and requires attached storage for a glibc guest root.
