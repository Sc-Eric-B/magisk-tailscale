# 代码审查 — Magisk-Tailscaled mdns16.1

- 审查日期：2026-09-18
- 基线：`Magisk-Tailscaled-v2.0.0.1-ts1.98.8-mdns16.1-full.zip`（18,958,519 B，09-18 08:53）
- 源码树：`_mdns12/`（目录名照旧滞后，实际已是 mdns16.1）
- 一句话结论：**mdns16.1 把我上轮提的 4 条全部修掉了，修得对。但 mdns16 引入的 P0 修复带来一个此前没人注意到的回归 —— 局域网/内网域名解析失效，这才是现在最该看的一条。**
- **v2 修订（09-18，sceric 指正后）**：本报告原先建议的 uid-0 修法**已作废**（Android 上 netd 同为 uid 0，分不开）；正解改为 **smartdns 降权 9999**。另新发现 `detect_upstream` 在现代 Android 恒空、导致探针空转。见 §2。
- **v3 修订（09-18 晚，真机实测回填）**：§7 记录实测结果 —— **netd = uid 0 已实测证实**；`/etc/passwd` **确无 `nobody`**（且是 ROM 极简版，仅 5 条、连 root 都没有）；`detect_upstream` 恒空已实锤且**找到真实来源 `dumpsys dnsresolver`**；**`ndc` 在该 ROM 上已不存在、`/etc/resolv.conf` 不存在**；另发现**该机唯一健康的系统 DNS 是 IPv6，而 v6 劫持在本内核不可用**。**两台设备当前均正常，不改代码。**

---

## 0. 基线核对（逐字节）

| 项 | 结果 |
|---|---|
| 源码树 ↔ mdns16.1 zip | **IDENTICAL**（23/23 文件 sha256 全等）|
| `module.prop` | `version=v2.0.0.1+ts1.98.8+mdns16.1`，`versionCode=02000161` |
| mdns16.1 vs mdns16 | 仅 3 个文件变：`module.prop`、`tailscale/settings.sh`、`tailscale/scripts/tailscaled.dns`（589 → 603 行）|

> 小提示：`_mdns12` 这个**父目录**的 mtime 停在 08:20，但里面 `tailscale/scripts/` 下的文件是新的 —— 改子目录里的文件不会更新父目录 mtime。别被它骗，要按内容比对。

---

## 1. ✅ 上轮提的 4 条，全部修掉（逐条验证）

### B1 — `status()` 打印假上游 → 已修
```diff
- log Info "Upstream: $(detect_upstream | sed 's/^ //')"
+ log Info "Upstream: $(upstream_list | sed 's/^ //')"
```
（`:462`）正确。`upstream_list` 输出无前导空格，`sed` 无害。

### B2 — P0 探针读错文件 → 已修
```diff
- sysdns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
+ sysdns=$(detect_upstream | awk '{print $1}')
```
（`:320`）正确。`detect_upstream` 输出形如 `" 192.168.1.1 8.8.8.8"`（带前导空格），`awk` 取第一个字段即首个系统 DNS，正是项目自己的定义。
**额外确认**：若系统 DNS 本身就是 `127.0.0.1`，探针走回环 → DNAT → smartdns → 有应答 → 不报警 —— 而这时 netd 确实被劫持了，所以"不报警"**语义上是对的**。这版比上一版严谨。

### B3 — 文档漂移 → 已修 4/5
- `settings.sh` 的 MagicDNS 说明段：重写为"*.ts.net 直答 / 其余转发固定公共 DNS" ✓
- `settings.sh:30` 注释：`empty = auto-detect` → `empty = fixed public DNS` ✓
- `tailscaled.dns:33-38` 文件头：重写，并写明"系统 DNS 刻意不做上游（mdns16）…只用于告警" ✓
- `:54` `if the detected upstreams changed` → `if the explicit upstream config changed` ✓
- `:47-52` watchdog 说明：补上了真路径探针 ✓
- ❌ **漏了一处**：`:19` 仍写 `So mdns14 rules are:` —— 见 C1

