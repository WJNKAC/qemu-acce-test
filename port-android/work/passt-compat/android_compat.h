/* bionic 与 glibc 的差异，passt 依赖 glibc 的地方在这里补齐。
   用 -include 强制加进每个编译单元，不改 passt 源码（除了 ip.h 那处
   结构体重复定义，那个没法用宏绕过）。 */
#ifndef PASST_ANDROID_COMPAT_H
#define PASST_ANDROID_COMPAT_H

#include <inttypes.h>    /* PRIu16 等格式宏：glibc 会间接带入，bionic 不会 */
#include <netinet/udp.h>   /* struct udphdr：passt 只包含了 <linux/udp.h> */

/* glibc 的 <resolv.h> 里有这两个上限，bionic 没有。
   值取自 glibc：MAXNS=3（最多 3 个 nameserver），MAXDNSRCH=6（最多 6 个搜索域）。 */
#ifndef MAXNS
#define MAXNS 3
/* glibc 的 <netinet/in.h> 定义，bionic 没有 */
#ifndef IPV4_MIN_MTU
#define IPV4_MIN_MTU 68
#endif
/* glibc 的 <paths.h> 里的 syslog socket 路径，bionic 没有 <paths.h> 的这项 */
#ifndef _PATH_LOG
#define _PATH_LOG "/dev/log"
#endif

#ifndef IPV6_MIN_MTU
#define IPV6_MIN_MTU 1280
#endif

#endif
#ifndef MAXDNSRCH
#define MAXDNSRCH 6
/* glibc 的 <netinet/in.h> 定义，bionic 没有 */
#ifndef IPV4_MIN_MTU
#define IPV4_MIN_MTU 68
#endif
/* glibc 的 <paths.h> 里的 syslog socket 路径，bionic 没有 <paths.h> 的这项 */
#ifndef _PATH_LOG
#define _PATH_LOG "/dev/log"
#endif

#ifndef IPV6_MIN_MTU
#define IPV6_MIN_MTU 1280
#endif

#endif

/* glibc 的 <netinet/in.h> 定义，bionic 没有 */
#ifndef IPV4_MIN_MTU
#define IPV4_MIN_MTU 68
#endif
/* glibc 的 <paths.h> 里的 syslog socket 路径，bionic 没有 <paths.h> 的这项 */
#ifndef _PATH_LOG
#define _PATH_LOG "/dev/log"
#endif

#ifndef IPV6_MIN_MTU
#define IPV6_MIN_MTU 1280
#endif

#endif

/* ---- IN6_IS_ADDR_* 宏 ----
 * bionic 的版本是 `(a)->s6_addr32[0] == 0` 这种直接成员访问；glibc 的版本先
 * cast 成 `const struct in6_addr *`。passt 会把这些宏用在它自己的
 * `union inany_addr *` 上（首成员是 struct in6_addr，布局兼容），
 * 于是 bionic 版编不过：union 没有 s6_addr32 成员。
 * 这里改成带 cast 的等价实现，用 s6_addr 字节访问，两边 libc 都有。 */
#include <netinet/in6.h>

static inline int hv_in6_unspec(const struct in6_addr *a) {
    for (int i = 0; i < 16; i++) if (a->s6_addr[i]) return 0;
    return 1;
}
static inline int hv_in6_loopback(const struct in6_addr *a) {
    for (int i = 0; i < 15; i++) if (a->s6_addr[i]) return 0;
    return a->s6_addr[15] == 1;
}
static inline int hv_in6_v4mapped(const struct in6_addr *a) {
    for (int i = 0; i < 10; i++) if (a->s6_addr[i]) return 0;
    return a->s6_addr[10] == 0xff && a->s6_addr[11] == 0xff;
}
static inline int hv_in6_linklocal(const struct in6_addr *a) {
    return a->s6_addr[0] == 0xfe && (a->s6_addr[1] & 0xc0) == 0x80;
}
static inline int hv_in6_multicast(const struct in6_addr *a) { return a->s6_addr[0] == 0xff; }
static inline int hv_in6_v4compat(const struct in6_addr *a) {
    for (int i = 0; i < 12; i++) if (a->s6_addr[i]) return 0;
    return a->s6_addr[12] || a->s6_addr[13] || a->s6_addr[14] || a->s6_addr[15];
}
static inline int hv_in6_any(const struct in6_addr *a) {
    for (int i = 0; i < 12; i++) if (a->s6_addr[i]) return 0;
    return 1;
}
static inline int hv_in6_mc_node(const struct in6_addr *a) {
    return a->s6_addr[0] == 0xff && (a->s6_addr[1] & 0x0f) == 0x01;
}
static inline int hv_in6_mc_linklocal(const struct in6_addr *a) {
    return a->s6_addr[0] == 0xff && (a->s6_addr[1] & 0x0f) == 0x02;
}
static inline int hv_in6_mc_sitelocal(const struct in6_addr *a) {
    return a->s6_addr[0] == 0xff && (a->s6_addr[1] & 0x0f) == 0x05;
}
static inline int hv_in6_equal(const struct in6_addr *a, const struct in6_addr *b) {
    for (int i = 0; i < 16; i++) if (a->s6_addr[i] != b->s6_addr[i]) return 0;
    return 1;
}

#define IN6_IS_ADDR_UNSPECIFIED(a)  hv_in6_unspec((const struct in6_addr *)(a))
#define IN6_IS_ADDR_LOOPBACK(a)     hv_in6_loopback((const struct in6_addr *)(a))
#define IN6_IS_ADDR_V4MAPPED(a)     hv_in6_v4mapped((const struct in6_addr *)(a))
#define IN6_IS_ADDR_LINKLOCAL(a)    hv_in6_linklocal((const struct in6_addr *)(a))
#define IN6_IS_ADDR_MULTICAST(a)    hv_in6_multicast((const struct in6_addr *)(a))
#define IN6_IS_ADDR_V4COMPAT(a)     hv_in6_v4compat((const struct in6_addr *)(a))
#define IN6_IS_ADDR_MC_NODELOCAL(a) hv_in6_mc_node((const struct in6_addr *)(a))
#define IN6_IS_ADDR_MC_LINKLOCAL(a) hv_in6_mc_linklocal((const struct in6_addr *)(a))
#define IN6_IS_ADDR_MC_SITELOCAL(a) hv_in6_mc_sitelocal((const struct in6_addr *)(a))
#define IN6_ARE_ADDR_EQUAL(a, b)    hv_in6_equal((const struct in6_addr *)(a), (const struct in6_addr *)(b))

/* bionic 的 <linux/virtio_ring.h> 只有结构体没有这些内联辅助函数
   （内核头里的实现靠 __KERNEL__ 分支）。补上标准的等价实现。
   只有 vhost-user 路径会用，我们走 --fd stream 模式用不到，但得能编过。 */
#include <linux/virtio_ring.h>

static inline int vring_need_event(uint16_t event_idx, uint16_t new_idx, uint16_t old_idx)
{
	return (uint16_t)(new_idx - event_idx - 1) < (uint16_t)(new_idx - old_idx);
}
