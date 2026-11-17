/* passt 后端：用宿主内核的原生 socket 代替 libslirp 的用户态协议栈。 */
#ifndef HV_NET_PASST_LINUX_H
#define HV_NET_PASST_LINUX_H

#include "machine.h"
#include "virtio_net.h"

/* 起 passt 进程并接管 n 的收发。0 = 成功。 */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* tick 里调（vCPU 线程）：把 passt 送来的帧交给 guest。 */
void hv_net_poll(void);
void hv_net_shutdown(void);
void hv_net_add_hostfwd(int host_port, int guest_port);
void hv_net_set_share_socket(const char *path);

#endif
