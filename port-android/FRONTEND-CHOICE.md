# arm64→arm64 前端方案选型：Limbo / VectrasVM / Termux

**日期**：2026-11-18
**前提**：引擎侧已经跑通（`qemu-system-aarch64 -accel henge`，Linux 客机有图形、键鼠通）。
现在缺的是**外面那一层**：APK、输入归一化、生命周期、音频。
**约束**：不要让 VM 活在 Activity 的生命周期里。

---

## 一、三者是什么

| | Limbo | VectrasVM | Termux |
|---|---|---|---|
| QEMU 来源 | **源码编进 .so**（JNI 进程内） | **预编译二进制**（`base-qemu-7.2.22.tar.gz` bootstrap） | 预编译二进制（`.deb`，`qemu-system-aarch64`） |
| 与 QEMU 的关系 | fork + patch（`qemu-5.1.0.patch` 576 行） | **fork 侵入 App 层**，QEMU 本体不动 | **完全不侵入**，把 QEMU 当命令行程序 |
| 进程模型 | 进程内调用 JNI | **fork/exec qemu 二进制** + PRoot | fork/exec |
| 前端显示 | VNC（内置客户端）/ SDL | **VNC**（`android-vnc-viewer`） | VNC / termux-x11 |
| 输入 | SDL 扩展（`SDL_limbomouse.c`）→ QEMU | VNC 协议（天然绝对坐标） | VNC 协议 |
| rootfs 依赖 | 无（直接挂 img） | **PRoot** + Alpine/Mesa container | 无（Termux 自己的 prefix） |
| Jetpack/现代 UI | ❌ `PreferenceActivity`（API 1 老古董） | ✅ Compose/Fragment | ❌ 命令行 |
| 维护状态 | 5.x/6.x 活跃 | **已宣布停更，迁到 BreadVM** | Termux 主仓活跃 |

### 一句话概括三者的主轴差异

用户说的"fork 侵入 vs 插件接入"完全准确，但**三种都各有各的侵入点**：

- **Limbo**：侵入 **QEMU 源码**（打 patch），换来**进程内、零 IPC、可 SDL 直连**。
- **VectrasVM**：侵入 **App 层**（包 PRoot、包 bootstrap、包 3dfx 包装），
  换来"支持任意架构 + 3Dfx"，代价是**多一层 fork/exec + PRoot 的 syscall 拦截**。
- **Termux**：**零侵入**，QEMU 是黑盒二进制；代价是**没有 UI**，只能命令行。

---

## 二、对我们的适配度（arm64→arm64，引擎已在进程内）

这一条是决定性的：**我们的引擎已经是 QEMU 里的一个 `accel`**，
`-accel henge` 是 libqemu 的内部实现，**不是外部进程**。

所以：

| | 能不能用我们的 `-accel henge` |
|---|---|
| **Limbo 路线**（编进 .so） | ✅ **能**。`accel/henge` 跟着 `.so` 一起编进去，JNI 里 `qemu_main()` 直接跑 |
| **VectrasVM 路线**（外部二进制 + PRoot） | ❌ **多一层没用的**。我们已经不需要 PRoot，也不需要 fork/exec QEMU；套上去只是增加 syscall 拦截开销 |
| **Termux 路线**（外部二进制） | ⚠ **能用但没有 UI**。等于我们现在 `adb shell` 的形态，只多了个 Termux 终端 |

**结论：只有 Limbo 的形态与"引擎在进程内"这个事实匹配。**

---

## 三、Limbo 的生命周期设计：它已经做对了，值得照抄

用户担心"VM 活在 Activity 生命周期里"。查 `MachineService.java` 的类注释：

> *"MachineService is responsible **only** for owning and starting the thread that
> executes the jni part. This implementation is needed for Android to make sure that
> the process is started from a **foreground service** so it will remain alive but
> with its thread running in the background. All other communications with the native
> process will happen via **MachineController → MachineExecutor**."*

也就是说 Limbo 的分层是：

```
LimboActivity (UI)
    │  只发命令、只收状态
    ▼
MachineController  ← 单例，持有 Machine 状态、事件回调
    │
    ▼
MachineService (前台 Service + Notification + WakeLock + WifiLock)
    │  持有 LimboThread（VM 真正跑在这个线程上）
    ▼
MachineExecutor (接口) ──► VMExecutor (JNI) ──► libqemu-system-aarch64.so
```

**Activity 死了 VM 照样跑**，因为它根本不持有 VM 线程。
这正是用户要的"先解耦模块化实现"。而且它顺手处理了保活：

```java
private void setupLocks() {
    mWakeLock  = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, ...);
    mWifiLock  = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, ...);
}
```

---

## 四、Limbo 的界面设置：`prepareParams()` 的九段式

