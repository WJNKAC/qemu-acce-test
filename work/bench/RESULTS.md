# QEMU+henge 性能重定价结果

日期：2026-11-18。设备 MT6833（cpu6/7 = Cortex-A76 @ 2.203 GHz，
cpu0-5 = Cortex-A55 @ 2.0 GHz）。客机 Debian 12 / 2 vCPU / 2 GB。

## 方法

- **同一个二进制**（`bench_freestanding.c`，4.6 KB，`-nostdlib` 直接发系统调用），
  客机（glibc）与 Android（bionic）都能跑，排除运行库差异。
- 两边都 `taskset` 钉到 **cpu6**（A76），原生用掩码 `0x40`，
  QEMU 全部线程用 `0xc0`（cpu6+7）。
- **1 秒预热**：这颗 SoC 的 `schedutil` 在 idle 时把频率压到 725 MHz，
  不预热会测到升频过程。不预热的数字误差可达 55%。
- 每个用例进程内 **best-of-3**，单次 200 ms 量级。
- 每项跑 3~5 轮取**中位数**。

## 结果

| 项 | 原生 ns/op | 客机 ns/op | 客机/原生 |
|---|---|---|---|
| alu（整数依赖链） | 1.432 | 1.421 | **0.99×** |
| mul（乘加链） | 2.503 | 2.355 | **0.94×** |
| call（noinline） | 2.504 | 6.191 | **2.47×** |
| branch（数据相关） | 2.462 | 4.226 | **1.72×** |
| mem_stride64 | 2.525 | 4.686 | **1.86×** |
| mem_seq | 3062 MiB/s | 1665 MiB/s | **1.84×** |

几何平均 1.54× → **达原生 65%**。

## 复现

```sh
# 编译
aarch64-linux-gnu-gcc -O2 -static -nostdlib -ffreestanding \
  -fno-stack-protector -Wl,-z,max-page-size=4096 \
  -o bench bench_freestanding.c

# 原生基准（钉大核）
adb push bench /data/local/tmp/bench
adb shell 'taskset 40 /data/local/tmp/bench'

# 送进客机（串口，sha256 校验）
python3 ../probe/pushfile.py --port 4491 --src ./bench --dst /root/bench
# 客机内运行
python3 ../probe/serialctl.py --port 4491 send "/root/bench" --read 15
```

## 为什么 `-Wl,-z,max-page-size=4096` 是必须的

不加的话，带 64 KB `.bss` 的静态二进制会链接出这样一个段：

```
LOAD 0x00fff0 0x41fff0 filesz=0 memsz=0x10000 align=0x10000
```

`p_offset=0xfff0` 已越过文件尾（文件只有 4544 B），内核按页取 `0xf000`
映射 → 落在 EOF 之外 → 一访问就 SIGSEGV。
**没有 bss 的小程序不触发**，所以用最小程序验证时会误判为"正常"。
