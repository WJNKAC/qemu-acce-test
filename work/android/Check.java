import com.henge.vm.control.HengeParams;
import com.henge.vm.control.Machine;

import java.util.*;

/**
 * Check.java —— 零依赖自检（不需要 JUnit / Gradle / Android）。
 *
 * <p>为什么要它：这套参数逻辑最需要的是"改一行就能立刻验证"。
 * 装 JUnit 要拉依赖、建 Gradle 工程，在只装 JDK 的机器上跑不起来。
 * 而这里要断言的东西很简单（某对 "-k v" 在不在），
 * 自己写三十行就够了——**测试的价值在断言的内容，不在框架**。
 *
 * <p>用法：
 * <pre>
 *   javac -d /tmp/hc work/android/*.java
 *   java -cp /tmp/hc Check
 * </pre>
 * 退出码 0 = 全过。
 */
public final class Check {

    private static int pass = 0;
    private static int fail = 0;
    private static final List<String> FAILS = new ArrayList<>();

    public static void main(String[] args) {
        Machine m = Machine.golden();
        List<String> p = HengeParams.build(m);

        // ---- 程序名 ----
        eq("argv[0]", "qemu-system-aarch64", p.get(0));

        // ---- 主板（13.64~13.67 验证过的）----
        has(p, "-M", "virt,gic-version=3");
        has(p, "-cpu", "max");
        has(p, "-smp", "2");
        has(p, "-m", "2048");

        // ---- 加速器 ----
        has(p, "-accel", "henge");

        // ---- 显示 ----
        contains(p, "virtio-gpu-pci");
        // ⚠ -vnc 的 ":N" 是 **display 号**，端口 = 5900+N（ui/vnc.c:3855）。
        // 第一版写成 "127.0.0.1:5900"，QEMU 就把 display 当 5900、
        // 实际监听 11800 —— 而打 5900 永远连不上。这个断言防它回退。
        has(p, "-vnc", "127.0.0.1:0");
        ok("-vnc 不能写成端口号（会被当 display 号）",
                !p.contains("127.0.0.1:5900"));
        has(p, "-display", "none");

        // ---- 输入三件套（缺 usb-kbd 会让 sendkey 静默失效）----
        has(p, "-device", "qemu-xhci,id=xhci");
        has(p, "-device", "usb-kbd,bus=xhci.0");
        has(p, "-device", "usb-tablet,bus=xhci.0");

        // ---- 存储 ----
        has(p, "-drive", "if=none,id=d0,format=qcow2,file=" + m.disk);
        has(p, "-device", "virtio-blk-pci,drive=d0");

        // ---- 网络 ----
        has(p, "-netdev", "user,id=n0");
        has(p, "-device", "virtio-net-pci,netdev=n0");

        // ---- 调试通道 ----
        has(p, "-monitor", "tcp:127.0.0.1:4490,server,nowait");
        has(p, "-serial", "tcp:127.0.0.1:4491,server,nowait");

        // ---- DNS 必须走环境变量 ----
        Map<String, String> e = HengeParams.env(m);
        eq("SLIRP_DNS_SERVER", "223.5.5.5", e.get("SLIRP_DNS_SERVER"));
        for (String s : p) {
            ok("DNS 不该出现在命令行里: " + s, !s.contains("SLIRP_DNS"));
        }

        // ---- 加速器：用户指定了就不能再出现第二个 ----
        // 第一版把断言写反了（以为 -accel 要在 tcg 之后），实际要求的是
        // "只出现一个 -accel，且值是用户的"。两个并存时 QEMU 取第一个能跑，
        // 但日志写着 henge 实际跑 tcg —— 这种状态必须杜绝。
        Machine m2 = Machine.golden();
        m2.extraParams = "-accel tcg";
        List<String> p2 = HengeParams.build(m2);
        int nAccel = 0;
        for (String s : p2) if (s.equals("-accel")) nAccel++;
        eq("用户指定 -accel 后不应再有默认值", 1, nAccel);
        // 注意：不能直接 p2.contains("henge") 判断 —— 机器名 "-name henge"
        // 里也有 henge，会把正确实现误判成错。必须只看 -accel 的**值**。
        eq("-accel 的值应是用户的 tcg", "tcg", valueOf(p2, "-accel"));

        // ---- 关掉输入就不该有 USB ----
        Machine m3 = Machine.golden();
        m3.inputEnabled = false;
        for (String s : HengeParams.build(m3)) {
            ok("关输入后不该有 " + s,
                    !s.contains("usb-kbd") && !s.contains("usb-tablet")
                            && !s.contains("qemu-xhci"));
        }

        // ---- 没磁盘就不生成空 -drive ----
        Machine m4 = Machine.golden();
        m4.disk = null;
        ok("没磁盘不该有 virtio-blk-pci",
                !HengeParams.build(m4).contains("virtio-blk-pci,drive=d0"));

        // ---- 参数里不能有意外空白 ----
        for (String s : p) {
            ok("参数含空白: [" + s + "]", s.indexOf(' ') < 0 && s.indexOf('\t') < 0);
            ok("参数为空", !s.isEmpty());
        }

        // ---- 每个选项后面都要有值 ----
        for (int i = 1; i < p.size(); i++) {
            String a = p.get(i);
            if (a.startsWith("-")) {
                ok("选项 " + a + " 后面没有值", i + 1 < p.size());
            }
        }

        // ---- 打印可复现命令 ----
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> en : HengeParams.env(m).entrySet()) {
            sb.append(en.getKey()).append('=').append(en.getValue()).append(' ');
        }
        for (String s : p) sb.append(s).append(' ');
        System.out.println("\n--- 可复现命令行 ---");
        System.out.println(sb.toString().trim());

        System.out.printf("%n=== %d passed, %d failed ===%n", pass, fail);
        for (String f : FAILS) System.out.println("  FAIL: " + f);
        System.exit(fail == 0 ? 0 : 1);
    }

    // ------------------------------------------------------------ 断言

    private static void ok(String what, boolean cond) {
        if (cond) pass++;
        else {
            fail++;
            FAILS.add(what);
        }
    }

    private static void eq(String what, Object want, Object got) {
        ok(what + " 期望 [" + want + "] 实际 [" + got + "]",
                want == null ? got == null : want.equals(got));
    }

    private static void contains(List<String> l, String v) {
        ok("应包含 " + v, l.contains(v));
    }

    /** 取某个选项紧跟的值；没有则返回 null。 */
    private static String valueOf(List<String> l, String k) {
        for (int i = 0; i < l.size() - 1; i++) {
            if (l.get(i).equals(k)) return l.get(i + 1);
        }
        return null;
    }

    private static void has(List<String> l, String k, String v) {
        boolean found = false;
        for (int i = 0; i < l.size() - 1; i++) {
            if (l.get(i).equals(k) && l.get(i + 1).equals(v)) {
                found = true;
                break;
            }
        }
        ok("缺 [" + k + " " + v + "]", found);
    }
}
