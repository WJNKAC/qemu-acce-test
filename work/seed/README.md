# seed v2：让 guest 自己周期 reboot

## 为什么

`system_reset` 是 QEMU 侧硬复位（设备拉到冷态、驱动从头初始化），
而 C6 原本要测的"重启"若是 guest 内 `reboot`（PSCI SYSTEM_RESET，
驱动走 warm reset 路径），两者对网卡状态机的压力完全不同。
要测后者，必须有 guest 内的执行通道 —— 而镜像**没有 sshd、没有 getty**。

## 关键设计：循环载体是 systemd 单元，不是 cloud-init 模块

cloud-init 的 `write_files` / `runcmd` / `power_state` 是 **per-instance** 语义：

1. 第一轮之后 instance-id 不变 → 全部跳过
2. **同一个 instance-id 第二次出现时也跳过**（`/var/lib/cloud/instances/<id>` 有记录）

所以 `meta-data` 的 instance-id **必须每次唯一**（`deb12-hv-<epoch>`）。
循环本身由 `netprobe.timer`（`OnBootSec=60`）自持，与 cloud-init 无关。

## 三件套

| 文件 | 作用 |
|---|---|
| `/usr/local/bin/netprobe` | 打地址/路由/TCP 三态/curl，然后 `systemctl reboot` |
| `/etc/systemd/system/netprobe.service` | `Type=oneshot`，`SuccessExitStatus=0 1` |
| `/etc/systemd/system/netprobe.timer` | `OnBootSec=60` |

## `datasource_list: [NoCloud, None]`

禁掉 metadata 探测。`169.254.169.254` 在 slirp 下永远不可达，
不禁掉 cloud-init 会白等 120 秒 —— boot 时间线上最大的单一常数。
实测：uptime 从 97s（首轮）→ **60.4s**（后续轮）。

## 判据（全部在 serial，不需要登录）

```
NETPROBE-BEGIN round=N uptime=XX.XX
NETPROBE-ADDR  enp0s1 10.0.2.15/24
NETPROBE-GW    gw=10.0.2.2
NETPROBE-TCP-GW22  state=refused|timeout|ok
NETPROBE-CURL      code=200|000
NETPROBE-END round=N
```

**三态语义（这一条最容易错）**：

| state | 含义 |
|---|---|
| `ok` | 连上了，服务在 |
| `refused` | 收到 RST —— **网络通**，只是那个端口没服务 |
| `timeout` | 无应答 —— **这才是"地址拿到但不通"** |

把 `refused` 当成失败会把"通"判成"不通"（首测就犯了这个错，
和同时存在的 `curl code=200` 直接矛盾）。

## 用法

```sh
# 每次都要新的 instance-id
TS=$(date +%s)
sed -i "s/instance-id: .*/instance-id: deb12-hv-$TS/" meta-data
genisoimage -quiet -output seed-v2.iso -volid cidata -joliet -rock user-data meta-data
adb push seed-v2.iso /data/local/tmp/

# host 侧守株待兔
sh seedtest.sh <tag> /data/local/tmp/q-p0a8 <rounds> <timeout> 2 /data/local/tmp/seed-v2.iso
```

`seedtest.sh` 会 `cp` 一份 `deb12-clean.qcow2` 再挂 —— **绝不直接挂基线盘**。

### ⚠ 两个会静默出错的坑

**1. 文件名必须正好是 `user-data` 和 `meta-data`。**
`genisoimage` 用的是**你给的 basename**：

```sh
genisoimage ... user-data-v3 meta-data-v3     # ISO 里就叫 user-data-v3
```

cloud-init 找不到 `user-data` 就当成空 seed 跑，**不报错**，只是整轮
没有 `NETPROBE-BEGIN` —— 现场看起来像"guest 卡住"。正确做法是先拷成
正确名字再打包：

```sh
mkdir -p /tmp/mkseed && cp user-data-v3 /tmp/mkseed/user-data
cp meta-data-v3 /tmp/mkseed/meta-data
(cd /tmp/mkseed && genisoimage -quiet -output /tmp/seed-v3.iso -volid cidata -joliet -rock user-data meta-data)
```

**2. 打完必须把内容抽回来比对。** 不要只信 `genisoimage` 返回 0：

```sh
7z x -o/tmp/isochk -y /tmp/seed-v3.iso user-data meta-data
diff -q /tmp/isochk/user-data user-data-v3 && echo 一致
```

上面第 1 条就是这么抓到的（`diff: /tmp/.../user-data: 没有那个文件`）。

## 清理（把 netprobe 从系统盘移除）

用 `cleanup-user-data`，**必须用 `bootcmd` 不能用 `runcmd`**：
`netprobe.timer` 是 60 秒，`runcmd` 走 final 阶段在 90 秒后 ——
用 `runcmd` 时 cleanup 永远来不及跑（实测 round 涨到 7 都没执行）。

```
CLEANUP-RAN
CLEANUP-PROBE-EXISTS=no
CLEANUP-TIMER=Failed to get unit file state: No such file or directory
reboot: Power down
```

## 基线资产

| 文件 | 说明 |
|---|---|
| `deb12-clean.qcow2` | 无 netprobe 的系统盘，**444** |
| `vars0.img` | 擦除态 varstore（`0xFF`），**444**，md5 `8317cb79...` |
| `seed-v2.iso` | 本轮探针 seed |
| `seed-clean.iso` | 清理 seed |
