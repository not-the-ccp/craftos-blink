.global _start
.section .text
_start:
  mov $5, %rax
  mov $7, %rcx
  add %rcx, %rax
  cmp $12, %rax
  jne failed
  push %rax
  pop %rdx
  sub $2, %rdx
  cmp $10, %rdx
  jne failed
  mov $60, %eax
  mov $42, %edi
  syscall
failed:
  mov $60, %eax
  mov $99, %edi
  syscall

