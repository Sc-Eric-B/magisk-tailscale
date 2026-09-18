# 代码审查 — Magisk-Tailscaled mdns16

- 审查日期：2026-09-18
- 基线：`Magisk-Tailscaled-v2.0.0.1-ts1.98.8-mdns16-full.zip`（18,958,222 B，09-18 08:34）
- 源码树：`_mdns12/`（目录名滞后，实际为 mdns16）
- 结论：**mdns16 是针对 P0 的一次实质性修复，方向正确、机理成立。但新加的 P0 检测探针自身有缺陷（漏报），且 `status` 会打印错误的上游，另有若干文档/语义漂移。**

---

## 0. 基线核对（逐字节）

| 项 | 结果 |
|---|---|
| 源码树 ↔ mdns16 zip | **IDENTICAL**（23/23 文件 sha256 全等，无 only-tree / only-zip / content-diff）|
| module.prop | `version=v2.0.0.1+ts1.98.8+mdns16`，`versionCode=02000016` |
| mdns16 vs mdns15 | 仅 `module.prop` + `tailscale/scripts/tailscaled.dns` 变（562 → 589 行）|
| 其余 21 个文件 | 与 mdns15 完全一致 |

> 目录名 `_mdns12` 一直没改。**以 `module.prop` 的 versionCode 为准。**

---

## 1. mdns16 改了什么

### 1.1 `upstream_list()`（:107-120）
不再调用 `detect_upstream()`。默认固定返回 `223.5.5.5 119.29.29.29`，仅在 `TS_DNS_UPSTREAM` 显式配置时使用配置值。

### 1.2 `gen_conf()`（:135-167）
- 非 CFG 分支：上游写死为 `server 223.5.5.5` / `server 119.29.29.29`，`UPSTREAM_ALL_V4=" 223.5.5.5 119.29.29.29"`。
- 新增 P0-window 警告：遍历 `detect_upstream`，若某个系统 DNS 出现在放行名单里，记 `system DNS x is allow-listed (P0 window)`。
- fallback 警告条件收紧为 `[ -n "$UPSTREAM_CFG" ]`（默认分支已不可能为空，逻辑正确）。

### 1.3 `health_check()`（:293-317）
新增真路径探针（P2-a）：
```sh
sysdns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
probe=$(awk '/^domain-rules \/.* -address /{print $2; exit}' "$SMARTDNS_CONF" | sed 's|^/||; s|/$||')
[ -n "$sysdns" ] && [ -n "$probe" ] && \
  timeout 5 "$bb" nslookup "$probe" "$sysdns" | grep -q "100\." || \
  log Error "P0 HIT: ..."
```
**仅记日志，不改状态**（注释说明：重启治不了名单冲突、降级只会让 ts.net 更糟）——这个取舍是对的。

---

## 2. 判定：P0 是否解决

**机理**：劫持规则 = 先给每个上游加 `-d <上游> --dport 53 -j RETURN`，再无条件 `--dport 53 -j DNAT → 127.0.0.1:15353`。
- 改动前：上游 = `detect_upstream()` = 系统 DNS = **netd 查询的目的地** → RETURN 把主解析路径放行掉 → 普通 app 不被劫持 → MagicDNS 静默失效。
- 改动后：放行名单 = `{223.5.5.5, 119.29.29.29}`，**不再包含 netd 的目的地** → netd 的 53 查询命中无条件 DNAT → 被劫持。

### 结论
✅ **P0 在"网络下发的 DNS 不是 223.5.5.5 / 119.29.29.29"时关闭。** 这是从 mdns14 起最实质的一次修复。

⚠️ **残留窗口**：若网络下发的系统 DNS 恰为 `223.5.5.5`（AliDNS）或 `119.29.29.29`（DNSPod）——这两个在国内被不少 ISP / 路由器 / ROM 直接下发，**并非空想** —— RETURN 仍会放行 → P0 复现。mdns16 只**检测**（`gen_conf` 警告 + `health_check` 的 P0 HIT 日志），不修复。

