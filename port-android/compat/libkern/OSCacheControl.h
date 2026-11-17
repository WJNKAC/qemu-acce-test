/* <libkern/OSCacheControl.h> 的替身：引擎只用这一个函数。 */
#ifndef HV_COMPAT_OSCACHECONTROL_H
#define HV_COMPAT_OSCACHECONTROL_H
#include <stddef.h>
void sys_icache_invalidate(void *start, size_t len);
#endif
