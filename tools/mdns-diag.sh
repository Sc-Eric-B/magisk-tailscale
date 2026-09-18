#!/system/bin/sh
# ============================================================
# mdns-diag.sh — Magisk-Tailscaled 复发诊断脚本
#
# 用法：
#   su
#   sh /sdcard/mdns-diag.sh         # 诊断（自动存快照并对比上次）
#   sh /sdcard/mdns-diag.sh history # 查看历史记录
#
# 说明：
#   * 首次运行自动存快照到 /sdcard/mdns-diag-last.txt
#   * 之后每次运行与上次对比，标注变化项
#   * 故障现场跑（先不要 restart），把输出整段发回分析
# ============================================================

BB=/data/adb/magisk/busybox
SCRIPTS=/data/adb/tailscale/scripts
RUN=/data/adb/tailscale/run
CONF=$RUN/smartdns.conf
SPID_FILE=$RUN/smartdns.pid
LAST=/sdcard/mdns-diag-last.txt
HIST=/sdcard/mdns-diag-history.log

NOW=$(date '+%m-%d %H:%M:%S')
say() { echo "[$NOW] $*"; }

# 快照读写
get_last() { grep "^$1=" "$LAST" 2>/dev/null | cut -d= -f2; }
chg() { # chg <label> <cur> <key>
  local old
  old=$(get_last "$3")
  if [ -z "$old" ]; then
    echo "      $1: $2  (首次)"
  elif [ "$old" != "$2" ]; then
    echo "  ⚠  $1: $2  (上次: $old)"
  else
    echo "      $1: $2  (无变化)"
  fi
}

echo
say "======== Magisk-Tailscaled 复发诊断 ========"

# ---------- 1. 网络环境 ----------
say "== 网络 =="
NETS=""
for i in wlan0 rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3; do
  ip4=$($BB ip -4 addr show "$i" 2>/dev/null | $BB grep -o 'inet [0-9.]*' | head -1)
  [ -n "$ip4" ] && NETS="$NETS $i=${ip4#inet }"
done
[ -n "$NETS" ] && say "接口:$NETS" || say "接口:(无IPv4地址?)"

# ---------- 2. 模块状态 ----------
say "== 模块 =="
"$SCRIPTS/tailscaled.dns" status 2>/dev/null | $BB grep -E "forwarder|watchdog|DNAT|Upstream|entries" || say "(tailscaled.dns status 不可用)"

# ---------- 3. 劫持规则与计数 ----------
say "== 劫持计数 =="
RULES=$(iptables -t nat -L OUTPUT -n -v 2>/dev/null | $BB grep "dpt:53")
echo "$RULES"
DNAT_PKTS=$(echo "$RULES" | $BB grep "DNAT" | $BB grep udp | $BB awk '{print $1; exit}')
[ -z "$DNAT_PKTS" ] && DNAT_PKTS=0
RT_PKTS=$(echo "$RULES" | $BB grep "RETURN" | $BB awk '{s+=$1} END{print s+0}')
chg "DNAT udp 劫持计数" "$DNAT_PKTS" "DNAT_PKTS"
chg "RETURN 放行计数" "$RT_PKTS" "RETURN_PKTS"

# ---------- 4. 直答探针（真实系统路径，不带 server 参数） ----------
say "== ts.net 直答(系统路径) =="
NODE=$($BB awk '/^domain-rules/{print $2; exit}' "$CONF" 2>/dev/null | $BB sed 's|^/||; s|/$||')
if [ -n "$NODE" ]; then
  TS_OUT=$($BB nslookup "$NODE" 2>/dev/null)
  echo "$TS_OUT" | $BB grep -E "Server:|Name:|Address [0-9]+" | head -5
  TS_IP=$(echo "$TS_OUT" | $BB grep -oE "Address [0-9]+: (100\.[0-9.]+|fd7a:[0-9a-f:]+)" | head -1 | $BB awk '{print $2}')
  if [ -n "$TS_IP" ]; then
    TS_ST=PASS
    say "判定: PASS (直答 $TS_IP)"
  else
    TS_ST=FAIL
    say "判定: FAIL (NXDOMAIN/无100.x → 劫持未生效)"
  fi
else
  TS_ST=FAIL
  say "判定: 跳过 (conf 无直答规则?)"
fi
chg "直答状态" "$TS_ST" "TS_ST"

# ---------- 5. 转发探针（127.0.0.1） ----------
say "== 公网转发(127.0.0.1) =="
FWD_OUT=$($BB nslookup baidu.com 127.0.0.1 2>/dev/null)
echo "$FWD_OUT" | $BB grep -E "Server:|Name:|Address [0-9]+" | head -5
FWD_IP=$(echo "$FWD_OUT" | $BB grep -oE "Address [0-9]+: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" | head -1 | $BB awk '{print $2}')
if [ -n "$FWD_IP" ]; then
  FWD_ST=PASS
  say "判定: PASS (转发 $FWD_IP)"
else
  FWD_ST=FAIL
  say "判定: FAIL (转发不通)"
fi
chg "转发状态" "$FWD_ST" "FWD_ST"

# ---------- 6. 进程与端口 ----------
say "== 进程/端口 =="
SPID=$(cat "$SPID_FILE" 2>/dev/null)
if [ -n "$SPID" ] && [ -d "/proc/$SPID" ]; then
  say "smartdns pid=$SPID 存活"
else
  say "smartdns pid=$SPID 不在/pid文件缺失 → 进程已死"
fi
$BB netstat -lun 2>/dev/null | $BB grep 15353 | head -3 || say "(15353 无监听!)"

# ---------- 7. smartdns.log 尾部 ----------
say "== smartdns.log 尾 3 行 =="
tail -3 "$RUN/smartdns.log" 2>/dev/null | sed 's/^/    /' || say "(日志不可读)"

# ---------- 8. 存快照 + 历史 ----------
cat > "$LAST" <<EOF
DNAT_PKTS=$DNAT_PKTS
RETURN_PKTS=$RT_PKTS
TS_ST=$TS_ST
FWD_ST=$FWD_ST
EOF
{
  echo "---- $NOW 网络:$NETS 直答:$TS_ST($TS_IP) 转发:$FWD_ST($FWD_IP) DNAT:$DNAT_PKTS RETURN:$RT_PKTS ----"
} >> "$HIST" 2>/dev/null

say "======== 完成 (快照已存 $LAST) ========"
echo
