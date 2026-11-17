/* Linux aarch64 客户机的虚拟平台。
 *
 * 复用引擎里已有的 devices/（GICv3 + ITS、PL011、PL031、PL061、PCIe GPEX、
 * virtio-net、NVMe），但走的是和 Windows 完全不同的启动路径：
 *
 *   Windows: pflash0 里的 EDK2 UEFI → ACPI → ntoskrnl
 *   Linux  : 直接把 Image 铺到 RAM + 0x80000，x0 给 DTB → start_kernel
 *
 * 所以这里不要 pflash、不要 ACPI、不要 fw_cfg，只有 RAM + DTB + 一组
 * 'linux,dummy-virt' 风格的外设。fdt.c 生成的树本来就是这个形状
 * （PSCI 走 hvc、GICv3、PL011、PCIe ECAM generic），Linux 直接认。
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "dispatch.h"
#include "fdt_linux.h"
#include "linuxvirt.h"
#include "mmu.h"
#include "timer.h"

#define DT_BASE_OFFSET 0x08000000ULL /* DTB 放在 RAM+128MB：内核 Image 铺在 +512KB，别打架 */

static uint64_t tick_locked(HvMachine *m, HvCpu *cpu) {
    HvWinVirt *b = m->tick_opaque;
    uint64_t deadline = hv_timer_update(b->gic, cpu);
    if (cpu->index != 0) return deadline;
    hv_pl031_tick(b->rtc);
    if (b->poll) b->poll();
    return deadline;
}

static uint64_t tick(HvMachine *m, HvCpu *cpu) {
    if (cpu->index != 0) return hv_timer_update(((HvWinVirt *)m->tick_opaque)->gic, cpu);
    hv_dev_lock(m);
    uint64_t deadline = tick_locked(m, cpu);
    hv_dev_unlock(m);
    return deadline;
}

static void uart_stdout_cb(void *opaque, uint8_t c) {
    (void)opaque;
    fputc(c, stderr);
    if (c == '\n') fflush(stderr);
}

int hv_linuxvirt_create(HvWinVirt *b, HvMachine *m, HvCpu *cpus, int ncpus, uint64_t ram_size,
                        const uint8_t *kernel, size_t kernel_size, uint64_t text_offset,
                        HvDisk *disk, const uint8_t mac[6]) {
    memset(b, 0, sizeof *b);
    b->m = m;
    b->cpu = cpus;
    b->ncpus = ncpus;
    b->ram_size = ram_size;

    /* 1. 客机 RAM：普通匿名映射。这里没有 iOS 的 Jetsam，不需要 ledger 那一套。 */
    void *ram = mmap(NULL, ram_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) {
        fprintf(stderr, "linuxvirt: cannot map %llu MB of guest RAM\n", (unsigned long long)(ram_size >> 20));
        return -1;
    }
    b->ram = ram;

    /* 2. 设备树：和 UEFI 路径共用同一个生成器，它就是 'linux,dummy-virt'。 */
    b->dtb = hv_fdt_build_linuxvirt(ncpus, LINUXVIRT_RAM_PA, ram_size, &b->dtb_size);
    if (!b->dtb || b->dtb_size > (1u << 20)) {
        fprintf(stderr, "linuxvirt: device tree build failed\n");
        return -1;
    }

    /* 3. 把内核 Image 铺到 RAM + 0x80000（arm64 Image 的 text_offset）。 */
    if (!kernel || kernel_size == 0 || kernel_size + text_offset > ram_size) return -1;
    memcpy(b->ram + text_offset, kernel, kernel_size);

    hv_machine_add_ram(m, LINUXVIRT_RAM_PA, ram_size, b->ram, 0);

    /* 4. 中断控制器：GICv3 + ITS（PCIe 的 MSI-X 走 LPI） */
    b->gic = hv_gicv3_create(m, LINUXVIRT_GIC_DIST_PA, LINUXVIRT_GIC_REDIST_PA);
    b->its = hv_gicv3_its_create(m, b->gic, LINUXVIRT_GIC_ITS_PA);

    /* 5. 平台外设。Linux 侧对应 8250/PL011（console=ttyAMA0）、pl031 rtc、pl061 gpio。 */
    b->uart = hv_pl011_create(m, b->gic, LINUXVIRT_UART_PA, LINUXVIRT_INTID_UART);
    b->uart->output = uart_stdout_cb;
    b->rtc = hv_pl031_create(m, b->gic, LINUXVIRT_RTC_PA, LINUXVIRT_INTID_RTC);
    b->gpio = hv_pl061_create(m, b->gic, LINUXVIRT_GPIO_PA, LINUXVIRT_INTID_GPIO);

    /* 6. PCIe：virtio-net，加一块 NVMe 做真文件系统（有盘时）。 */
    b->pcie = hv_pcie_create(m, b->gic, LINUXVIRT_PCIE_ECAM_PA, LINUXVIRT_PCIE_ECAM_SZ,
                             LINUXVIRT_PCIE_MMIO_PA, LINUXVIRT_PCIE_MMIO_SZ, LINUXVIRT_INTID_PCIE);
    hv_pcie_add_pio(b->pcie, LINUXVIRT_PCIE_PIO_PA, LINUXVIRT_PCIE_PIO_SZ);
    hv_pcie_add_high_mmio(b->pcie, LINUXVIRT_PCIE_HIGH_PA, LINUXVIRT_PCIE_HIGH_SZ);
    hv_pcie_set_gpex_swizzle(b->pcie, 1);
    hv_pcie_set_its(b->pcie, b->its, LINUXVIRT_GIC_TRANSLATER);
    if (mac) b->net = hv_virtio_net_create(m, b->pcie, mac);
    if (disk) b->nvme0 = hv_nvme_create(m, b->pcie, disk, "HV-LINUX-01");

    m->tick = tick;
    m->tick_opaque = b;
    return 0;
}

void hv_linuxvirt_reset_cpu(HvWinVirt *b, uint64_t kernel_entry) {
    /* DTB 落到 RAM+128MB，写进 RAM 里（内核会用 x0 指的那份） */
    uint8_t *dt = b->ram + DT_BASE_OFFSET;
    memcpy(dt, b->dtb, b->dtb_size);
    uint64_t dtb_pa = LINUXVIRT_RAM_PA + DT_BASE_OFFSET;

    for (int i = 0; i < b->ncpus; i++) {
        HvCpu *c = &b->cpu[i];
        hv_cpu_reset_index(c, b->m, (uint32_t)i);
        c->mpidr = 0x80000000ULL | (uint32_t)i;
        c->pc = kernel_entry;
        c->x[0] = dtb_pa;  /* arm64 boot protocol: x0 = DTB */
        c->off = (i != 0); /* 只有 CPU0 起跑，其余等 PSCI CPU_ON */
        c->halted = 0;
    }
}
