# dnsdiag seed：把「DNS 坏了」拆到具体一层

## 为什么单独一个 seed

`seed/user-data`（netprobe）用一个 `DNS-RESOLVE result=fail|ok` 说"DNS 坏了"。
这句话对判读没用 —— 坏了有四种完全不同的坏法，修法各不相同：

| 坏在哪 | 现象 | 修法 |
|---|---|---|
| 下发错 | guest 拿到的 nameserver 根本不对 | 改 DHCP/cloud-init |
| 转发断 | 拿到的地址打了没人应 | 网络后端 |
| 中间层 | 地址能通，但 resolved/nsswitch 不往上递 | 改 guest 配置 |
| 整体不通 | 连公网 DNS 都打不通 | UDP/NAT 层 |

而且 **DNS 主用 UDP**，UDP 没有 RST、没有握手，`timeout` 的含义与 TCP 的
`timeout` 不是一回事（见 `work/probe/STATES.md` 第七节）。

## 结构：一次 boot，两个 phase

```yaml
runcmd:
  - [ /usr/local/bin/dnsdiag ]              # pre   裸状态
  - [ /usr/local/bin/dnsdiag, --fix ]       # post  换 link DNS 后重测
```

`--fix` = `resolvectl dns <if> 223.5.5.5` + `flush-caches`。

**为什么同一次 boot 做 A/B**：两个 phase 共享同一次 DHCP、同一份内核、
同一个 resolved 状态，唯一变量就是 DNS 指向。跨 boot 比较会混进启动抖动。

## 六路打点

| kind | 手段 | 回答什么 |
|---|---|---|
| `udp` | 未 connect 的 `sendto` | 应用最常见写法看到什么 |
| `udpc` | `connect()` 过的 UDP | ICMP 错误会不会浮出来 |
| `udperr` | `+IP_RECVERR` + `MSG_ERRQUEUE` | **内核到底收没收到 ICMP** |
| `tcp53` | TCP 连 53 | 与 UDP 的差异 |
| `tcp80` | TCP 连同地址 80 | 「地址不可达」还是「只有 53 被拦」 |
| `ctrl` | 直连 `223.5.5.5` | 对照：UDP53 整体通不通 |

`udperr` 不能省。前两路只能说"应用没拿到"，而"没拿到"至少有两种：
包被丢了，包被回了但应用看不见。**修法完全不同。**

## 判据

```
DNSDIAG-pre-BEGIN ...      runcmd 跑到了
DNSDIAG-pre-END            这一 phase 跑完了
DNSDIAG-<ph>-VERDICT ...   脚本自己拼的结论（省得读的人拼错）
DNSDIAG-post-END           全部结束（缺它 = 半途死，不是通过）
```

## 用法

```sh
# 宿主：打包 + 逐字节校验 + 推送（instance-id 自动唯一）
./mkseed.sh

# 设备：跑一次
NET=slirp sh /data/local/tmp/dnsdiag.sh slirp1 /data/local/tmp/q-p0a8 400 2

# 反事实实验：把虚拟 DNS 地址本身改掉
USER_OPTS=,dns=223.5.5.5 NET=slirp sh /data/local/tmp/dnsdiag.sh dnsopt /data/local/tmp/q-p0a8 400 2
```

`mkseed.sh` 会把 ISO 里的 `user-data` / `meta-data` 抽回来**逐字节 diff**。
上一版用 grep 固定串，改版把那个串换掉之后它立刻误报 —— 判据自己会过期。

## 实测结论

见 `QEMU-BACKEND.md` 13.54。一句话：
**slirp 下 `10.0.2.3` 整个地址不可路由**（Android 无 `/etc/resolv.conf` →
`get_dns_addr()` 恒 -1 → `EPERM`），不是"DNS 转发慢/不稳"。
`-netdev user,dns=X` 是坑，不是修法。