### 把 P0 从根上关死（已确认可行）
改用**非 53 端口上游**：DoT（853）或 DoH（443）。
因为劫持规则只匹配 `--dport 53`，smartdns 走 853/443 时**永远不会命中自己的 DNAT**，于是 allow-list 可整个删掉（无条件 DNAT 全部 53），P0 window 从根上消失。

**可行性证据（本次新查）**：本模块自带的 smartdns 二进制（arm 与 arm64）均含
`server-tls` / `server-https` / `server-h3` / `-host-name` / `-tls-host-verify` / `-no-check-certificate`
以及符号 `_dns_client_socket_ssl_send`、`_config_bind_ip_tls`、`tls_construct_ctos_server_name` 等 → **TLS 客户端能力已编译进二进制**。
上游示例：`server-tls 223.5.5.5 -host-name dns.alidns.com`（AliDNS 支持 DoT/853）。

> ⚠️ 证书链风险：musl libc 默认读 `/etc/ssl/certs`（Android 上常缺失）。落地时建议配 `-no-check-certificate`，或指定可用 CA 文件 —— **需真机验证**。

---

## 3. 新发现

### B1（功能 Bug）`status()` 打印假上游 — `tailscaled.dns:448`
```sh
log Info "Upstream: $(detect_upstream | sed 's/^ //')"   # ← 打印的是系统 DNS
```
实际上游是 `upstream_list()`（固定公共 DNS）。用户跑 `tailscaled.dns status` 看到的 "Upstream:" 与真正在用的不是一回事，排障时会被带偏。
**改法**：`log Info "Upstream: $(upstream_list)"`（一行）。

### B2（P0 检测自身缺陷）新探针读 `/etc/resolv.conf`，与本项目对"系统 DNS"的定义不一致
项目全程用 `getprop net.dns*`（`detect_upstream`）来认定系统 DNS，而新探针读 `/etc/resolv.conf`。Android 上该文件通常是**空**或 **`nameserver 127.0.0.1`**：
- **空** → `sysdns` 为空 → `if` 条件不成立 → 探针整体跳过 → **零检测**（静默，最坏）；
- **`127.0.0.1`** → 查询被 DNAT 到 smartdns → 返回 `100.x` → `grep` 命中 → **假"健康"**（漏报 P0）。

两种失效模式都让这个"本应抓住 P0"的防线形同虚设。
**改法**：
```sh
sysdns=$(detect_upstream | awk '{print $1}')
```
（即用项目自己的定义；必要时再补一条对 `/etc/resolv.conf` 的探查做交叉验证。）

### B3（文档 / 语义漂移，5 处）
| 位置 | 现状 | 应为 |
|---|---|---|
| `settings.sh:30` | `# e.g. "223.5.5.5 119.29.29.29"; empty = auto-detect` | `empty = 固定公共 DNS 223.5.5.5/119.29.29.29` |
| `settings.sh:25` | `forwarded to the device's current DNS (or TS_DNS_UPSTREAM if set)` | 同上 |
| `tailscaled.dns:33-35` | `forwarded to the device's current DNS servers (auto-detected via getprop ... falls back to 223.5.5.5/...)` | 与实现完全相反，需重写 |
| `tailscaled.dns:19` | `So mdns14 rules are:` | 版本号未跟上 |
| `tailscaled.dns:54` | `if the detected upstreams changed, regenerate config + restart;` | 上游已固定，默认配置下恒不触发（仅 TS_DNS_UPSTREAM 下有意义）|
| `tailscaled.dns:47-52` | watchdog 说明只提 `nslookup www.baidu.com 127.0.0.1` | 未提新增的真路径探针 |

> `settings.sh` 在升级时会被覆盖（旧账），所以这里改注释同样会影响用户配置 —— 顺带提醒。

### B4（行为回归风险）硬编码 IPv4-only 上游 → 纯 IPv6 网络无可用上游
`detect_upstream` 原本可能返回 IPv6 系统 DNS（mdns15 还专门加了 `%zone` 剥除），现在默认只有两个 IPv4 上游。
若手机处于**纯 IPv6 网络**（无 v4 出口、无 464XLAT），smartdns 全部上游不可达 → `health_check` 失败 → watchdog 3 次后**降级、删规则、把 DNS 还给系统**。
**会自愈（安全兜底有效），但该网络下 MagicDNS 关闭。** 需确认是否可接受。
若想覆盖：当 `detect_upstream` 含 IPv6 且不含 v4 时，把该 v6 也加入上游。

