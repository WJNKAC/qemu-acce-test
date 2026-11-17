# passt 后端启动方式

## 为什么需要 passtlaunch

`-netdev stream` + `passt --socket <path>` 在 adb shell 域被 SELinux 拒：

```
Failed to bind UNIX domain socket: Permission denied
```

连 abstract socket（`@name`）也被拒 —— 是域策略，不是路径问题。
搬到 Termux 域能 bind，但那边 Seccomp=2，passt 启动即 SIGSYS。

## 方案：socketpair + --fd

`socketpair()` 不 bind、不碰文件系统，adb shell 域实测可用。
两端各拿一个 fd，都不需要 bind：

```
passtlaunch ./passt -f -q -F %PFD% -D 223.5.5.5 -- \
  ./q-p0a8 ... -netdev socket,id=n0,fd=%QFD% -device virtio-net-pci,netdev=n0
```

## 必须项

| 项 | 为什么 |
|---|---|
| `HV_PASST_NO_SECCOMP=1` | passt 自装 glibc 风格 seccomp 白名单，bionic 下必死 |
| `HV_PASST_NO_SANDBOX=1` | `unshare(IPC\|NS\|UTS\|PID)` 要 CAP_SYS_ADMIN |
| `HV_PASST_NO_USERNS=1` | 读不到 `/proc/self/uid_map` |
| `-D 223.5.5.5` | Android 无 `/etc/resolv.conf`，passt 取不到 nameserver |
| **不要给 `-a` / `-g`** | 给了宿主不拥有的地址会双峰（见 FINDINGS.md 归因） |

## 实测（vivo V2156FA, 2026-11-18）

```
PASSTPROBE-ADDR  enp0s1 169.254.2.1/8
PASSTPROBE-GW    gw=192.168.1.1              ← 宿主真实网关
PASSTPROBE-TCP-GW80       state=refused      ← 网络通
PASSTPROBE-CURL-TUNA      code=301
PASSTPROBE-THROUGHPUT     Bps_code=5719198 200   ← 5.72 MB/s
```

对照 slirp 基线 4.9–8.5 MB/s：**同量级**。
