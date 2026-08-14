.global _start
.section .text
_start:
  mov $1, %eax
  mov $1, %edi
  lea message(%rip), %rsi
  mov $message_end-message, %edx
  syscall
  mov $60, %eax
  xor %edi, %edi
  syscall
.section .rodata
message:
  .ascii "hello from x86-64\n"
message_end:

