/* <mach/mach.h> 的替身，只够 core/dispatch.c 的统计段编译通过。
   那段代码用 thread_info(THREAD_BASIC_INFO) 量 vCPU 线程真正占了多少 CPU，
   在 Linux 上换个量法是另一件事，这里让它恒失败、统计里就不打印那一行了。 */
#ifndef HV_COMPAT_MACH_MACH_H
#define HV_COMPAT_MACH_MACH_H

#include <stdint.h>

typedef int kern_return_t;
typedef unsigned int mach_port_t;
typedef unsigned int mach_msg_type_number_t;
typedef int *thread_info_t;
typedef mach_port_t task_t;

#define KERN_SUCCESS 0
#define MACH_PORT_NULL 0
#define THREAD_BASIC_INFO 3
#define THREAD_BASIC_INFO_COUNT 10

typedef struct { int seconds; int microseconds; } time_value_t;
typedef struct {
    int suspend_count;
    int run_state;
    int flags;
    int policy;
    time_value_t user_time;
    time_value_t system_time;
} thread_basic_info_data_t;

static inline mach_port_t mach_task_self(void) { return 0; }
static inline mach_port_t mach_thread_self(void) { return 0; }
static inline kern_return_t mach_port_deallocate(mach_port_t task, mach_port_t name) {
    (void)task; (void)name;
    return KERN_SUCCESS;
}
static inline kern_return_t thread_info(mach_port_t thread, int flavor, thread_info_t out, mach_msg_type_number_t *cnt) {
    (void)thread; (void)flavor; (void)out; (void)cnt;
    return -1; /* 拿不到：调用点会跳过整块 */
}

typedef uintptr_t vm_address_t;
typedef uintptr_t vm_offset_t;
typedef int vm_prot_t;
typedef unsigned int vm_inherit_t;

#endif