### B5 — 探针 `grep` 假告警 → 已修
```diff
- if ! timeout 5 "$bb" nslookup "$probe" "$sysdns" 2>/dev/null | grep -q "100\."; then
+ if ! timeout 5 "$bb" nslookup "$probe" "$sysdns" 2>/dev/null | grep -q "Name:"; then
```
（`:326`）**判定成立，我查证过**：busybox `nslookup` 在**有应答**时打印 `Name: <name>` + `Address 1: …`（1.28 与 1.31 两种格式都含 `Name:`）；NXDOMAIN 时只打印 `** server can't find <name>: NXDOMAIN`，**没有 `Name:` 行**。且 `Name:` 对 v4(`100.x`) 和 v6(`fd7a:`) 应答都命中 → v6-only 节点不再假报警。✅

### ⬜ B4 — 纯 IPv6 网络无上游 → 未动
上游仍是两个 IPv4 公共 DNS，没有"检测到 v6 系统 DNS 时补一个 v6 上游"的逻辑。纯 IPv6 网络下 smartdns 无可用上游 → watchdog 3 次后降级、还 DNS 给系统（自愈，但该网络 MagicDNS 关闭）。**仍是设计取舍，待你决策。**

---

## 2. 🔴 D1（新发现，优先级最高）— mdns16 引入的回归：内网域名解析失效

### 现象
在**家庭/公司局域网**里，解析内网名字（`nas.lan`、`router.home`、公司内网域名、路由器管理页域名…）会失败。

### 根因（已逐行核实）
`:221-224` 的劫持规则是**无条件的**，只按 `--dport 53` 匹配：

```sh
iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:15353
iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:15353
```

放行名单只有 `223.5.5.5 119.29.29.29`（`:162`）。全脚本核实：**没有** `-m owner`、没有私网段排除（`10./172.16/192.168/100.64` 各 0 命中），`! -o tun+` 只出现在**删除** tailscaled 死规则的命令里，不在自己的劫持规则上。

于是：
```
app 查 nas.lan  →  netd 发给路由器 192.168.1.1:53
               →  192.168.1.1 不在放行名单  →  命中 DNAT  →  转到 smartdns
               →  smartdns 只配了 ts.net 直答 + 上游 223.5.5.5/119.29.29.29
               →  AliDNS 不认识 nas.lan  →  NXDOMAIN  →  解析失败 ✗
```

### 为什么说这是 mdns16 引入的回归
mdns12/13/14/15 的上游都是 `detect_upstream()` = 系统 DNS = **路由器本身**。放行名单里就有路由器 → 内网查询走 RETURN 直接问路由器 → 内网名**能解析**。
mdns16 为了让放行名单不再吞掉 netd 的主路径（P0），把上游换成固定公共 DNS → 路由器被踢出放行名单 → **内网名从此解析不了**。

> 换来了 ts.net，赔上了内网。这是个真实的权衡，不是笔误。

### 根因的本质
"放行系统 DNS"和"劫持系统 DNS"在**同一条目的地规则**里天然互斥：路由器既**必须**被问到（内网名只有它认识），又**不能**被问到（它不认识 ts.net，问它就是 P0）。

### ❌ 本报告原提的修法已作废（sceric 指正，成立）

原方案 `-m owner --uid-owner 0 -j RETURN` **在 Android 上不成立**：

> **netd 本身就是 uid 0。**
> app 的 DNS 走 dnsproxyd → netd，报文由 **netd 进程**发出，uid = 0。所以这条 RETURN 会把 netd 的查询一起放行 → ts.net 不再被劫持 → **P0 以另一种形态回归**。
> iptables 无法区分 smartdns 和 netd —— 二者同为 uid 0。

**根因**：放行判据必须是"只有 smartdns"，而 smartdns 与 netd **同为 root**，按 uid 天然分不开。所以"让 forwarder 自己走原路"这个思路，在"forwarder 和 netd 同 uid"的前提下不可能成立。

### ✅ 唯一能同时解决 P0 + D1 的路：smartdns 降权到 9999

让 smartdns 换一个**独有的 uid**，然后用"非该 uid 即劫持"：

