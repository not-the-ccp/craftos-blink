# Compatibility

This file is generated from `src/craftos_blink/registry.lua`. A feature is supported only when its status is `implemented`; planned entries are not advertised by CPUID.

## Instructions

| Instruction | Encoding | Class | Status |
|---|---|---|---|
| ADD | `01/03/81.0/83.0` | integer | **implemented** |
| AND | `21/23/81.4/83.4` | integer | **implemented** |
| CALL | `E8/FF.2` | control | **implemented** |
| CMP | `39/3B/81.7/83.7` | integer | **implemented** |
| CPUID | `0F A2` | system | **implemented** |
| ENDBR64 | `F3 0F 1E FA` | control | **implemented** |
| IMUL | `0F AF/69/6B` | integer | **implemented** |
| Jcc | `70-7F/0F 80-8F` | control | **implemented** |
| JMP | `E9/EB/FF.4` | control | **implemented** |
| LEA | `8D` | integer | **implemented** |
| LEAVE | `C9` | control | **implemented** |
| MOV | `88-8B/B0-BF/C6/C7` | integer | **implemented** |
| MOVSX/MOVSXD/MOVZX | `0F BE/BF/B6/B7/63` | integer | **implemented** |
| NOP | `90/0F 1F` | control | **implemented** |
| OR | `09/0B/81.1/83.1` | integer | **implemented** |
| POP | `58-5F` | stack | **implemented** |
| PUSH | `50-57/68/6A/FF.6` | stack | **implemented** |
| RET | `C3` | control | **implemented** |
| SUB | `29/2B/81.5/83.5` | integer | **implemented** |
| SYSCALL | `0F 05` | system | **implemented** |
| TEST | `85/F7.0` | integer | **implemented** |
| XOR | `31/33/81.6/83.6` | integer | **implemented** |
| x87 | `D8-DF` | floating-point | **planned** |
| SSE2/SSE3/SSSE3 | `0F maps` | vector | **planned** |
| CLMUL/POPCNT/ADX/BMI2 | `0F maps` | extended | **planned** |
| privileged instructions | `system` | system | **fault** |

## Linux x86-64 syscalls

| Number | Name | Status |
|---:|---|---|
| 0 | `read` | **implemented** |
| 1 | `write` | **implemented** |
| 2 | `open` | **implemented** |
| 3 | `close` | **implemented** |
| 5 | `fstat` | **implemented** |
| 8 | `lseek` | **implemented** |
| 9 | `mmap` | **implemented** |
| 10 | `mprotect` | **implemented** |
| 11 | `munmap` | **implemented** |
| 12 | `brk` | **implemented** |
| 13 | `rt_sigaction` | **stubbed** |
| 14 | `rt_sigprocmask` | **stubbed** |
| 16 | `ioctl` | **stubbed** |
| 17 | `pread64` | **implemented** |
| 21 | `access` | **implemented** |
| 22 | `pipe` | **planned** |
| 32 | `dup` | **implemented** |
| 33 | `dup2` | **implemented** |
| 39 | `getpid` | **implemented** |
| 41 | `socket` | **local-only** |
| 53 | `socketpair` | **planned** |
| 56 | `clone` | **planned** |
| 57 | `fork` | **planned** |
| 59 | `execve` | **planned** |
| 60 | `exit` | **implemented** |
| 61 | `wait4` | **planned** |
| 62 | `kill` | **planned** |
| 63 | `uname` | **implemented** |
| 72 | `fcntl` | **stubbed** |
| 79 | `getcwd` | **implemented** |
| 89 | `readlink` | **implemented** |
| 158 | `arch_prctl` | **implemented** |
| 186 | `gettid` | **implemented** |
| 202 | `futex` | **planned** |
| 218 | `set_tid_address` | **implemented** |
| 228 | `clock_gettime` | **implemented** |
| 231 | `exit_group` | **implemented** |
| 257 | `openat` | **implemented** |
| 262 | `newfstatat` | **implemented** |
| 273 | `set_robust_list` | **implemented** |
| 302 | `prlimit64` | **implemented** |
| 318 | `getrandom` | **implemented** |
| other | `unknown` | **ENOSYS** |
| AF_INET | `external networking` | **EAFNOSUPPORT** |

## Deliberate boundaries

- AF_INET and AF_INET6 are unavailable because standard CC:Tweaked exposes no raw TCP/UDP socket API. AF_UNIX remains planned.
- JIT, BIOS, real mode, PC hardware, and the blinkenlights debugger UI are not part of this userspace port.
- x87 and vector/extended instruction families are listed as planned until their differential suites pass. Blink's reduced x87 long-double precision boundary will be retained and documented when enabled.
- The in-game profile uses only standard ComputerCraft APIs and requires attached storage for a glibc guest root.