这是**最值得直接搬**的部分。它没有一个大 `switch` 拼命令行，而是按职责拆成九段：

```java
private String[] prepareParams(Context context) {
    ArrayList<String> p = new ArrayList<>();
    p.add(getQemuLibrary());
    addUIOptions(context, p);        // -vnc / -display
    addCpuBoardOptions(p);           // -M / -cpu / -smp
    addDrives(p);                    // -drive
    addRemovableDrives(p);           // cd/fda/fdb/sd
    addBootOptions(p);               // -kernel / -initrd / -append
    addGraphicsOptions(p);           // -vga / -device
    addAudioOptions(p);              // -audiodev
    addNetworkOptions(p);            // -netdev / -device
    addGenericOptions(context, p);   // -name / -m / -monitor
    addStateOptions(p);              // -incoming（恢复快照）
    addAdvancedOptions(p);           // 用户的自定义参数
    addAccelerationOptions(p);       // -accel
    return p.toArray(new String[0]);
}
```

**这个结构的价值不在代码，在"每一段只读 Machine 里属于自己的字段"**。
我们的 `Machine` 只需要多一个 `accel` 字段（值 `henge`），其余原样可用。

对应到我们已经验证过的参数，映射是这样：

| Limbo `addXxxOptions` | 我们要写的内容 | 验证状态 |
|---|---|---|
| `addUIOptions` | `-vnc 127.0.0.1:0` | ✅ 13.64 |
| `addCpuBoardOptions` | `-M virt,gic-version=3 -cpu max -smp 2` | ✅ |
| `addGraphicsOptions` | `-device virtio-gpu-pci` | ✅ 13.67 |
| `addAudioOptions` | 待做 | ⏳ |
| `addAccelerationOptions` | `-accel henge` | ✅ |
| （Limbo 没有） | `-device qemu-xhci,usb-kbd,usb-tablet` | ✅ 13.67，**必须加** |
| （Limbo 没有） | `SLIRP_DNS_SERVER` 环境变量 | ✅ 13.55 |

**注意最后两行**：Limbo 的九段式里**没有输入设备段**——它是靠 SDL 直连解决输入的。
我们走 VNC + USB HID，所以需要**多一个 `addInputOptions()`**。

---

## 五、建议的模块化拆分（按解耦方式补，不 fork Limbo）

用户要求"别让 VM 活在 Activity 生命周期里"，且"按解耦方式补"。
建议**不 fork Limbo 整个 App**，而是分四层，每层可以独立替换：

```
┌─────────────────────────────────────────────────┐
│  app-ui            设置页 / 列表 / VNC 客户端     │  ← 抄 Limbo 的九段式结构
│                    (Activity/Fragment，随时可死)  │
└────────────────────┬────────────────────────────┘
                     │ 只发 intent / 收 broadcast
┌────────────────────▼────────────────────────────┐
│  vm-control        MachineController（单例）      │  ← 状态机 + 事件总线
│                    Machine 数据模型 + DB          │  ← 抄 Limbo 的扁平字段
└────────────────────┬────────────────────────────┘
                     │ 方法调用
┌────────────────────▼────────────────────────────┐
│  vm-service        Foreground Service            │  ← 抄 Limbo：持有 VM 线程
│                    WakeLock / WifiLock / 通知     │     Activity 死不影响
└────────────────────┬────────────────────────────┘
                     │ JNI
┌────────────────────▼────────────────────────────┐
│  vm-engine         libqemu .so（含 accel/henge） │  ← 我们的，已完成
│  + vm-input        输入归一化（VNC→QEMU）         │  ← 已有 usb-tablet 方案
│  + vm-audio        音频（后续）                   │
└─────────────────────────────────────────────────┘
```

**关键点：Activity 只与 `vm-control` 通信，永远不 import `vm-engine`。**
这样之后要加 su/root 保活、要换前端（SDL/原生 Surface）、要做后台服务，
都只动一层。

### 保活怎么留口子

不要现在就用 root。按用户的说法"之后可以用 su/root 保活"，所以现在做两件事：

1. **前台 Service + 常驻通知**（无权限，Android 8+ 就够）
2. **把"线程归属"抽象成一个接口**：
   ```java
   interface VmHost {
       void start(Machine m);   // 前台 Service 实现
       void stop();
   }
   ```
   之后要加 root 保活（`su -c` 起 `:vm` 独立进程 / 双进程互拉），
   只需换一个 `VmHost` 实现，UI 与 engine 都不动。

---

## 六、三者各自该"借"什么

