.global _start
.section .text
_start:
prompt:
  mov $1, %eax
  mov $1, %edi
  lea prompt_text(%rip), %rsi
  mov $prompt_end-prompt_text, %edx
  syscall

  xor %eax, %eax
  xor %edi, %edi
  lea buffer(%rip), %rsi
  mov $64, %edx
  syscall
  test %rax, %rax
  jle done
  cmpl $0x74697865, buffer(%rip)
  je done
  cmpl $0x706c6568, buffer(%rip)
  je show_help
  cmpl $0x6d616e75, buffer(%rip)
  je show_uname
  cmpl $0x6f686365, buffer(%rip)
  je echo_text

unknown:
  mov $1, %eax
  mov $1, %edi
  lea unknown_text(%rip), %rsi
  mov $unknown_end-unknown_text, %edx
  syscall
  jmp prompt

show_help:
  mov $1, %eax
  mov $1, %edi
  lea help_text(%rip), %rsi
  mov $help_end-help_text, %edx
  syscall
  jmp prompt

show_uname:
  mov $1, %eax
  mov $1, %edi
  lea uname_text(%rip), %rsi
  mov $uname_end-uname_text, %edx
  syscall
  jmp prompt

echo_text:
  cmp $5, %rax
  jle prompt
  mov %rax, %rdx
  sub $5, %edx
  mov $1, %eax
  mov $1, %edi
  lea buffer+5(%rip), %rsi
  syscall
  jmp prompt

done:
  mov $1, %eax
  mov $1, %edi
  lea goodbye(%rip), %rsi
  mov $goodbye_end-goodbye, %edx
  syscall
  mov $60, %eax
  xor %edi, %edi
  syscall

.section .rodata
prompt_text:
  .ascii "minish$ "
prompt_end:
help_text:
  .ascii "built-ins: echo TEXT, uname, help, exit\n"
help_end:
uname_text:
  .ascii "Linux craftos 6.6.0-craftos-blink x86_64\n"
uname_end:
unknown_text:
  .ascii "minish: unknown command (try help)\n"
unknown_end:
goodbye:
  .ascii "bye from x86-64\n"
goodbye_end:

.section .bss
.align 16
buffer:
  .skip 64
