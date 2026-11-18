package com.henge.vm.control;

/**
 * Machine —— 一台虚拟机的全部配置。
 *
 * <p>刻意做成**扁平的一堆 public 字段**，照 Limbo 的 {@code Machine} 那样。
 * 为什么不封装成 getter/setter：
 * 这个对象要能被 Gson 直接序列化进数据库、能被 UI 直接绑定、
 * 能在单元测试里三行构造出来。加一层 getter 只是让这三件事都变麻烦。
 * Limbo 用 400 行的 getter/setter 包这一堆字段，实际收益是零。
 *
 * <p>默认值都取自**已经在设备上跑通**的那套（13.64~13.68），
 * 所以 {@code new Machine()} 直接就能起一台能用的机器。
 */
public class Machine {

    // ---------------------------------------------------------- 标识
    public String id;
    public String name = "henge";

    // ---------------------------------------------------------- 主板
    /**
     * 必须带 gic-version=3：Linux 6.x 的 GICv3 驱动要它。
     * 光写 virt 会退到 gicv2，客机起不来。
     */
    public String machineType = "virt,gic-version=3";
    public String cpu = "max";
    public int smp = 2;
    public int memoryMb = 2048;

    // ---------------------------------------------------------- 加速
    /**
     * 我们的引擎在 QEMU 里注册成一个 accel，名字叫 henge。
     * 没有 KVM 也不走 TCG。
     */
    public String accel = "henge";

    // ---------------------------------------------------------- 存储
    public String disk;                 // qcow2 路径
    public String diskFormat = "qcow2";
    public String iso;                  // 可引导光驱

    // ---------------------------------------------------------- 启动
    public String kernel;               // 裸 Image（可选，UEFI 启动时留空）
    public String initrd;
    public String append;

    // ---------------------------------------------------------- 固件
    public boolean useUefi = true;
    public String biosDir = "/data/local/tmp/henge/bios";
    public String varsImage;            // UEFI 变量存储，每次启动复制一份

    // ---------------------------------------------------------- 显示
    /**
     * 注意：设备侧有这个开关不代表客机能用。客机内核必须带 virtio_gpu 模块。
     * Debian 的 linux-image-*-cloud-arm64 **不含**它（13.66），要装
     * linux-image-arm64。判断方法：客机里 ls /dev/dri/ 有 card0 才行。
     */
    public boolean gpuEnabled = true;
    public int vncPort = 5900;          // -1 = 不开

    // ---------------------------------------------------------- 输入
    /**
     * 三件套必须一起开。缺 usb-kbd 时 monitor 的 sendkey 会静默失效
     * （QEMU 的 input handlers 链表为空，事件被丢弃，13.67）。
     * 指针必须用 usb-tablet（绝对坐标），usb-mouse 是相对位移会漂。
     */
    public boolean inputEnabled = true;
    public boolean keyboardEnabled = true;
    public boolean pointerEnabled = true;

    // ---------------------------------------------------------- 网络
    public boolean netEnabled = true;
    /**
     * Android 没有 /etc/resolv.conf，libslirp 的 get_dns_addr() 恒失败，
     * 此时发往虚拟 DNS 地址的所有包都会被拒（13.54/13.55）。
     * QEMU 命令行没有对应开关，只能通过这个环境变量喂给库。
     */
    public String dns = "223.5.5.5";

    // ---------------------------------------------------------- 音频
    /** 例："sdl,id=snd0" 或 "aaudio,id=snd0"。空 = 不开。 */
    public String audioDriver = "";

    // ---------------------------------------------------------- 调试
    public int monitorTcpPort = 4490;   // screendump / sendkey / mouse_move
    public int serialTcpPort = 4491;    // 交互式 console（配 serialctl.py）

    // ---------------------------------------------------------- 杂项
    public String extraParams = "";
    public int incomingFd = -1;         // 快照恢复用

    public Machine() {}

    /** 从"已验证过的那条命令"生成，方便对照测试。 */
    public static Machine golden() {
        Machine m = new Machine();
        m.disk = "/data/local/tmp/deb12-gui.qcow2";
        m.varsImage = "/data/local/tmp/gui-vars.img";
        return m;
    }
}
