/* Darwin 专有的 pthread 扩展，Linux 上没有：
   pthread_cond_timedwait_relative_np(cv, mu, rel) 等"相对超时"。
   dispatch.c 用它来实现 WFI 的等待。这里用 CLOCK_REALTIME 的绝对死线
   还原同样的语义（默认 cond 变量就是 REALTIME 时钟）。 */
#ifndef HV_POSIX_COMPAT_H
#define HV_POSIX_COMPAT_H

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

/* Darwin 的 F_BARRIERFSYNC：带屏障的写盘。Linux 上最接近的是 fdatasync，
   而 disk.c 里本来就是用 fcntl 调的，这里改指到一条等价路径。 */
#ifndef F_BARRIERFSYNC
#define F_BARRIERFSYNC (-2)
static inline int hv_fcntl_barrier(int fd) { return fdatasync(fd); }
#endif

static inline int hv_cond_timedwait_relative(pthread_cond_t *cv, pthread_mutex_t *mu,
                                             const struct timespec *rel) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    struct timespec abs;
    abs.tv_sec = now.tv_sec + rel->tv_sec;
    abs.tv_nsec = now.tv_nsec + rel->tv_nsec;
    if (abs.tv_nsec >= 1000000000L) { abs.tv_sec++; abs.tv_nsec -= 1000000000L; }
    return pthread_cond_timedwait(cv, mu, &abs);
}
#define pthread_cond_timedwait_relative_np(cv, mu, rel) hv_cond_timedwait_relative((cv), (mu), (rel))

#endif