```sh
# smartdns 以 9999 运行；只有它的查询被排除，其余（netd/app/其它）全部劫持
iptables -t nat -A OUTPUT -p udp --dport 53 -m owner ! --uid-owner 9999 -j DNAT --to-destination 127.0.0.1:15353
iptables -t nat -A OUTPUT -p tcp --dport 53 -m owner ! --uid-owner 9999 -j DNAT --to-destination 127.0.0.1:15353
```
上游改回系统 DNS（路由器）：
- smartdns（9999）→ 不被劫持 → 用路由器当上游 → **内网名 ✓**；ts.net 由自己直答，压根不问路由器 ✓
- netd / app（任何 ≠9999）→ 被劫持 → ts.net ✓、其余转路由器 → 内网名 ✓
- **P0 根治**：`UPSTREAM_ALL_V4/V6`、allow-list、P0-window 告警、空名单拒装 —— 这一整套机制可以**全部删掉**，脚本反而变简单。

#### 产物侧已核实（本次新查）
| 事实 | 证据 |
|---|---|
| 降权代码路径**已编译进二进制** | `smartdns-arm64` 含 `setuid`×2、`setgid`×2、`getpwnam_r`×2、`capset`×2、`capget`×2、`setrlimit`×2；短标识符含 `user` / `uid` / `onlyuser` |
| `getpwnam_r` 确实读 `/etc/passwd`（claim a 机理成立）| musl `libc.so` 含 `/etc/passwd`×1、`/etc/group`×1、`setgroups`、`initgroups`、`setresuid` |
| 用户名不写死，来自配置 | 两个二进制里都**没有** `nobody` 字符串 |
| 这条路**从未实现过** | 全源码树除脚本头注释（`tailscaled.dns:8-10`）外，**无** passwd/setuid/overlay 任何代码 |

> `customize.sh` 目前只用 `set_perm_recursive` 设了 bin/lib/scripts/system/bin/service.sh 的权限，**没有** 任何 `/system/etc/passwd` overlay。

#### ❌ 实测已否定："先验一步可能省掉 overlay"（本报告 v2 的乐观推测）
真机 `/etc/passwd` 全文只有 **5 条**，**没有 `nobody`**，**连 `root` 都没有**：
```
system_backup::6100:6100::/:/bin/sh
system_theme::6101:6101::/:/bin/sh
system_updater::6102:6102::/:/bin/sh
system_finddevice::6110:6110::/:/bin/sh
system_cameramind::6120:6120::/:/bin/sh
```
→ 这不是 AOSP 标准那份，是 **ROM 自定义的极简版**。所以：
1. **overlay 是必需的**（改动量回到"大"）；
2. overlay 时必须**保留这 5 条**，只追加 `nobody:x:9999:9999:...` —— 别整份替换，否则可能影响 ROM 自身逻辑。

#### ✅ 原提案第一步（仍建议先跑）
```sh
cat /etc/passwd | grep -i nobody
```
（本机结果：无。但换 ROM 仍有必要先看，因为覆盖前必须知道原文件长什么样。）

#### ⚠️ 强制要求：fail-closed 校验（否则会重演 mdns12/13 的全断事故）
降权若**静默失败**（SELinux 拦 setuid，或 `getpwnam_r` 拿不到 nobody），smartdns 仍是 uid 0 —— 而规则是 `! --uid-owner 9999 -j DNAT` → **它的上游查询会被 DNAT 回自己 → 无限自劫持 → 全设备 DNS 死**。
这正是 mdns12/13 踩过的坑，只是换了触发方式。所以 `start()` **必须**：
1. 启动后读 `/proc/<pid>/status` 的 `Uid:` 行，确认**首个字段 == 9999**；
2. 不满足就**拒绝安装 DNAT**（照抄 mdns15 那条"空 allow-list 拒装 DNAT"的守卫思路），并回退到当前"目的地放行 + 固定公网 DNS"方案；
3. 确认降权后 smartdns 仍能读 conf、写 log（目录 chown 9999，或日志放到 9999 可写处）。

