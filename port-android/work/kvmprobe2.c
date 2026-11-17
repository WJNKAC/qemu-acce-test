/* 第二轮：VCPU_INIT 的 target 逐个试，找出内核到底认哪个。
   4.14 的 kvm_vcpu_set_target() 要求 init->target == kvm_target_cpu()，
   而 kvm_target_cpu() 在 4.14 只映射 A53/A57；A55/A76 会返回 -EINVAL，
   于是任何 target 都对不上。这里把 target 0..15 全试一遍把结论钉死。 */
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/ioctl.h>

#define KVMIO 0xAE
#define KVM_GET_API_VERSION   _IO(KVMIO, 0x00)
#define KVM_CREATE_VM         _IO(KVMIO, 0x01)
#define KVM_CHECK_EXTENSION   _IO(KVMIO, 0x03)
#define KVM_CREATE_VCPU       _IO(KVMIO, 0x41)
#define KVM_ARM_VCPU_INIT     _IOW(KVMIO, 0xae, struct kvm_vcpu_init)
#define KVM_ARM_PREFERRED_TARGET _IOR(KVMIO, 0xaf, struct kvm_vcpu_init)
struct kvm_vcpu_init { uint32_t target; uint32_t features[7]; };

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int kvm = open("/dev/kvm", O_RDWR);
    if (kvm < 0) { perror("open /dev/kvm"); return 1; }
    printf("api = %d\n", ioctl(kvm, KVM_GET_API_VERSION, 0));

    struct kvm_vcpu_init pref; memset(&pref, 0, sizeof pref);
    int r = ioctl(kvm, KVM_ARM_PREFERRED_TARGET, &pref);
    printf("PREFERRED_TARGET: rc=%d errno=%d (%s)\n", r, errno, strerror(errno));

    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    printf("CREATE_VM: %d\n", vm);
    if (vm < 0) return 1;

    printf("\ntarget : VCPU_INIT result\n");
    for (unsigned t = 0; t <= 15; t++) {
        int v = ioctl(vm, KVM_CREATE_VCPU, 0);
        if (v < 0) { printf("  %2u : CREATE_VCPU failed: %s\n", t, strerror(errno)); continue; }
        struct kvm_vcpu_init in; memset(&in, 0, sizeof in);
        in.target = t;
        errno = 0;
        int rc = ioctl(v, KVM_ARM_VCPU_INIT, &in);
        printf("  %2u : %s%s\n", t, rc == 0 ? "OK" : "EINVAL/other",
               rc == 0 ? "" : "");
        if (rc != 0) printf("       -> %s\n", strerror(errno));
        close(v);
    }
    return 0;
}
