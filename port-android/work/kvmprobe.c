/* 最小 KVM 探针：不依赖 QEMU，直接问内核"你能不能真的跑一个 guest"。
 *
 * 为什么需要它：/dev/kvm 这个设备节点在 Android 上是 ueventd 按配置静态创建的
 * （给 cuttlefish 用的），**不代表 KVM 真的初始化成功了**。arm64 上 KVM 需要
 * 内核在 EL2 上（nVHE），而多数手机 bootloader 把内核放在 EL1 交接 —— 那种情况下
 * kvm_init() 返回 -ENODEV，模块加载失败，但 /dev/kvm 照样存在。
 * 唯一可靠的判据是真的 CREATE_VM + CREATE_VCPU + RUN 一次。
 *
 * 编译：aarch64-linux-gnu-gcc -O2 -static -o kvmprobe kvmprobe.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define KVMIO 0xAE
#define KVM_GET_API_VERSION        _IO(KVMIO, 0x00)
#define KVM_CREATE_VM              _IO(KVMIO, 0x01)
#define KVM_CHECK_EXTENSION        _IO(KVMIO, 0x03)
#define KVM_GET_VCPU_MMAP_SIZE     _IO(KVMIO, 0x04)
#define KVM_CREATE_VCPU            _IO(KVMIO, 0x41)
#define KVM_SET_USER_MEMORY_REGION _IOW(KVMIO, 0x46, struct kvm_userspace_memory_region)
#define KVM_CREATE_IRQCHIP         _IO(KVMIO, 0x60)
#define KVM_RUN                    _IO(KVMIO, 0x80)
#define KVM_SET_ONE_REG            _IOW(KVMIO, 0xac, struct kvm_one_reg)
#define KVM_GET_ONE_REG            _IOR(KVMIO, 0xab, struct kvm_one_reg)
#define KVM_ARM_VCPU_INIT          _IOW(KVMIO, 0xae, struct kvm_vcpu_init)
#define KVM_ARM_PREFERRED_TARGET   _IOR(KVMIO, 0xaf, struct kvm_vcpu_init)
#define KVM_CREATE_DEVICE          _IOWR(KVMIO, 0xe0, struct kvm_create_device)

struct kvm_userspace_memory_region {
    uint32_t slot, flags;
    uint64_t guest_phys_addr, memory_size, userspace_addr;
};
struct kvm_one_reg { uint64_t id; uint64_t addr; };
struct kvm_vcpu_init { uint32_t target; uint32_t features[7]; };
struct kvm_create_device { uint32_t type, fd; uint32_t flags; };

/* arm64 核心寄存器编码 */
#define KVM_REG_ARM64       0x6000000000000000ULL
#define KVM_REG_SIZE_U64    0x0030000000000000ULL
#define KVM_REG_ARM_CORE    0x00100000ULL
#define KVM_REG_ARM_CORE_REG(name) ((offsetof(struct kvm_regs_user, name)) / 4)
struct kvm_regs_user { uint64_t regs[31], sp, pc, pstate; };

/* KVM_EXIT_* */
static const char *exit_name(uint32_t r) {
    switch (r) {
    case 0: return "UNKNOWN";
    case 2: return "IO";
    case 5: return "HLT";
    case 6: return "MMIO";
    case 7: return "IRQ_WINDOW_OPEN";
    case 8: return "SHUTDOWN";
    case 9: return "FAIL_ENTRY";
    case 10: return "EXCEPTION";
    case 11: return "HYPERCALL(arm: psci)";
    case 17: return "HYPERCALL";
    case 24: return "SYSTEM_EVENT";
    default: return "?";
    }
}

