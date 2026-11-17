/* 第三轮：每个 target 用全新 VM，避免 EEXIST 串扰。 */
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
#define KVM_CREATE_VCPU       _IO(KVMIO, 0x41)
#define KVM_ARM_VCPU_INIT     _IOW(KVMIO, 0xae, struct kvm_vcpu_init)
struct kvm_vcpu_init { uint32_t target; uint32_t features[7]; };

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int kvm = open("/dev/kvm", O_RDWR);
    if (kvm < 0) { perror("open"); return 1; }
    for (unsigned t = 0; t <= 12; t++) {
        int vm = ioctl(kvm, KVM_CREATE_VM, 0);
        if (vm < 0) { printf("target %2u: CREATE_VM failed %s\n", t, strerror(errno)); continue; }
        int v = ioctl(vm, KVM_CREATE_VCPU, 0);
        if (v < 0) { printf("target %2u: CREATE_VCPU failed %s\n", t, strerror(errno)); close(vm); continue; }
        struct kvm_vcpu_init in; memset(&in, 0, sizeof in); in.target = t;
        errno = 0;
        int rc = ioctl(v, KVM_ARM_VCPU_INIT, &in);
        if (rc == 0) printf("target %2u: VCPU_INIT **OK**\n", t);
        else         printf("target %2u: %s\n", t, strerror(errno));
        close(v); close(vm);
    }
    return 0;
}
