# cntfrq 探针

读设备的 `CNTFRQ_EL0`，并用 `CLOCK_MONOTONIC` 实测计数器速率，两者对比。

## 为什么需要

Henge 的 `counter()` 硬编码假设 `CNTFRQ = 24 MHz`（Apple Silicon）：

```c
static uint64_t counter(void) {
    return mach_absolute_time(); /* 24 MHz on Apple silicon */
}
```

移植层的 `to24_mult` 把它换算到 24 MHz 域，但换算的**分母写死了设备频率**
（`24e6<<32/13e6` 里的 `13e6`）。换一台 19.2 MHz 的设备，这个换算就是错的。

`ratio to CNTFRQ` 不等于 1.0000 说明固件报的 CNTFRQ 与实际计数速率不符
（MTK 上确有这种机型），那连 `CNTFRQ_EL0` 都不能信。

## 实测结果（2026-11-17）

| 设备 | SoC | Android | CNTFRQ_EL0 | measured | ratio |
|---|---|---|---|---|---|
| OPPO PDYT20 | mt6853 | 12 | 13000000 (13.000 MHz) | 13.000 MHz | 1.0000 |
| vivo V2156FA | MT6833V/ZA | 11 | 13000000 (13.000 MHz) | 13.000 MHz | 1.0000 |

两台 MTK 都是 13 MHz，寄存器与实测一致。

**没有踩到 19.2 MHz**，所以「硬编码 13e6」的隐患在这两台设备上不显现 ——
但它真实存在：Apple 是 24 MHz，高通/部分 MTK 是 19.2 MHz。
`to24_mult` 应该改成运行时读 `CNTFRQ_EL0` 计算，见 QEMU-BACKEND.md 13.32。

## 编译

```sh
NDK=/data/software/apps/android_studio/main/x86_64/installed/android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin
$NDK/aarch64-linux-android30-clang -O2 -static -o cntfrq cntfrq.c
```

静态链接是刻意的：这样 `adb push` 到 `/data/local/tmp/` 就能跑，
不需要 Termux 的运行环境（vivo 的 Termux 是私有目录，adb shell 进不去）。

## 跑

```sh
# 有 adb 的设备
adb push cntfrq /data/local/tmp/ && adb shell 'chmod 755 /data/local/tmp/cntfrq && /data/local/tmp/cntfrq'

# 只有 SSH 的设备（Termux）
gzip -1 -c cntfrq | ssh <dev> 'gunzip > ~/cntfrq && chmod +x ~/cntfrq'
ssh <dev> '~/cntfrq'
```