| 来源 | 借什么 | 明确不借什么 |
|---|---|---|
| **Limbo** | ① 九段式 `prepareParams` 结构<br>② 前台 Service 持有 VM 线程<br>③ 扁平 `Machine` 数据模型 + DB<br>④ 设置页的字段分组方式 | ❌ 它的 QEMU 5.1 补丁（版本差太远）<br>❌ `PreferenceActivity`（老 API）<br>❌ SDL 输入层（我们走 VNC） |
| **VectrasVM** | ① "设置项 → 分组 UI" 的组织经验<br>② bootstraps 的版本管理思路（多版本并存） | ❌ PRoot（我们不需要）<br>❌ fork/exec QEMU（引擎已在进程内）<br>❌ 它的品牌/图标（有明确授权限制） |
| **Termux** | ① 构建脚本的依赖管理（我们已在用它的 x11 思路） | ❌ 命令行形态（我们是 GUI App） |

---

## 七、下一步（按依赖顺序）

1. **先把 `Machine` 数据模型定下来**（含 `accel=henge`、`inputs=[kbd,tablet]`、
   `net.dns=<SLIRP_DNS_SERVER>`），照 Limbo 的扁平字段。
2. **`prepareParams()` 九段 + 一段**（加 `addInputOptions`），
   用单元测试对着我们已经验证过的那条命令行做 golden test。
3. **前台 Service 骨架**（`VmHost` 接口 + 默认实现），只做"起/停/通知"。
4. **VNC 客户端接进来**（可以用 `android-vnc-viewer`，它是 Apache-2.0）。
5. 之后才碰音频与 root 保活。

**为什么这个顺序**：1、2 是纯逻辑，不需要设备，可以先写完再上机；
3 是最容易做错的一层（生命周期）；4 是最容易"看起来能跑"的一层。

---

## 八、需要提醒的两个事实

1. **VectrasVM 已宣布停止新功能开发**，作者迁往 BreadVM。
   现在把架构押在它上面不是好选择——这也侧面支持"参考 Limbo"的判断。
2. **Limbo 的 UI 是 `PreferenceActivity` + 原生 Android 老式布局**。
   九段式*逻辑*值得抄，*界面代码*不值得。设置页应该用现代的
   Compose/RecyclerView 重写，只照搬它的**字段分组**。

---

## 附录：已落地的实现与实测（2026-11-18）

文档写完后又把九段式**真的实现了一遍并跑通**，代码在 `work/android/`：

| 文件 | 作用 |
|---|---|
| `Machine.java` | 扁平数据模型（照 Limbo），默认值取自已验证的那套 |
| `HengeParams.java` | 九段 + 一段（`addInputOptions`）的参数生成器，**不依赖 Android API** |
| `Check.java` | 零依赖自检，210 项断言，一条命令跑完 |
| `HengeParamsTest.java` | JUnit 版本（给将来的 Gradle 工程用） |

```sh
javac -encoding UTF-8 -d /tmp/hc work/android/HengeParams.java \
      work/android/Machine.java work/android/Check.java
java -cp /tmp/hc Check
# === 210 passed, 0 failed ===
```

### 实现过程中抓到的两个真 bug（都已修 + 加断言）

**1. `-vnc 127.0.0.1:5900` 实际监听在 11800**

QEMU 的 `-vnc host:N` 里 `N` 是 **display 号**，端口 = `5900 + N`
（`ui/vnc.c:3855`：`int offset = reverse ? 0 : 5900;` 然后 `baseport + offset`）。
写成 `:5900` 就是 display 5900 → 端口 11800，客户端打 5900 永远连不上。

- 症状：进程在跑、`-vnc` 参数看起来完全正确、日志无报错、**端口就是不通**
- 正确写法：`:0`（→5900），或绝对端口用 `host::5900`（双冒号）

**2. `-accel` 会重复出现两个**

用户写 `extraParams="-accel tcg"` 时，我原来会生成
`... -accel tcg -accel henge`。QEMU 取第一个所以能跑，
但**日志里写着 henge、实际跑的是 tcg** —— 这种"看起来对其实不是"比报错更糟。
改成：用户指定了就不再追加默认值。

### 用生成的命令行真跑了一次

```
$ java -cp /tmp/hc Check | grep -A1 可复现命令行
SLIRP_DNS_SERVER=223.5.5.5 qemu-system-aarch64 -vnc 127.0.0.1:0 -serial ... \
  -M virt,gic-version=3 -cpu max -smp 2 -m 2048 ... -accel henge
```

推设备执行后：

```
(qemu) info vnc
  Server: 127.0.0.1:5900 (ipv4)
    Auth: none

RFB banner:  b'RFB 003.008\n'
security:    [1]
auth:        0
ServerInit:  1280x800 depth=0  name=QEMU (henge)     ← 是我们的引擎
```

**不是"字符串对上了"，是这条命令真的把机器起起来了。**