（15353 > 1024，非 root 绑定无问题。）

#### 改动清单（供单独一轮验证）
1. conf 加 `user nobody`（或 `user 9999`）
2. `run/`、日志、conf 的属主 chown 到 9999
3. 可选：`$MODPATH/system/etc/passwd` overlay（**仅**在真机确认缺 nobody 时才需要）
4. `ipt_add_rules` 整段重写为两条 `-m owner ! --uid-owner 9999 -j DNAT`
5. 删掉 allow-list 相关全部逻辑
6. `start()` 加 `/proc` Uid 校验 + 不通过则回退
7. 保留旧方案作为 fallback 代码路径

#### 备选（零改动，接受取舍）
tailnet 设备都有 ts.net 域名 → 内网服务改用 ts.net 名或 IP 直连；P2-a 探针已把 P0 显式化。
**代价**：内网里**非 tailnet** 的设备/服务（打印机、路由器管理页、NAS 的其他入口）在手机上仍然打不开。

### ⚠️ 附带发现：`detect_upstream` 在现代 Android 可能恒空 → 探针其实是空转

sceric 实测：**小米 14 上 `detect_upstream` 恒空**。这大概**不是 ROM 怪癖** —— `net.dns1` / `dhcp.*.dns*` 这些 property 在 **Android 10+ 基本已废弃**（DNS 配置移进 netd 按网络管理），"读 getprop 拿系统 DNS"这个前提本身就老了。

**连锁后果**（在 detect_upstream 恒空的设备上）：
- `gen_conf` 的 **P0-window 告警永不触发**；
- **B2 修好的真路径探针 `sysdns` 为空 → 整个探针被跳过 → P0 完全没有可见性** —— 等于我上轮要求的防线在这台机上不生效；
- mdns12–15 的 allow-list 也是公网 → **内网域名一直是挂的**（与实测一致，**不是 mdns16 引入的回归**）。

**设备差异（sceric 核实）**
| 设备 | detect_upstream | 内网域名 |
|---|---|---|
| 小米 14 | 恒空 | mdns12–15 起就一直挂 → **既有缺陷** |
| 小米 11（WiFi，能读到路由器）| 正常 | mdns15 时正常 → mdns16 固定公网 → **真回归** |

**真机确认结果（实测，非推断）**

| 取法 | 结果 |
|---|---|
| `getprop net.dns1/2`、`dhcp.*.dns*` | **全空** |
| `cat /etc/resolv.conf` | **文件不存在**（`No such file or directory`）|
| `ndc resolver getresolvers` | **`500 0 Command not recognized`** —— 该 ROM 上 `ndc` 已不存在 |
| **`dumpsys dnsresolver`** | ✅ **可用，是唯一真实来源**，明确列出 `DNS servers:` |

→ 结论：
1. **`detect_upstream` 在这台机上必然返回空**，实锤。
2. `gen_conf` 的 **P0-window 告警永不触发**；B2 的真路径探针 `sysdns` 为空 → **整段被跳过**。实测 `grep -i "P0 HIT" runs.log` **为空 —— 但这只证明"探针没跑"，不证明"没有 P0"**，别误读。
3. 要让告警/探针真正生效，**唯一可用取法是 `dumpsys dnsresolver` 解析**（`ndc` 已死、`resolv.conf` 不存在、property 全空）。

**⚠️ 但有个反直觉的发现：就算取到了，也不该拿它当上游。** 实测 `dumpsys dnsresolver` 显示该机蜂窝网络（NetId 103 / rmnet_data3）的 4 个 DNS 里：
```
120.196.165.7  (v4)  BROKEN   SERVFAIL 21/23
221.179.38.7   (v4)  BROKEN   SERVFAIL 23/23
2409:8057:2000::8    (v6)  正常   score 99.7
2409:8057:2000:4::8  (v6)  <no data>
```
**两个 v4 系统 DNS 全是坏的，唯一健康的是 v6。** 所以 mdns16 "固定公共 DNS 当上游"这个决定，在这台设备/网络下**反而是更稳的选择** —— 换成系统 DNS 会直接拿两个 SERVFAIL 的服务器当上游。

