/* Henge MMIO 读探针：把"写能用"与"读能用"分开验证
 *
 * 之前的 probe.S 只做了 MMIO **写**（向 PL011 打字符串）。读路径从没测过，
 * 而 ECAM 枚举完全依赖它 —— 这次实测 ECAM 读回 0，正好暴露了这个缺口。
 *
 * 三个读点，各有不同的意义：
 *   0x09000018  PL011 UARTFR   一个必然存在的设备寄存器（TXFE 位应为 1）
 *   0x09000000  PL011 UARTDR   数据寄存器，读它就是消费一个字节
 *   0x40000000  RAM            对照：普通内存必须能读
 *   0x4010000000 pcie ECAM     >4 GiB 的地址，验证高地址 MMIO
 *
 * 输出全是十六进制，与 tcg 逐行对照。
 */
    .section .text
    .globl _start
_start:
    adr  x1, stack0_top
    mov  sp, x1

    adr  x2, m_begin
    bl   puts

    /* RAM：先写后读，确认基础回路 */
    movz x9, #0x4000, lsl #16
    movz w10, #0xbeef
    str  w10, [x9]
    ldr  w11, [x9]
    adr  x2, m_ram
    bl   puts
    mov  x0, x11
    bl   hex

    /* PL011 UARTFR：设备寄存器读 */
    movz x9, #0x0900, lsl #16
    ldr  w11, [x9, #0x18]
    adr  x2, m_fr
    bl   puts
    mov  x0, x11
    bl   hex

    /* 4 GiB 之上的 MMIO（pcie ECAM）：高地址读 */
    movz x9, #0x0000
    movk x9, #0x1000, lsl #16
    movk x9, #0x0040, lsl #32
    ldr  w11, [x9]
    adr  x2, m_ecam
    bl   puts
    mov  x0, x11
    bl   hex

    /* 再读一次，看是否稳定（区分"偶发"与"恒定"） */
    ldr  w11, [x9]
    adr  x2, m_ecam2
    bl   puts
    mov  x0, x11
    bl   hex

    adr  x2, m_end
    bl   puts
1:  wfi
    b    1b

puts:
    movz x1, #0x0900, lsl #16
2:  ldrb w3, [x2], #1
    cbz  w3, 3f
    strb w3, [x1]
    b    2b
3:  ret

hex:
    movz x1, #0x0900, lsl #16
    mov  x9, #60
4:  lsr  x10, x0, x9
    and  x10, x10, #0xf
    cmp  x10, #10
    b.lo 5f
    add  x10, x10, #('a' - 10)
    b    6f
5:  add  x10, x10, #'0'
6:  strb w10, [x1]
    subs x9, x9, #4
    b.ge 4b
    mov  w10, #10
    strb w10, [x1]
    ret

    .p2align 4
stack0:  .space 0x4000
stack0_top:

m_begin: .asciz "MMRD-BEGIN\n"
m_ram:   .asciz "RAM="
m_fr:    .asciz "UARTFR="
m_ecam:  .asciz "ECAM0="
m_ecam2: .asciz "ECAM1="
m_end:   .asciz "MMRD-END\n"
