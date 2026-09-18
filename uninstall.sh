#!/system/bin/sh
# Stop MagicDNS forwarder and remove its iptables rules before cleanup
if [ -f "/data/adb/tailscale/scripts/tailscaled.dns" ]; then
    sh /data/adb/tailscale/scripts/tailscaled.dns stop 2>/dev/null
fi
rm -rf /data/adb/tailscale
SERVICE_DIR="/data/adb/service.d"
if [ -f "$SERVICE_DIR/tailscaled_service.sh" ]; then
    rm -f "$SERVICE_DIR/tailscaled_service.sh"
fi