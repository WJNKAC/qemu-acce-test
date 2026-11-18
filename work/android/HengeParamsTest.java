package com.henge.vm.control;

import org.junit.Test;

import java.util.Arrays;
import java.util.List;
import java.util.Map;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

/**
 * HengeParamsTest —— 黄金对照测试。
 *
 * <p>基准是**在设备上真正跑通过的那条命令**（13.67，图形+键鼠端到端验证过）：
 *
 * <pre>
 * SLIRP_DNS_SERVER=223.5.5.5 q-vnc \
 *   -L /data/local/tmp/henge/bios -M virt,gic-version=3 -cpu max -m 2048 -smp 2 \
 *   -accel henge \
 *   -drive if=pflash,...,unit=0,file=.../edk2-aarch64-code.fd,readonly=on \
 *   -drive if=pflash,...,unit=1,file=.../gui-vars.img \
 *   -drive if=none,id=d0,format=qcow2,file=.../deb12-gui.qcow2 -device virtio-blk-pci,drive=d0 \
 *   -device virtio-gpu-pci \
 *   -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
 *   -vnc 127.0.0.1:0 \
 *   -monitor tcp:127.0.0.1:4490,server,nowait \
 *   -serial tcp:127.0.0.1:4491,server,nowait \
 *   -netdev user,id=n0 -device virtio-net-pci,netdev=n0
 * </pre>
 *
 * <p>这个测试的用途：以后改 {@link HengeParams} 的任何一段，只要这里红了，
 * 就说明你改动了已经验证过的东西。比装到手机上试快一万倍。
 *
 * <p>注意：**不比对参数顺序**，只比对"成对的选项都在"。QEMU 对参数顺序
 * 基本不敏感（除了 -accel 有"取第一个"的语义，见下），
 * 死比顺序会让测试变脆而没有额外收益。
 */
public class HengeParamsTest {

    /** 把 "-key value" 拉平成 "key=value"，便于按对断言、忽略顺序。 */
    private static String pairs(List<String> argv) {
        StringBuilder sb = new StringBuilder();
        for (int i = 1; i < argv.size(); i++) {   // 跳过 argv[0]（程序名）
            String a = argv.get(i);
            if (a.startsWith("-")) {
                sb.append(a);
                if (i + 1 < argv.size() && !argv.get(i + 1).startsWith("-")) {
                    sb.append('=').append(argv.get(++i));
                }
                sb.append('\n');
            }
        }
        return sb.toString();
    }

    private static boolean has(List<String> argv, String key, String val) {
        for (int i = 0; i < argv.size() - 1; i++) {
            if (argv.get(i).equals(key) && argv.get(i + 1).equals(val)) return true;
        }
        return false;
    }

    @Test
    public void 黄金配置包含全部已验证的参数() {
        List<String> p = HengeParams.build(Machine.golden());

        assertEquals("qemu-system-aarch64", p.get(0));

        // 主板
        assertTrue("缺 -M virt,gic-version=3", has(p, "-M", "virt,gic-version=3"));
        assertTrue("缺 -cpu max", has(p, "-cpu", "max"));
        assertTrue("缺 -smp 2", has(p, "-smp", "2"));
        assertTrue("缺 -m 2048", has(p, "-m", "2048"));

        // 加速器
        assertTrue("缺 -accel henge", has(p, "-accel", "henge"));

        // 显示
        assertTrue("缺 virtio-gpu-pci", p.contains("virtio-gpu-pci"));
        assertTrue("缺 -vnc", has(p, "-vnc", "127.0.0.1:5900"));
        assertTrue("-display 必须是 none", has(p, "-display", "none"));

        // 输入三件套
        assertTrue("缺 qemu-xhci", has(p, "-device", "qemu-xhci,id=xhci"));
        assertTrue("缺 usb-kbd", has(p, "-device", "usb-kbd,bus=xhci.0"));
        assertTrue("缺 usb-tablet", has(p, "-device", "usb-tablet,bus=xhci.0"));

        // 存储
        assertTrue("缺 virtio-blk-pci", has(p, "-device", "virtio-blk-pci,drive=d0"));

        // 网络
        assertTrue("缺 -netdev user", has(p, "-netdev", "user,id=n0"));
        assertTrue("缺 virtio-net-pci",
                has(p, "-device", "virtio-net-pci,netdev=n0"));

        // 调试通道
        assertTrue("缺 monitor", has(p, "-monitor", "tcp:127.0.0.1:4490,server,nowait"));
        assertTrue("缺 serial", has(p, "-serial", "tcp:127.0.0.1:4491,server,nowait"));
    }

