/* slirp 后端（备用）：纯用户态 TCP/IP 栈。
   passt 是首选（用宿主内核 socket），这个留着做对照和在 passt 不可用时兜底。 */
#ifndef HV_NET_SLIRP_LINUX_H
#define HV_NET_SLIRP_LINUX_H
#include "machine.h"
#include "virtio_net.h"
int  slirp_hv_net_attach(HvMachine *m, HvVirtioNet *n);
void slirp_hv_net_poll(void);
void slirp_hv_net_shutdown(void);
#endif
