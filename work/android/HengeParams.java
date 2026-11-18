package com.henge.vm.control;

import java.util.ArrayList;
import java.util.List;

/**
 * HengeParams —— 把 Machine 配置翻译成 qemu-system-aarch64 的命令行参数。
 *
 * <p>结构直接照搬 Limbo 的 {@code VMExecutor.prepareParams()}（九段式）：
 * 每一段只读 Machine 里属于自己的字段，谁都不去碰别人的。这样加一个新选项
 * 只需要改一段，不会像一个大 switch 那样牵一发动全身。
 *
 * <p>与 Limbo 的差异（都是有实测依据的，不是偏好）：
 * <ul>
 *   <li><b>多一段 {@link #addInputOptions}</b>：Limbo 靠 SDL 直连输入，它的九段里
 *       没有输入设备段。我们走 VNC + USB HID，必须显式加
 *       {@code qemu-xhci/usb-kbd/usb-tablet}。缺这段的话 monitor 的 sendkey
 *       会静默失效（13.67：ui/input.c 的 handlers 链表为空）。</li>
 *   <li><b>加速段写死 henge</b>：我们只有这一个 accel，不需要 KVM/TCG 分支。</li>
 *   <li><b>DNS 走环境变量</b>：Android 没有 /etc/resolv.conf，libslirp 的
 *       get_dns_addr() 恒失败，发往虚拟 DNS 地址的包整个被拒（13.54/13.55）。
 *       QEMU 命令行里没有对应开关，只能靠 {@code SLIRP_DNS_SERVER} 环境变量。</li>
 * </ul>
 *
 * <p>本类刻意**不依赖任何 Android API**，这样就可以在普通 JVM 上做单元测试
 * （见 {@code HengeParamsTest}），不必每次改参数都装到手机上试。
 */
public final class HengeParams {

    /** QEMU 可执行文件 / 库名。 */
    public static final String QEMU_BIN = "qemu-system-aarch64";

    private HengeParams() {}

    /**
     * 组装完整参数列表。
     *
     * @param m 机器配置
     * @return 可直接交给 {@code ProcessBuilder} 或 JNI 的参数数组
     */
    public static List<String> build(Machine m) {
        List<String> p = new ArrayList<>();
        p.add(QEMU_BIN);

        addUIOptions(m, p);
        addCpuBoardOptions(m, p);
        addDrives(m, p);
        addRemovableDrives(m, p);
        addBootOptions(m, p);
        addGraphicsOptions(m, p);
        addInputOptions(m, p);      // Limbo 没有这一段，见类注释
        addAudioOptions(m, p);
        addNetworkOptions(m, p);
        addGenericOptions(m, p);
        addStateOptions(m, p);
        addAdvancedOptions(m, p);
        addAccelerationOptions(m, p);   // 必须放最后：QEMU 取第一个实例，
                                        // 放前面会让 extraParams 无法覆盖
        return p;
    }

    /** 需要注入给子进程/库的环境变量。命令行表达不了的东西放这里。 */
    public static java.util.Map<String, String> env(Machine m) {
        java.util.Map<String, String> e = new java.util.HashMap<>();
        if (m.dns != null && !m.dns.isEmpty()) {
            e.put("SLIRP_DNS_SERVER", m.dns);
        }
        return e;
    }

    // ---------------------------------------------------------------- UI

    static void addUIOptions(Machine m, List<String> p) {
        if (m.vncPort >= 0) {
            p.add("-vnc");
            // ⚠ 这里踩过一个真 bug：写成 "127.0.0.1:" + 5900，QEMU 把它
            // 当成 **display 号 5900**，实际监听在 5900+5900 = 11800。
            // 源码 ui/vnc.c:3855 —— `int offset = reverse ? 0 : 5900;`
            // 然后 `inet->port = baseport + offset`。
            //
            // 正确写法有两种：
            //   "127.0.0.1:0"      → display 0 → 端口 5900（**推荐**）
            //   "127.0.0.1:5900"   → display 5900 → 端口 11800（错）
            // 要指定绝对端口得写 "127.0.0.1::5900"（双冒号，空 display 号）。
            //
            // 我们用单冒号 + 从 5900 反推 display 号，避免二义性。
            int display = m.vncPort - 5900;
            if (display < 0 || display > 99) display = 0;
            p.add("127.0.0.1:" + display);
        }
        if (m.serialTcpPort > 0) {
            p.add("-serial");
            p.add("tcp:127.0.0.1:" + m.serialTcpPort + ",server,nowait");
        }
        if (m.monitorTcpPort > 0) {
            p.add("-monitor");
            p.add("tcp:127.0.0.1:" + m.monitorTcpPort + ",server,nowait");
        }
    }

    // ------------------------------------------------------------ cpu/board

    static void addCpuBoardOptions(Machine m, List<String> p) {
        // gic-version=3 是硬要求：Linux 6.x 的 GICv3 驱动要它，缺了起不来
        p.add("-M");
        p.add(m.machineType == null || m.machineType.isEmpty()
                ? "virt,gic-version=3"
                : m.machineType);

        p.add("-cpu");
        p.add(m.cpu == null || m.cpu.isEmpty() ? "max" : m.cpu);

        if (m.smp > 0) {
            p.add("-smp");
            p.add(String.valueOf(m.smp));
        }
        if (m.memoryMb > 0) {
            p.add("-m");
            p.add(String.valueOf(m.memoryMb));
        }
    }

    // -------------------------------------------------------------- drives

    static void addDrives(Machine m, List<String> p) {
        if (m.disk == null || m.disk.isEmpty()) return;
        p.add("-drive");
        p.add("if=none,id=d0,format=" + fmt(m.diskFormat) + ",file=" + m.disk);
        p.add("-device");
        p.add("virtio-blk-pci,drive=d0");
    }