### B5（小）探针 `grep -q "100\."`
- 若 tailnet 节点是 IPv6（`fd7a:...`，`gen_magic_addresses` 有 `// .TailscaleIPs[0]` 兜底）→ 永远不匹配 `100.` → **假 P0 告警**。
- P0 命中时每 60s 记一次 `Error`，日志会刷（可接受，但知悉）。

### B6（延续）上游变化触发失效
`:564` 的 `upstream changed` 分支在默认配置下恒不触发（上游固定）→ 网络切换不再触发重启。
**但** `IP 变化`（`:0.5` 分支）仍在生效 → mdns13 那个"DCHP 漂移导致 connect() 源地址失效"的根治逻辑**没有丢**。可接受。

---

## 4. 遗留账逐条复核

| 账目 | mdns16 状态 |
|---|---|
| **P0** 上游=系统 DNS → 放行主解析路径 | ✅ 已关闭（常见情形）；⚠️ 残留"网络下发 223.5.5.5/119.29.29.29"窗口，仅检测不修复 |
| **P2-a** 只探 127.0.0.1、不验劫持是否生效 | ⚠️ 已加探针，但探针本身有 **B2** 缺陷 → 仍可能漏报 |
| P1-2 装载顺序 / 升级覆盖 settings.sh | 未动 |
| 探测域名两处硬编码 / `bind [::1]` 无条件写 / `set -e` 全链路 | 未动 |
| **B1 / B2 / B3** 本轮新发现 | 见上 |

---

## 5. 装机验证清单

1. `adb shell su -c 'tailscaled.dns status'`
   → 确认 "Upstream:" 显示的是 **223.5.5.5 119.29.29.29**（当前会显示错的，见 B1）。
2. `su -c 'iptables -t nat -S OUTPUT | grep magicdns'`
   → 应有 2 条 `-d 223.5.5.5 ... -j RETURN`、2 条 `-d 119.29.29.29 ... -j RETURN`、以及 2 条无条件 `DNAT --to-destination 127.0.0.1:15353`（udp/tcp）。
3. `cat /etc/resolv.conf`
   → 看是不是空 / `127.0.0.1`（验证 B2 风险是否真实存在）。
4. `su -c 'nslookup <你的节点>.ts.net $(getprop net.dns1)'`
   → 在系统 DNS 未被放行的网络下应返回 `100.x`；返回 NXDOMAIN 即 P0 窗口命中。
5. `su -c 'grep -i "P0 HIT" /data/adb/tailscale/run/runs.log | tail'`
   → 确认探针是否误报 / 漏报。
6. 切一次 WiFi ↔ 流量，观察 `runs.log`
   → 应**不再**出现 `upstream changed`；**应**出现 `IP changed`。

---

## 6. 建议优先级

| 级别 | 项 | 工作量 |
|---|---|---|
| **P1** | B1 `status()` 改 `upstream_list` | 1 行 |
| **P1** | B2 探针改用 `detect_upstream`（让 P0 防线真正生效）| 1 行 |
| P2 | B3 文档同步（`settings.sh` + 文件头）| 5 处注释 |
| P2 | 决策 B4（纯 IPv6 网络）| 设计取舍 |
| P3 | 若要根除 P0 → DoT/DoH(853/443) 上游，删 allow-list | 中等，需真机验证书 |

---

## 附：本次审查所用方法

- 源码树 ↔ 发行 zip 逐字节（sha256）比对
- 版本间 unified diff（`difflib`）
- 全树 grep 引用面（`detect_upstream` / `upstream_list` / `TS_DNS_UPSTREAM` / 固定 DNS IP / `resolv.conf`）
- 二进制特征取证（smartdns arm/arm64 的 TLS 能力字符串与符号）
- 脚本：`check15.py` 同类流程，均在绝对路径直调 Python（本工作区 Bash/PowerShell 环境异常）
