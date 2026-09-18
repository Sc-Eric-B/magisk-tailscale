#!/system/bin/sh
# ============================================================================
# mdns16.1 真机核对清单
#   用法：su -c 'sh /data/local/tmp/verify-mdns16.1.sh'
#   或先 `su` 再 `sh /data/local/tmp/verify-mdns16.1.sh`
#
#   全部为【只读】检查，唯一会改动 iptables 的是 STEP 7 —— 那是可选实验，
#   自带清理，且失败也不会造成断网（它只是让 root 的查询绕过 DNAT）。
#
#   把下面 NODE 改成你自己的 MagicDNS 名字（内网名改成你家/公司的内网域名）
# ============================================================================
NODE="sc-nas.tailc5859.ts.net"
LANNAME="nas.lan"

BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=$(command -v busybox 2>/dev/null)
[ -n "$BB" ] || BB=nslookup
DNSSCRIPT=/data/adb/tailscale/scripts/tailscaled.dns
RUNLOG=/data/adb/tailscale/run/runs.log

hr() { echo; echo "======== $* ========"; }

hr "0. 环境"
echo "model : $(getprop ro.product.model)  ($(getprop ro.product.device))"
echo "android: $(getprop ro.build.version.release)  sdk=$(getprop ro.build.version.sdk)"
echo "busybox: $BB"
echo "node   : $NODE"

# ---------------------------------------------------------------------------
hr "1. netd 是不是 root  ← 决定 uid-0 方案生死（零风险，最先看这条）"
NPID=$(pidof netd)
echo "netd pid = ${NPID:-<none>}"
if [ -n "$NPID" ]; then
  grep -E '^(Name|Uid|Gid):' /proc/$NPID/status
fi
echo "--- 旁证：ps 列表 ---"
ps -A -o PID,USER,NAME 2>/dev/null | grep -iE 'netd|dnsproxy' 
echo
echo "判读：Uid 行第一个数字是 0  →  netd = root  →  --uid-owner 0 方案【死】"
echo "      第一个数字非 0        →  uid-0 方案理论上可用（但仍需实跑确认）"

# ---------------------------------------------------------------------------
hr "2. /etc/passwd 里有没有 nobody  ← 决定要不要 overlay passwd"
ls -l /etc/passwd /etc/group 2>&1
echo "--- grep nobody ---"
grep -i nobody /etc/passwd /etc/group 2>&1
echo "--- /etc/passwd 全文 ---"
cat /etc/passwd 2>&1
echo
echo "判读：出现 nobody:*:9999:9999  →  不需要 overlay，改动量从【大】降到【中】"
echo "      没有 nobody 或文件不存在 →  需要 \$MODPATH/system/etc/passwd overlay"

# ---------------------------------------------------------------------------
hr "3. detect_upstream 为什么空 / 真实系统 DNS 从哪来"
echo "--- getprop | grep -i dns ---"
getprop | grep -i dns
echo "--- 脚本实际读的那几个 property ---"
for p in net.dns1 net.dns2 dhcp.wlan0.dns1 dhcp.wlan0.dns2 dhcp.eth0.dns1 dhcp.eth0.dns2; do
  printf '  %-22s = [%s]\n' "$p" "$(getprop $p)"
done
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>&1
echo "--- ndc resolver getresolvers ---"
ndc resolver getresolvers 2>&1 | head -40
echo "--- dumpsys 兜底 ---"
dumpsys dnsresolver 2>/dev/null | head -40
echo
echo "判读：上面全空  →  detect_upstream 必然返回空 → P0-window 告警【永不触发】"
echo "                  且真路径探针 sysdns 为空 → 整段探针【被跳过】→ P0 零可见性"

# ---------------------------------------------------------------------------
hr "4. 当前劫持规则（放行名单里有谁）"
iptables -t nat -S OUTPUT 2>/dev/null | grep -i magicdns
echo "--- 带计数 ---"
iptables -t nat -L OUTPUT -v -n 2>/dev/null | head -20

# ---------------------------------------------------------------------------
hr "5. D1：内网域名还能不能解析"
SYS=$(getprop net.dns1)
[ -z "$SYS" ] && SYS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
echo "用系统 DNS = [${SYS:-<空>}] 去查内网名 $LANNAME"
[ -n "$SYS" ] && $BB nslookup "$LANNAME" "$SYS" 2>&1
echo
echo "判读：NXDOMAIN / can't find  →  内网名被劫持失效（D1 成立）"
echo "      返回正常内网 IP        →  内网名没被劫持（或该网络没把路由器当 DNS）"

# ---------------------------------------------------------------------------
hr "6. P0：ts.net 走真实系统路径还能不能解析"
echo "用系统 DNS = [${SYS:-<空>}] 去查 $NODE"
[ -n "$SYS" ] && $BB nslookup "$NODE" "$SYS" 2>&1
echo "--- 对照组：直接问本地 forwarder ---"
$BB nslookup "$NODE" 127.0.0.1 2>&1
echo
echo "判读：第 1 个返回 100.x / fd7a  →  劫持生效，P0 已关"
echo "      第 1 个 NXDOMAIN 而第 2 个正常 → P0 命中（系统 DNS 被放行/或探针取不到）"

# ---------------------------------------------------------------------------
hr "7. 【可选 · 会改 iptables · 自带清理】netd uid 实跑对照"
echo "跳过请直接 Ctrl-C 或忽略本段。开始前 5 秒倒计时..."
sleep 5
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -m owner --uid-owner 0 -j RETURN 2>&1
echo "已插入临时规则，现在 ts.net 查询："
$BB nslookup "$NODE" 2>&1
echo "--- 清理 ---"
iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner 0 -j RETURN 2>&1
echo "已删除（重复执行一次确保干净）："
iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner 0 -j RETURN 2>&1
echo
echo "判读：出现 NXDOMAIN  →  root 的查询被放行了 → netd 就是 root → 方案死"
echo "      仍然 100.x     →  netd 不是 root（与 STEP 1 矛盾则说明还有别的路径）"

# ---------------------------------------------------------------------------
hr "8. 模块状态与日志"
[ -f "$DNSSCRIPT" ] && sh "$DNSSCRIPT" status 2>&1
echo "--- runs.log 里的 P0 HIT ---"
grep -i "P0 HIT" "$RUNLOG" 2>/dev/null | tail -10
echo "--- runs.log 末 30 行 ---"
tail -30 "$RUNLOG" 2>/dev/null

hr "完成"
echo "把 STEP 1 / 2 / 3 的判读结果发我，就能定 9999 方案还是零改动取舍。"