---

## 3. 其他发现

### C1（文档，1 处漏网）
`tailscaled.dns:19` 仍写 `So mdns14 rules are:` —— 上一轮 5 处漂移里唯一没改的。改成 `mdns16 rules` 或干脆去掉版本号即可。

### C2（死配置）`TS_MAGICDNS_DOMAINS` 完全没被使用
全树核实：
- `settings.sh:30` `export TS_MAGICDNS_DOMAINS="${TS_MAGICDNS_DOMAINS:-ts.net}"   # space-separated suffixes`
- `tailscaled.dns:71` `DOMAINS="${TS_MAGICDNS_DOMAINS:-ts.net}"`
- **`DOMAINS` 之后再无任何引用**（0 命中）。

含义上它承诺"配置 MagicDNS 域名后缀（空格分隔）"，但 mdns16 的实现只从 `tailscale status --json` 的 `DNSName` 生成规则，用户改这个变量**毫无效果**。15/16 就有，不是 16.1 引入，但 16.1 刚把周边文档清理干净后，它是唯一剩下的"写着能配、其实没用"的旋钮。
**二选一**：删掉它，或真的用它过滤 `gen_magic_addresses` 的输出。

> 对照：`TS_MAGICDNS_SERVER` **是**在用的（`MAGIC_SERVER`，用于清 tailscaled 的死规则），别一起当死配置删了。

### C3（版本号编码不单调，会影响后续升级判定）
| 版本 | versionCode |
|---|---|
| mdns15 | `02000015` |
| mdns16 | `02000016` |
| mdns16.1 | `02000161` |

`16.1` 写成 `0161` 用的是"去掉小数点补零"，而 `16` 写成 `0016` 用的是"直接补零"——两套规则。数值上 `2000016 < 2000161` 暂时还单调，**但下一版 mdns17 若沿用 `02000017`（=2000017），就会小于 2000161**，Magisk 的"是否有新版"判定会认为没升级，`customize.sh` 按 versionCode 命名的备份目录也会错乱。
**建议**：统一成 `0200` + `major*100 + minor`（16→0160、16.1→0161、17→0170），或干脆一直待在 `020001xx` 段。

### C4（可选收紧）`grep -q "Name:"` 比 `grep -q "100\."` 宽松
`Name:` 的判据是"有应答就算被劫持"。如果**运营商 DNS 做了 NXDOMAIN 劫持**（老式国内 ISP 把不存在的域名解析到广告页），那它也会返回 A 记录 → 出现 `Name:` → **漏报 P0**。
**更严的做法**：探针只需要看**同一条 conf 行**里已经写好的期望地址 ——
```sh
probe=$(awk '/^domain-rules \/.* -address /{print $2; exit}' "$SMARTDNS_CONF" | sed 's|^/||; s|/$||')
want=$(awk  '/^domain-rules \/.* -address /{print $4; exit}' "$SMARTDNS_CONF")
... | grep -q "$want"     # 直接比对 100.x / fd7a: 的实际值
```
既杜绝 v6 假告警，也杜绝劫持假阴性。属于锦上添花。
（另：老版 busybox 1.29/1.29.1 的 `nslookup` 有已知解析 bug；不过本模块的 baidu 探针一直依赖 busybox nslookup，能跑通就说明设备上这版没问题，风险低。）

---

## 4. 仍未处理的旧账（历版累积）

| 项 | 说明 |
|---|---|
| **劫持范围** | 见 D1 —— 现在是最高优先 |
| 升级覆盖 `settings.sh` | `customize.sh` 备份白名单不含它；且 `rm -rf backups/<versionCode>` 会删同版本备份 |
| postinstall 顺序 | 先 `rm -rf run/`（丢 pid）再 start，没先 stop |
| `bind [::1]` 无条件写 | 内核禁 IPv6 时 smartdns 起不来且永不恢复 |
| 探测域名硬编码 | `www.baidu.com` 出现在两处 |
| `set -e` 全链路 | settings.sh 开着 `set -e`，中途一条命令失败会整体退出 |
| B4 | 纯 IPv6 网络无上游 |