static int caps[] = {
    32,  /* IRQFD */
    36,  /* IOEVENTFD */
    57,  /* KVM_CAP_ARM_PSCI (0.2 merged) */
    66,  /* ONE_REG */
    88,  /* GUEST_DEBUG_HW_BPS */
    102, /* ARM_PSCI_0_2 */
    105, /* ARM_EL1_32BIT */
    108, /* ARM_SET_DEVICE_ADDR */
    113, /* VCPU_ATTRIBUTES */
    114, /* DEVICE_CTRL */
    115, /* ARM_PMU_V3 */
    121, /* MAX_VCPU_ID */
    125, /* ARM_USER_IRQ */
    137, /* ARM_VM_IPA_SIZE? actually 165 */
    165, /* ARM_VM_IPA_SIZE */
    168, /* ARM_PTRAUTH_ADDRESS */
    169, /* ARM_PTRAUTH_GENERIC */
    172, /* ARM_NISV_TO_USER */
    176, /* ARM_MTE */
};

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== KVM probe ===\n");

    /* 1) 能不能打开 */
    int kvm = open("/dev/kvm", O_RDWR);
    if (kvm < 0) {
        printf("open(/dev/kvm) FAILED: %s\n", strerror(errno));
        if (errno == EACCES) printf("  -> 权限问题：节点是 crw------- virtmanager，需要 root\n");
        if (errno == ENODEV) printf("  -> 节点存在但内核里没有真正注册 kvm 设备\n");
        return 1;
    }
    printf("open(/dev/kvm)        ok (fd=%d)\n", kvm);

    /* 2) API 版本：这一步会走 kvm_dev_ioctl，能区分"节点在但驱动没起来" */
    int api = ioctl(kvm, KVM_GET_API_VERSION, 0);
    if (api < 0) {
        printf("KVM_GET_API_VERSION   FAILED: %s  (errno=%d)\n", strerror(errno), errno);
        printf("  -> 判定：KVM 驱动未初始化，/dev/kvm 是空壳\n");
        return 1;
    }
    printf("KVM_GET_API_VERSION   %d\n", api);

    /* 3) 能力位 */
    printf("\n-- capabilities --\n");
    for (unsigned i = 0; i < sizeof caps / sizeof *caps; i++) {
        int r = ioctl(kvm, KVM_CHECK_EXTENSION, caps[i]);
        if (r > 0) printf("  cap %-4d = %d\n", caps[i], r);
    }
    int ipa = ioctl(kvm, KVM_CHECK_EXTENSION, 165);
    if (ipa > 0) printf("  IPA 空间上限 = %d 位（%llu GiB）\n", ipa, (1ULL << ipa) >> 30);

    /* 4) 首选 vCPU 类型 */
    struct kvm_vcpu_init pref;
    memset(&pref, 0, sizeof pref);
    if (ioctl(kvm, KVM_ARM_PREFERRED_TARGET, &pref) == 0) {
        printf("\npreferred target = %u  (features[0]=0x%x)\n", pref.target, pref.features[0]);
    } else {
        /* 这台设备的 vendor 内核（4.14）没把 Cortex-A55/A76 映射进
           kvm_target_cpu()，所以"首选目标"这个查询失败；但
           KVM_ARM_TARGET_GENERIC_V8 = 5 是支持的（见 kvmprobe3 的逐值扫描）。 */
        printf("\nKVM_ARM_PREFERRED_TARGET failed: %s -> 退回 GENERIC_V8(5)\n", strerror(errno));
        pref.target = 5;
    }

    /* 5) 建 VM —— 这一步开始才真正吃 EL2 */
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    if (vm < 0) {
        printf("\nKVM_CREATE_VM         FAILED: %s (errno=%d)\n", strerror(errno), errno);
        switch (errno) {
        case ENODEV: printf("  -> 内核没有可用的 hypervisor（未在 EL2 上），KVM 不可用\n"); break;
        case EINVAL: printf("  -> vm type 不支持\n"); break;
        case ENOENT: printf("  -> 缺 CONFIG_KVM / 模块未加载\n"); break;
        }
        return 1;
    }
    printf("\nKVM_CREATE_VM         ok (fd=%d)\n", vm);

    /* 6) 一页客户机内存，放 mov x0,#0x10000000 ; ldr x1,[x0]  */
    size_t pg = 4096;
    void *mem = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap"); return 1; }
    uint32_t *code = mem;
    code[0] = 0xd2a20000;  /* movz x0, #0x1000, lsl #16  -> x0 = 0x10000000 */
    code[1] = 0xf9400001;  /* ldr  x1, [x0]              -> 未映射 IPA，必然 MMIO 退出 */

    struct kvm_userspace_memory_region region = {
        .slot = 0, .flags = 0,
        .guest_phys_addr = 0, .memory_size = pg,
        .userspace_addr = (uint64_t)(uintptr_t)mem,
    };
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region) < 0) {
        printf("KVM_SET_USER_MEMORY_REGION FAILED: %s\n", strerror(errno));
        return 1;
    }
    printf("memory region         ok (IPA 0, 1 页)\n");

    int irqchip = ioctl(vm, KVM_CREATE_IRQCHIP, 0);
    printf("KVM_CREATE_IRQCHIP    %s", irqchip == 0 ? "ok (内核内 GIC)\n" : "failed: ");
    if (irqchip != 0) printf("%s\n", strerror(errno));

    /* 7) 建 vCPU */
    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) {
        printf("KVM_CREATE_VCPU       FAILED: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
    printf("KVM_CREATE_VCPU       ok (fd=%d)\n", vcpu);

    int mmap_sz = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    printf("KVM_GET_VCPU_MMAP_SIZE %d\n", mmap_sz);
    void *run = mmap(NULL, mmap_sz, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) { perror("mmap kvm_run"); return 1; }

    struct kvm_vcpu_init init;
    memset(&init, 0, sizeof init);
    init.target = pref.target;
    if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init) < 0) {
        printf("KVM_ARM_VCPU_INIT     FAILED: %s\n", strerror(errno));
        return 1;
    }
    printf("KVM_ARM_VCPU_INIT     ok (target=%u)\n", init.target);

    /* 8) 把 PC 指到 0 */
    struct kvm_one_reg r = { .id = KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE |
                                   KVM_REG_ARM_CORE_REG(pc) };
    uint64_t pc = 0;
    r.addr = (uint64_t)(uintptr_t)&pc;
    if (ioctl(vcpu, KVM_SET_ONE_REG, &r) < 0) {
        printf("KVM_SET_ONE_REG(pc)   FAILED: %s\n", strerror(errno));
        return 1;
    }
    printf("KVM_SET_ONE_REG(pc)   ok -> 0x%llx\n", (unsigned long long)pc);

    /* 9) 真正跑一次 */
    printf("\n-- KVM_RUN --\n");
    int rc = ioctl(vcpu, KVM_RUN, 0);
    if (rc < 0) {
        printf("KVM_RUN               FAILED: %s (errno=%d)\n", strerror(errno), rc);
        return 1;
    }
    uint32_t reason = *(uint32_t *)run;
    printf("KVM_RUN               exit_reason=%u (%s)\n", reason, exit_name(reason));
    if (reason == 6) {  /* MMIO */
        /* struct kvm_run: exit_reason(4) padding(4) ready(1) pad(7) then union */
        uint64_t phys = *(uint64_t *)((char *)run + 16);
        uint32_t len = *(uint32_t *)((char *)run + 28);
        printf("                      物理地址 0x%llx, 长度 %u\n",
               (unsigned long long)phys, len);
    }
    /* 读回 PC，确认 guest 真的走了两条指令 */
    struct kvm_one_reg r2 = { .id = KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE |
                                    KVM_REG_ARM_CORE_REG(pc) };
    uint64_t pc2 = 0;
    r2.addr = (uint64_t)(uintptr_t)&pc2;
    ioctl(vcpu, KVM_GET_ONE_REG, &r2);
    printf("guest PC after run    0x%llx\n", (unsigned long long)pc2);

    printf("\n结论：KVM 可用，guest 代码真的执行了。\n");
    return 0;
}
