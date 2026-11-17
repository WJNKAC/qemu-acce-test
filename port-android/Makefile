# Android/Linux 主机上的构建。
#
# 设计原则：原项目树（src/WindowsiOS）只读，一个字都不改。平台差异全部
# 通过 compat/ 里的垫片头 + 本目录的三个替换文件承担：
#   compat/            冒充 Darwin 的头（TargetConditionals / mach_time / mach_task）
#   jit_region_linux.c 替换 host/jit_region.c（vm_remap → mmap RWX / memfd 双映射）
#   linuxvirt.c        替换 devices/winvirt.c 的启动语义（UEFI → 直接 Image）
#   main_android.c     替换 host/main_mac.m + host/winvm.c 的 UI/音频/显示那半
#
# 用 NDK 的 clang 编 aarch64 Android；用系统 aarch64-linux-gnu-gcc 也能起
# （SYS=aarch64-linux-gnu- 覆盖）。

S ?= ../src/WindowsiOS

NDK   ?= /data/software/apps/android_studio/main/x86_64/installed/android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin
TARGET?= aarch64-linux-android30
# make 有内建的 CC=cc 默认值，所以 ?= 不会生效；只在用户没从命令行指定时覆盖。
ifeq ($(origin CC),default)
CC     = $(NDK)/$(TARGET)-clang
STRIP  = $(NDK)/llvm-strip
endif
STRIP ?= llvm-strip

B   = build
INC = -Icompat -Idevs -Ihost $(CORE_INC) -I$(S)/host -I$(S)/devices
CFLAGS = -include compat/hv_posix_compat.h -std=c11 -O2 -g -Wall -Wextra -fno-omit-frame-pointer $(INC) -D_GNU_SOURCE -DHAVE_SLIRP=1 -I$(SLIRP)
# mmu.c 必须不生成 SIMD：hv_tlb_refill 跑的时候 guest 的 SIMD 寄存器是活的。
MMUFLAGS = -mgeneral-regs-only

CORE_SRC = $(S)/core/classify.c $(S)/core/operands.c $(S)/core/translate.c \
           $(S)/core/dispatch.c $(MMU_SRC) $(S)/core/memop.c \
           $(S)/core/exception.c $(S)/core/sysreg.c $(MACH_SRC)