    static void addRemovableDrives(Machine m, List<String> p) {
        if (m.iso != null && !m.iso.isEmpty()) {
            // 用 -cdrom 而不是手工拼 -drive：UEFI 会自动把它当成可引导光驱
            p.add("-cdrom");
            p.add(m.iso);
        }
    }

    // ---------------------------------------------------------------- boot

    static void addBootOptions(Machine m, List<String> p) {
        if (m.kernel != null && !m.kernel.isEmpty()) {
            p.add("-kernel");
            p.add(m.kernel);
        }
        if (m.initrd != null && !m.initrd.isEmpty()) {
            p.add("-initrd");
            p.add(m.initrd);
        }
        if (m.append != null && !m.append.isEmpty()) {
            p.add("-append");
            p.add(m.append);
        }
    }

    // ------------------------------------------------------------ graphics

    static void addGraphicsOptions(Machine m, List<String> p) {
        // 注意：光有 virtio-gpu 设备不够，客机内核必须有 virtio_gpu 驱动。
        // Debian 的 -cloud 内核把它裁掉了（13.66），要装 linux-image-arm64。
        if (m.gpuEnabled) {
            p.add("-device");
            p.add("virtio-gpu-pci");
        }
        p.add("-display");
        p.add("none");   // 画面只走 VNC，不要在客体上再开一个本地窗口

        if (m.vncPort >= 0) {
            // VNC 起不来时会报 "could not find keymap file for language 'en-us'"
            // 需要把 pc-bios/keymaps/en-us 放进 -L 目录
            p.add("-L");
            p.add(m.biosDir == null ? "/data/local/tmp/henge/bios" : m.biosDir);
        }
    }

    // --------------------------------------------------------------- input

    /**
     * USB HID 输入。**不能用 virtio-keyboard-pci** —— 实测会让 henge 直接退出
     * （13.66）。而 usb-tablet 是绝对坐标设备，VNC 客户端发绝对坐标必须用它，
     * usb-mouse 是相对位移会漂（limbo 也只给用户这几个 USB 选项）。
     */
    static void addInputOptions(Machine m, List<String> p) {
        if (!m.inputEnabled) return;
        p.add("-device");
        p.add("qemu-xhci,id=xhci");
        if (m.keyboardEnabled) {
            p.add("-device");
            p.add("usb-kbd,bus=xhci.0");
        }
        if (m.pointerEnabled) {
            p.add("-device");
            p.add("usb-tablet,bus=xhci.0");
        }
    }

    // --------------------------------------------------------------- audio

    static void addAudioOptions(Machine m, List<String> p) {
        if (m.audioDriver == null || m.audioDriver.isEmpty()) return;
        p.add("-audiodev");
        p.add(m.audioDriver);
    }

    // ------------------------------------------------------------- network

    static void addNetworkOptions(Machine m, List<String> p) {
        if (!m.netEnabled) return;
        p.add("-netdev");
        p.add("user,id=n0");
        p.add("-device");
        p.add("virtio-net-pci,netdev=n0");
    }

    // ------------------------------------------------------------- generic

    static void addGenericOptions(Machine m, List<String> p) {
        if (m.name != null && !m.name.isEmpty()) {
            p.add("-name");
            p.add(m.name);
        }
        if (m.biosDir != null && !m.biosDir.isEmpty() && m.useUefi) {
            p.add("-drive");
            p.add("if=pflash,format=raw,unit=0,file=" + m.biosDir
                    + "/edk2-aarch64-code.fd,readonly=on");
            p.add("-drive");
            p.add("if=pflash,format=raw,unit=1,file=" + m.varsImage);
        }
    }

    static void addStateOptions(Machine m, List<String> p) {
        if (m.incomingFd >= 0) {
            p.add("-incoming");
            p.add("fd:" + m.incomingFd);
        }
    }

    static void addAdvancedOptions(Machine m, List<String> p) {
        if (m.extraParams == null || m.extraParams.isEmpty()) return;
        for (String s : m.extraParams.trim().split("\\s+")) {
            if (!s.isEmpty()) p.add(s);
        }
    }

    // -------------------------------------------------------- acceleration

    /**
     * 加速器必须在**最后**加：QEMU 对同一选项取第一个出现的实例，
     * 放前面的话用户写在 extraParams 里的 -accel 就覆盖不了它。
     * 这条是从 limbo 的 {@code addAccelerationOptions} 注释里学来的。
     *
     * <p>但"排最后"还不够。实测出过这个问题：
     * {@code extraParams="-accel tcg"} 会生成
     * {@code ... -accel tcg -accel henge}，两个 -accel 并存。
     * QEMU 取第一个所以能跑，但**日志里写着 henge、实际跑的是 tcg** ——
     * 这种"看起来对其实不是"的状态比直接报错更糟。
     *
     * <p>所以这里改成：如果用户自己指定了 -accel，就**完全不加**默认值。
     * 只留一个，谁的就是谁的。
     */
    static void addAccelerationOptions(Machine m, List<String> p) {
        if (hasOption(p, "-accel")) {
            return;   // 用户已指定，不重复
        }
        p.add("-accel");
        p.add(m.accel == null || m.accel.isEmpty() ? "henge" : m.accel);
    }

    /** 判断某个选项是否已在列表里。 */
    private static boolean hasOption(List<String> p, String opt) {
        for (String s : p) {
            if (s.equals(opt)) return true;
        }
        return false;
    }

    static String fmt(String format) {
        return format == null || format.isEmpty() ? "qcow2" : format;
    }

    /** 转成数组，方便 JNI / ProcessBuilder 使用。 */
    public static String[] buildArray(Machine m) {
        List<String> l = build(m);
        return l.toArray(new String[0]);
    }
}
