/* Linux 客户机的虚拟平台：沿用引擎里 HvWinVirt 这个板子的结构体（字段够用），
   但创建/复位的语义按 Linux 直接启动来写。 */
#ifndef HV_LINUXVIRT_H
#define HV_LINUXVIRT_H

#include <stddef.h>
#include <stdint.h>

#include "winvirt.h" /* HvWinVirt 结构体与标准 virt 地址常量 */

/* 与 QEMU -M virt 一致的物理布局，只少了 pflash 那 128 MB。 */
#define LINUXVIRT_GIC_DIST_PA  0x08000000ULL
#define LINUXVIRT_GIC_ITS_PA   0x08080000ULL
#define LINUXVIRT_GIC_TRANSLATER 0x08090040ULL
#define LINUXVIRT_GIC_REDIST_PA 0x080a0000ULL
#define LINUXVIRT_UART_PA      0x09000000ULL
#define LINUXVIRT_RTC_PA       0x09010000ULL
#define LINUXVIRT_GPIO_PA      0x09030000ULL
#define LINUXVIRT_PCIE_MMIO_PA 0x10000000ULL
#define LINUXVIRT_PCIE_MMIO_SZ 0x2eff0000ULL
#define LINUXVIRT_PCIE_PIO_PA  0x3eff0000ULL
#define LINUXVIRT_PCIE_PIO_SZ  0x00010000ULL
#define LINUXVIRT_RAM_PA       0x40000000ULL
#define LINUXVIRT_PCIE_ECAM_PA 0x4010000000ULL
#define LINUXVIRT_PCIE_ECAM_SZ 0x10000000ULL
#define LINUXVIRT_PCIE_HIGH_PA 0x8000000000ULL
#define LINUXVIRT_PCIE_HIGH_SZ 0x8000000000ULL

#define LINUXVIRT_INTID_UART   (32 + 1)
#define LINUXVIRT_INTID_RTC    (32 + 2)
#define LINUXVIRT_INTID_PCIE   (32 + 3)
#define LINUXVIRT_INTID_GPIO   (32 + 7)

#define LINUXVIRT_KERNEL_OFFSET 0x00080000ULL /* arm64 Image 的 text_offset */

int hv_linuxvirt_create(HvWinVirt *b, HvMachine *m, HvCpu *cpus, int ncpus, uint64_t ram_size,
                        const uint8_t *kernel, size_t kernel_size, uint64_t text_offset,
                        HvDisk *disk, const uint8_t mac[6]);
void hv_linuxvirt_reset_cpu(HvWinVirt *b, uint64_t kernel_entry);

#endif