---

## 5. 装机验证清单

1. `su -c 'tailscaled.dns status'`
   → `Upstream:` 应显示 **223.5.5.5 119.29.29.29**（B1 已修，现在会显示对了）。
2. `su -c 'iptables -t nat -S OUTPUT | grep magicdns'`
   → 应有 2 条 `-d 223.5.5.5/119.29.29.29 … -j RETURN` + 2 条无条件 `DNAT`（udp/tcp）。
3. **`su -c 'nslookup nas.lan $(getprop net.dns1)'`（或任何内网名）**
   → **验 D1**：返回 NXDOMAIN 即内网名确实被劫持失效。
   ⚠️ 若 `getprop net.dns1` 为空（小米 14 就是），改用第一条命令取真实系统 DNS 再试。
4. **`su -c 'grep -i nobody /etc/passwd; ls -l /etc/passwd'`**
   → **验 9999 路线第一步**：若已有 `nobody:x:9999:9999`，则 passwd overlay 可省。
5. **`su -c 'getprop | grep -i dns; ndc resolver getresolvers'`**
   → **验 detect_upstream 为何恒空**，确认现代 Android 的真实系统 DNS 来源。
6. **netd uid 对照（10 秒，验"uid 分不开"这个结论）**：
   ```sh
   su -c 'iptables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner 0 -j RETURN'
   su -c '/data/adb/magisk/busybox nslookup <你的节点>.ts.net'      # NXDOMAIN → netd 就是 root，uid-0 方案死路
   su -c 'iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner 0 -j RETURN'   # 清理
   ```
7. `su -c 'nslookup <你的节点>.ts.net $(getprop net.dns1)'`
   → 应返回 `100.x`（P0 已关）。
8. `su -c 'grep -i "P0 HIT" /data/adb/tailscale/run/runs.log | tail'`
   → 确认探针有没有误报 / 漏报。
9. 切一次 WiFi ↔ 流量，看 `runs.log`：应**不再**出现 `upstream changed`，**应**出现 `IP changed`。

---

## 6. 优先级

| 级别 | 项 | 说明 |
|---|---|---|
| ~~P0~~→**观察** | **D1** 内网域名解析失效 | **实测两台设备均正常，本轮不改。** mdns16 在"能读到路由器"的网络下是回归；小米 14 属既有缺陷。若日后要根治：smartdns 降权 9999（uid-0 方案已作废）。**备选（零改动）**：内网服务走 ts.net/IP |
| **观察** | v6 路径绕过 smartdns（§7.3①） | 该机唯一健康的系统 DNS 是 v6，而 v6 劫持不可用 → ts.net 靠"抢答"胜出。**"ts.net 时好时坏"的第一嫌疑** |
| **P1** | `detect_upstream` 恒空（已实锤）| 使告警 + 探针双双空转；真实来源是 `dumpsys dnsresolver`。**但实测表明系统 DNS 本身不可用，故修它的收益有限** |
| P2 | C3 versionCode 编码 | 下一版就会踩 |
| P2 | C2 死配置 `TS_MAGICDNS_DOMAINS` | 删或真正实现 |
| P3 | C1 `:19` 版本标签 | 一行 |
| P3 | C4 探针判据收紧 | 可选 |
| — | B4 纯 IPv6 | 待决策 |
| — | 旧账（升级覆盖 / 顺序 / `bind [::1]` / `set -e`） | 历版累积 |

---

## 7. 真机实测记录（2026-09-18，`verify-mdns16.1.sh`）

被测机：`M2102K1AC (mars)`，Android 17 / SDK 37。**两台设备（小米 14、小米 11 Pro）当前 MagicDNS 均正常工作 —— 因此本轮不改代码。**

### 7.1 已证实的事实