# libslirp 从 WindowsPixel 借用（同源引擎的 Linux/Android 移植），
# 它已经把 glib 依赖剥成单头垫片，可以直接编译进来。
SLIRP     = ../src/WindowsPixel/third_party/libslirp
SLIRP_SRC = $(wildcard $(SLIRP)/*.c)
DEV_SRC  = devs/fdt_linux.c $(S)/devices/gicv3.c $(S)/devices/pcie.c \
           $(S)/devices/pl011.c $(S)/devices/pl031.c $(S)/devices/pl061.c \
           $(S)/devices/timer.c $(S)/devices/virtio.c $(S)/devices/virtio_net.c \
           $(S)/devices/nvme.c

HOST_SRC = $(S)/host/disk.c jit_region_linux.c linuxvirt.c main_android.c compat/plat_linux.c \
           host/net_passt_linux.c host/net_slirp_linux.c\
           $(SLIRP_SRC)

# enter.S 里的符号是 Mach-O 风格的下划线前缀（_hv_enter），ELF 上不需要。
# 这里生成一份去掉前缀的副本，而不是改原文件。
ENTER_ELF = $(B)/enter_elf.S

# ---- core 的实验变体（原树只读，改的是 build/core 里的副本）----
#   TLB_BITS=16  HV_TLB_BITS 14->16：每 EL 16384->65536 槽，覆盖 64->256 MB
#                （同时要挪 HV_CPU_RET_TAB、把槽编码从 uint16 升到 uint32）
#   PMD_BANK=1   大页独立 bank + 慢路径桶计数器
TLB_BITS ?= 14
PMD_BANK ?= 0
PROF ?= 0
ABL ?= 0
ABL ?= 0
WHINT ?= 0
LINMAP ?= 0
LM_SKIPSEG ?= 0
CORE_OVERRIDE = $(B)/core
ifeq ($(TLB_BITS)$(PMD_BANK)$(PROF)$(ABL)$(WHINT)$(BANK)$(LINMAP),14000000)
CORE_INC = -I$(S)/core
MMU_SRC  = $(S)/core/mmu.c
MACH_SRC = $(S)/core/machine.c
CORE_HDRS = $(CORE_OVERRIDE)/variant.txt
else
# 不能靠 -I 覆盖：core/dispatch.h 写的是 #include "cpu.h"，
# 而引号包含**先查该头文件自己所在目录** —— 永远命中 src/core/cpu.h 原版。
# 所以用 -include 抢先展开补丁版；include guard 相同，后续原版包含变成空操作。
CORE_INC = -include $(CORE_OVERRIDE)/cpu.h -include $(CORE_OVERRIDE)/machine.h -I$(S)/core
MMU_SRC  = $(CORE_OVERRIDE)/mmu.c
MACH_SRC = $(CORE_OVERRIDE)/machine.c
MACH_SRC = $(CORE_OVERRIDE)/machine.c
CORE_HDRS = $(CORE_OVERRIDE)/variant.txt $(CORE_OVERRIDE)/cpu.h $(CORE_OVERRIDE)/machine.h
endif

# RET_MODE: 返回指令的实验变体（原树只读，改的是生成出来的副本）
#   0 = 原样 `ret x6`    1 = `mov x30,x6; ret`（试宿主 RSB）    2 = `br x6`（反向对照）
RET_MODE ?= 0
HASH ?= 0
ifeq ($(RET_MODE)$(HASH)$(BANK)$(LINMAP),0000)
TRANSLATE_SRC = $(S)/core/translate.c
else
TRANSLATE_SRC = $(B)/translate_patched.c
endif

OBJ = $(patsubst %,$(B)/%.o,$(notdir $(basename $(CORE_SRC)) $(basename $(DEV_SRC)) $(basename $(HOST_SRC)))) $(B)/enter_elf.o

all: $(B)/hv-linux

$(B)/enter_elf.S: $(S)/host/enter.S | $(B)
	sed -e 's/\b_hv_/hv_/g' $< > $@

$(B)/enter_elf.o: $(B)/enter_elf.S | $(B)
	$(CC) -c $< -o $@

# translate.o 在 RET_MODE/HASH/BANK 任一非零时来自打过补丁的副本
ifeq ($(TRANSLATE_SRC),$(B)/translate_patched.c)
$(B)/translate_patched.c: $(S)/core/translate.c tools/patch_translate.py | $(B)
	RET_MODE=$(RET_MODE) HASH=$(HASH) BANK=$(BANK) LINMAP=$(LINMAP) LM_NJMP=$(LM_NJMP) LM_SKIPSEG=$(LM_SKIPSEG) python3 tools/patch_translate.py $< $@ $(RET_MODE)
endif

$(B)/translate.o: $(TRANSLATE_SRC) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@

# core 副本。用 FORCE 让它每次都跑：脚本内容不变时不写文件，
# 于是只有真的切的变体才会触发重编译。
# 注意：-I 指向 build/core，若副本还没生成就会静默用原版头 → 必须让 .o 依赖它们。
.PHONY: FORCE
FORCE:

$(CORE_OVERRIDE)/variant.txt $(CORE_OVERRIDE)/cpu.h $(CORE_OVERRIDE)/machine.h $(CORE_OVERRIDE)/mmu.c $(CORE_OVERRIDE)/machine.c: tools/patch_core.py tools/patch_whint.py FORCE | $(B)
	TLB_BITS=$(TLB_BITS) PMD_BANK=$(PMD_BANK) PROF=$(PROF) ABL=$(ABL) WHINT=$(WHINT) BANK=$(BANK) LINMAP=$(LINMAP) python3 tools/patch_core.py $(S)/core $(CORE_OVERRIDE)

$(B)/mmu.o: $(MMU_SRC) $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) $(MMUFLAGS) -c $(MMU_SRC) -o $@

$(B)/%.o: $(S)/core/%.c $(CORE_HDRS) $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: $(S)/devices/%.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: $(S)/host/%.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: %.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: devs/%.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: host/%.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: $(SLIRP)/%.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -Wno-unused-parameter -Wno-sign-compare -Wno-unused-variable -c $< -o $@
$(B)/%.o: compat/%.c $(CORE_HDRS) | $(B)
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/hv-linux: $(OBJ)
	$(CC) $(OBJ) -o $@
	$(STRIP) --strip-debug $@ || true

$(B):
	mkdir -p $(B)

clean:
	rm -rf $(B)

.PHONY: all clean