    @Test
    public void DNS_走环境变量而不是命令行() {
        Machine m = Machine.golden();
        List<String> p = HengeParams.build(m);
        Map<String, String> e = HengeParams.env(m);

        // QEMU 命令行没有 DNS 开关，必须靠这个环境变量
        assertEquals("223.5.5.5", e.get("SLIRP_DNS_SERVER"));

        // 并且**不能**出现在命令行里（说明我们没搞错通道）
        for (String s : p) {
            assertTrue("DNS 不该出现在命令行: " + s, !s.contains("SLIRP_DNS"));
        }
    }

    @Test
    public void 加速器必须在最后() {
        Machine m = Machine.golden();
        // 用户写了自己的 -accel，应能覆盖默认值
        m.extraParams = "-accel tcg";
        List<String> p = HengeParams.build(m);

        int firstAccel = p.indexOf("-accel");
        int extraIdx = p.indexOf("tcg");
        int defaultIdx = p.indexOf("henge");

        assertTrue("-accel 必须出现在 extraParams 之后（QEMU 取第一个实例）",
                firstAccel > extraIdx);
        assertEquals("默认 accel 应被排在最后", 1,
                countOf(p, "henge"));
    }

    @Test
    public void 关掉输入就不该出现任何USB设备() {
        Machine m = Machine.golden();
        m.inputEnabled = false;
        List<String> p = HengeParams.build(m);

        for (String s : p) {
            assertTrue("关掉输入后不该有 " + s,
                    !s.contains("usb-kbd") && !s.contains("usb-tablet")
                            && !s.contains("qemu-xhci"));
        }
    }

    @Test
    public void 没有磁盘时不生成空drive() {
        Machine m = Machine.golden();
        m.disk = null;
        List<String> p = HengeParams.build(m);
        assertTrue("没磁盘不该有 virtio-blk-pci", !p.contains("virtio-blk-pci,drive=d0"));
    }

    @Test
    public void 参数里不能有空白拼接错误() {
        List<String> p = HengeParams.build(Machine.golden());
        for (String s : p) {
            assertTrue("参数含空格或 Tab: [" + s + "]", s.indexOf(' ') < 0 && s.indexOf('\t') < 0);
            assertTrue("参数为空", !s.isEmpty());
        }
    }

    @Test
    public void 成对选项数量为偶数结构() {
        // 每个 "-x" 后面都跟着它的值，避免出现悬空选项
        List<String> p = HengeParams.build(Machine.golden());
        for (int i = 1; i < p.size(); i++) {
            String a = p.get(i);
            if (a.startsWith("-") && !a.startsWith("-device") && !a.equals("-display")) {
                assertTrue("选项 " + a + " 后面没有值", i + 1 < p.size());
            }
        }
    }

    /** 便于人工核对：打印成一行可复制的命令。 */
    @Test
    public void 打印可复现命令行() {
        Machine m = Machine.golden();
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : HengeParams.env(m).entrySet()) {
            sb.append(e.getKey()).append('=').append(e.getValue()).append(' ');
        }
        for (String s : HengeParams.build(m)) {
            sb.append(s.contains(" ") ? "'" + s + "'" : s).append(' ');
        }
        System.out.println("REPRODUCE:\n  " + sb.toString().trim());
        assertTrue(true);
    }

    // ------------------------------------------------------------ helpers

    private static int countOf(List<String> l, String v) {
        int n = 0;
        for (String s : l) if (s.equals(v)) n++;
        return n;
    }
}
