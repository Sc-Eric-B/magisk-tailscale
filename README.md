# Magisk-Tailscaled — SmartDNS MagicDNS 增强版

基于 [anasfanani/Magisk-Tailscaled](https://github.com/anasfanani/Magisk-Tailscaled) 的增强维护分支。核心变化：把 Tailscale Android 端的 MagicDNS（`*.ts.net` 域名解析）从"依赖 tailscaled 内置 DNS 代理"改为 **SmartDNS 本地劫持 + 设备表直答**，并配套 watchdog 自愈与 fail-safe 降级。

当前版本：**mdns16.1**（`v2.0.0.1+ts1.98.8+mdns16.1`）

## 特性

- **MagicDNS 直答**：`tailscale status --json` 实时生成设备表，`*.ts.net` 由 SmartDNS 直接返回 100.x，不依赖 100.100.100.100（该地址在 Android 构建上无监听，见迭代史）
- **普通域名转发**：公网域名固定转发 `223.5.5.5 / 119.29.29.29`（`TS_DNS_UPSTREAM` 可覆盖），与 MagicDNS 互不干扰
- **防回环（目的地放行）**：iptables 先对上游 `RETURN` 放行、其余 53 端口全量 `DNAT → 127.0.0.1:15353`；对 SELinux 域差异免疫（fwmark 方案在 boot 域静默失效，已弃）
- **watchdog 自愈**：60s 全链路健康检查（no-cache 探针域名防缓存假阳性）、有界重试、3 连败自动降级系统 DNS 并每 5 分钟静默重试
- **网络切换感知**：IP 变化（WiFi↔蜂窝、DHCP 漂移）自动重启 forwarder
- **fail-safe**：smartdns 起不来、规则装不上时自动收手，绝不挂死全机 DNS
- **P0 探针**：检测"系统 DNS 被放行名单命中"的静默失效（只告警不动作）

## 目录结构

```
Magisk-Tailscaled/
├── module.prop                 # 模块元信息（版本、版本号）
├── customize.sh / service.sh   # Magisk 生命周期脚本
├── tailscale/
│   ├── scripts/
│   │   ├── tailscaled.dns      # 核心：SmartDNS 劫持/直答/watchdog 全部逻辑
│   │   ├── tailscaled.service  # tailscaled 服务脚本
│   │   └── start.sh / tailscaled.inotify
│   ├── settings.sh             # 用户配置（TS_DNS_UPSTREAM 等）
│   ├── bin/                    # smartdns / tailscaled / jq（arm+arm64）
│   └── lib/                    # musl loader（libc.so）等
├── META-INF/                   # Magisk 安装描述
├── docs/                       # 版本审查报告
└── tools/                      # 复发诊断 / 打包校验脚本
```

## 安装

1. 下载模块 zip（见 Releases）
2. Magisk → 模块 → 从本地安装 → 选择 zip
3. 重启（或按模块提示）

升级覆盖安装即可，数据在 `/data/adb/tailscale/`。

## 工作原理

```
App 查询 *.ts.net
   ↓ netd → 路由器/系统 DNS :53
   ↓ iptables OUTPUT nat（目的地放行）
   ├─ 目标 = 223.5.5.5 / 119.29.29.29 → RETURN（smartdns 自己的上游查询）
   └─ 其余 → DNAT → 127.0.0.1:15353（SmartDNS）
        ├─ *.ts.net → 设备表直答 100.x
        └─ 普通域名 → 转发 223.5.5.5/119.29.29.29
```

watchdog 每 60s：健康检查 → 不健康重启（最多 3 次）→ 仍不健康撤规则降级 → 每 5 分钟重试恢复。

## 配置（`tailscale/settings.sh`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `TS_DNS_ENABLE` | 1 | 开启本地 DNS 转发 |
| `TS_DNS_UPSTREAM` | 空 | 自定义上游（空格分隔）；空 = 固定公网 223.5.5.5/119.29.29.29 |
| `TS_SMARTDNS_MARK` | 1073741824 | 已弃用（fwmark 时代遗留，勿改） |

## 迭代历史（简版）

- **mdns1-3**：SmartDNS 接入排障（路径/语法）
- **mdns4**：弃 100.100.100.100 路径（Android 构建无监听 → 全机 DNS 黑洞）
- **mdns5-7**：弃降权路径（SELinux 禁 nobody 域 exec、musl getpwnam_r 无 /etc/passwd）
- **mdns8-9**：fwmark 防回环（atoll 十六进制 bug → 十进制），boot 域静默失效
- **mdns12-13**：watchdog 全链路健康检查 + fail-safe 降级
- **mdns14-15**：弃 fwmark，改目的地放行；修 already-running 分支空名单回环
- **mdns16**：上游固定公网，堵 P0（放行名单=系统 DNS → ts.net 失效）
- **mdns16.1**：status 上游显示修正、P0 探针数据源修正、文档漂移清理、探针判据收紧

## 已知限制

- **IPv6 绕过**：内核无 IPv6 nat 表的设备（小米14/11 实测）蜂窝下 v6 DNS 查询绕过劫持，纯 v6 网络下 MagicDNS 不可用（watchdog 会降级自愈）
- **内网域名（D1）**：劫持规则不区分目标网段，指向路由器等内网 DNS 的查询会被劫持进 SmartDNS → 内网域名（如 `nas.lan`）NXDOMAIN；已论证 uid 放行不可行（Android netd 为 root），待定方案：SmartDNS 降权或 DoT 上游
- **纯 IPv6 网络**：上游仅 v4 公网，无 v4 路由时 watchdog 3 连败降级
- **与其他 53 劫持模块**（AdAway 类）可能互相干扰
- `TS_MAGICDNS_DOMAINS` 为死配置（设备表直答不读它）

## 故障诊断

```sh
su
sh /sdcard/mdns-diag.sh        # 复发诊断（自动对比上次基线）
```

或手动：

```sh
/data/adb/tailscale/scripts/tailscaled.dns status
/data/adb/magisk/busybox nslookup sc-nas.tailc5859.ts.net   # 直答
/data/adb/magisk/busybox nslookup baidu.com 127.0.0.1        # 转发
iptables -t nat -L OUTPUT -n -v | grep 53                    # 劫持计数
```

## 致谢

- [anasfanani/Magisk-Tailscaled](https://github.com/anasfanani/Magisk-Tailscaled) — 上游模块
- [pymumu/smartdns](https://github.com/pymumu/smartdns) — SmartDNS
- Tailscale 官方 Android CLI 构建

## 许可证

见 [LICENSE](LICENSE)（沿用上游）。
