.global _start
.section .text

_start:
  # Aligned and unaligned packed moves.  The MOVDQU destination deliberately
  # starts one byte into the output buffer.
  movaps vector_a(%rip), %xmm0
  movaps %xmm0, output(%rip)
  movdqa vector_b(%rip), %xmm1
  movdqa %xmm1, output+16(%rip)
  movdqu vector_unaligned+1(%rip), %xmm2
  movdqu %xmm2, output+33(%rip)

  # Snapshot each narrow baseline operation so native Linux, Blink, and the
  # Lua interpreter compare the exact 128-bit result.
  movhlps %xmm1, %xmm0
  movdqu %xmm0, output+64(%rip)
  paddq %xmm1, %xmm0
  movdqu %xmm0, output+80(%rip)
  por %xmm2, %xmm0
  movdqu %xmm0, output+96(%rip)
  psubq %xmm1, %xmm0
  movdqu %xmm0, output+112(%rip)
  punpckldq %xmm2, %xmm0
  movdqu %xmm0, output+128(%rip)
  psrldq $5, %xmm0
  movdqu %xmm0, output+144(%rip)
  xorps %xmm1, %xmm0
  movdqu %xmm0, output+160(%rip)
  pause

  mov $1, %eax
  mov $1, %edi
  lea output(%rip), %rsi
  mov $176, %edx
  syscall
  mov $60, %eax
  xor %edi, %edi
  syscall

.section .rodata
.balign 16
vector_a:
  .long 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00
.balign 16
vector_b:
  .long 0x01020304, 0x05060708, 0x0a0b0c0d, 0x0e0f1011
.balign 16
vector_unaligned:
  .byte 0
  .long 0xdeadbeef, 0x76543210, 0x0badf00d, 0xcafebabe

.section .bss
.balign 16
output:
  .skip 176
