/* Henge probe: 三件可观察的事 —— 取指执行、MMIO 写、WFI。
 * 链接到 0x40080000（-M virt 的 kernel 加载点），全部 PC 相对寻址。 */
    .section .text
    .globl _start
_start:
    movz x1, #0x0900, lsl #16      /* PL011 DR on -M virt */
    adr  x2, msg
1:  ldrb w3, [x2], #1               /* post-index 取字节 */
    cbz  w3, 2f
    strb w3, [x1]                   /* MMIO 写：走引擎 catch-all → QEMU pl011 */
    b    1b
2:  movz x1, #0x0900, lsl #16
    mov  w3, #10                    /* '\n' */
    strb w3, [x1]
3:  wfi                             /* HENGE_EXIT_WFI，干净退出 */
    b    3b
msg:
    .asciz "HENGE-MMIO-OK"
