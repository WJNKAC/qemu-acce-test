    .section .text.start,"ax"
    .globl _start
_start:
    bl  c_start
1:  wfi
    b   1b
