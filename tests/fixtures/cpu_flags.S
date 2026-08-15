.global _start
.section .text

.set snapshot_offset, 0
.macro snapshot tag, mask
  pushfq
  pop %r11
  and $\mask, %r11d
  movabs $\tag, %r10
  mov %r10, snapshots+snapshot_offset(%rip)
  mov %rax, snapshots+snapshot_offset+8(%rip)
  mov %rdx, snapshots+snapshot_offset+16(%rip)
  mov %r11, snapshots+snapshot_offset+24(%rip)
  .set snapshot_offset, snapshot_offset + 32
.endm

_start:
  # Signed overflow, auxiliary carry, and sign/zero/parity flags.
  movabs $0x7fffffffffffffff, %rax
  mov $1, %rdx
  add %rdx, %rax
  snapshot 1, 0xcd5

  mov $0, %rax
  mov $1, %rdx
  cmp %rdx, %rax
  mov $7, %rax
  adc $0, %rax
  snapshot 2, 0xcd5

  mov $0, %rax
  mov $1, %rdx
  cmp %rdx, %rax
  mov $7, %rax
  sbb $0, %rax
  snapshot 3, 0xcd5

  # Count-zero shifts preserve flags; rotates define only carry/overflow.
  mov $0, %rax
  cmp $1, %rax
  movabs $0x8000000000000001, %rax
  shl $0, %rax
  snapshot 4, 0xcd5

  movabs $0x8000000000000001, %rax
  rol $1, %rax
  snapshot 5, 0x801

  # Signed multiply and unsigned divide exercise full register results.
  mov $-7, %rax
  imul $9, %rax, %rax
  snapshot 6, 0x801

  mov $79, %rax
  xor %rdx, %rdx
  mov $39, %rcx
  div %rcx
  snapshot 7, 0

  mov $1, %rax
  mov $5, %rdx
  bt %rdx, %rax
  snapshot 8, 1

  mov $0x80000000, %eax
  rol $1, %eax
  snapshot 9, 0x801

  movabs $0x1122334455667788, %rax
  mov $0xaa, %ah
  snapshot 10, 0

  mov $-1, %rax
  mov $2, %rcx
  mul %rcx
  snapshot 11, 0x801

  mov $1, %rdx
  xor %rax, %rax
  mov $2, %rcx
  div %rcx
  snapshot 12, 0

  mov $-1, %rdx
  xor %rax, %rax
  mov $2, %rcx
  idiv %rcx
  snapshot 13, 0

  mov $0x100, %rdx
  bsf %rdx, %rax
  snapshot 14, 0x40

  movabs $0x1122334455667788, %rax
  bswap %rax
  snapshot 15, 0

  mov $5, %rax
  mov $7, %rdx
  xchg %rax, %rdx
  snapshot 16, 0

  mov $5, %rax
  mov $7, %rdx
  xadd %rdx, %rax
  snapshot 17, 0xcd5

  mov $5, %rax
  mov $5, %rdx
  mov $9, %rcx
  cmpxchg %rcx, %rdx
  snapshot 18, 0xcd5

  movabs $0x8000000000000000, %rax
  mov $1, %rdx
  shld $1, %rdx, %rax
  snapshot 19, 0x8c5

  mov $1, %rax
  movabs $0x8000000000000000, %rdx
  shrd $1, %rdx, %rax
  snapshot 20, 0x8c5

  mov $1, %eax
  mov $1, %edi
  lea snapshots(%rip), %rsi
  mov $snapshot_offset, %edx
  syscall

  mov $60, %eax
  xor %edi, %edi
  syscall

.section .bss
.balign 16
snapshots:
  .skip snapshot_offset
