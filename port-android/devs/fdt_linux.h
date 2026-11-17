#ifndef HV_FDT_LINUX_H
#define HV_FDT_LINUX_H
#include <stddef.h>
#include <stdint.h>
/* hv_fdt_build_linuxvirt: 与 devices/fdt.h 里同名函数一致，只是少了
   UEFI 才需要的 fw-cfg 与 pflash 节点（Linux 直接启动用不到，
   而那两块地址在 Linux 板上没有设备，留着会让驱动 probe 时 abort）。 */
uint8_t *hv_fdt_build_linuxvirt(int ncpus, uint64_t ram_base, uint64_t ram_size, size_t *out_size);
#endif