| # | 项 | 实测结果 | 影响 |
|---|---|---|---|
| 1 | **netd 是不是 root** | `Uid: 0 0 0 0`，`ps` 显示 `root netd` | **uid-0 方案正式判死**（§2）。sceric 的判断被实测证实 |
| 2 | `/etc/passwd` 有无 `nobody` | 无；全文件仅 5 条，**连 `root` 都没有** | **必须 overlay**，且要保留原有 5 条 |
| 3 | `detect_upstream` | 全空（property 空 + `resolv.conf` 不存在 + `ndc` 已移除）| 告警 + 探针**双双空转** |
| 4 | 真实系统 DNS 来源 | **`dumpsys dnsresolver`** 是唯一可用取法 | 未来若要修，改这里 |
| 5 | 系统 DNS 健康状况 | **两个 v4 全 BROKEN（SERVFAIL），唯一健康的是 v6** | 支持"固定公共 DNS 当上游"这个设计 |
| 6 | `status()` 输出 | `Upstream: 223.5.5.5 119.29.29.29` | ✅ **B1 修复生效** |
| 7 | watchdog IP 变化重启 | `IP changed (…192.168.31.48… -> …10.113.79.224…), restarting forwarder` | ✅ 机制生效（WiFi→蜂窝切换被正确捕获）|

### 7.2 一个原报告的测试设计缺陷（诚实记录）

§5 第 6 步那条"uid-0 实跑对照"**证明力弱**：跑 `nslookup` 的是 **root shell 自己**，被 `--uid-owner 0 -j RETURN` 放行是**必然**的，它并不能证明 netd 是 root。真正定案的是第 1 步**直接读 `/proc/<netd-pid>/status`**。
→ **该实验可以退休**，保留第 1 步（零风险只读）即可。原报告把它写成"10 秒定生死"是夸大了。

### 7.3 本次实测新暴露的两条（**只记录，不动代码**）

**① v6 路径完全绕过 smartdns，而它恰好是这台机上唯一健康的 DNS**

`status` 明确报 `IPv6 DNAT: unavailable on this kernel, v6 DNS queries bypass`；而系统 DNS 里健康的又只有 v6 那个。于是：
- `sc-nas.tailc5859.ts.net` 的解析变成一场**竞争**：v4 那路被 DNAT 进 smartdns（本地直答 100.x，几乎瞬时）vs v6 那路直连电信 v6 DNS（返回 NXDOMAIN）。
- Android 解析器取**首个 NOERROR**，本地直答基本必胜 → **实际可用**，与"两台都正常"一致。
- **风险**：一旦 smartdns 变慢或挂掉（watchdog 降级窗口内），NXDOMAIN 那路就会胜出 → ts.net 解析失败。属于降级场景的固有抖动，**当前无需处理，知道即可**。

**② 本机 `/etc/resolv.conf` 不存在，libc 回退到 `8.8.8.8`**

实跑对照那段显示 `Server: 8.8.8.8 dns.google` —— 因为 `resolv.conf` 不存在，libc 用了编译期默认 DNS。对模块**无影响**（8.8.8.8 不在放行名单里，走 libc 默认的查询反而会被劫持进 smartdns）。

### 7.4 MIUI 自有 NAT 链

`iptables -t nat -L OUTPUT` 里，MIUI 的 `onelink_nat_chain` 排在模块规则**之前**（544 包）。目前未见冲突（模块规则随后有正常计数）。**记一笔备查。**

### 7.5 结论与建议

- **不按 §2 的 9999 方案动手。** 两台设备正常，且 9999 方案需要 passwd overlay + fail-closed 校验，属于"大改换小的稳定性收益"。
- **唯一值得保留的观察项**：7.3 ① 的 v6 绕过 —— 如果以后出现"ts.net 时好时坏"，第一个怀疑对象就是它。
- 若哪天仍要推进 9999：本轮的 4 条实测数据（netd=root、passwd 无 nobody、dumpsys 是真实来源、v4 全坏）已足够直接开工，不必再探。

---

## 附：方法

源码树 ↔ zip sha256 逐字节比对 → 版本间 unified diff → 全树 grep 引用面（`DOMAINS`/`detect_upstream`/`upstream_list`/owner/私网段）→ 逐行读改动 → busybox nslookup 输出格式外部查证。脚本在 `.workbuddy/tmp/`。
