#!/bin/sh
# Simcom WebUI Uninstall
# Auto-detects install path; can also override with: WEBUI_DIR=/xxx ./uninstall.sh

SERVICE=simcom-webui.service
# 动态匹配所有 socat bridge 服务（socat-<dev>.service / socat-<dev>-to-*.service / socat-<dev>-from-*.service）

if [ -z "$WEBUI_DIR" ]; then
    # Try common paths
    for d in /userdata/simcom-webui /usrdata/simcom-webui /data/simcom-webui /opt/simcom-webui /home/root/simcom-webui; do
        if [ -d "$d" ] && [ -f "$d/systemd/lighttpd.conf" ]; then
            WEBUI_DIR="$d"
            break
        fi
    done
fi

if [ -z "$WEBUI_DIR" ]; then
    echo "Cannot find WebUI install directory."
    echo "Run: WEBUI_DIR=/path/to/simcom-webui ./uninstall.sh"
    exit 1
fi

echo "Uninstalling Simcom WebUI from $WEBUI_DIR ..."

# 解析运行时目录（内存 fs）：锁/日志/心跳/pidfile 都在这儿
AT_RUN_DIR=""
if [ -f "$WEBUI_DIR/at-runenv.sh" ]; then
    . "$WEBUI_DIR/at-runenv.sh"
fi

# Stop socat bridge services (动态匹配所有 socat-*.service)
for svc in $(ls /etc/systemd/system/socat-*.service 2>/dev/null); do
    svc=$(basename "$svc")
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc"
done

# Stop webui service
if [ -f /etc/systemd/system/$SERVICE ]; then
    systemctl stop $SERVICE 2>/dev/null || true
    systemctl disable $SERVICE 2>/dev/null || true
    rm -f /etc/systemd/system/$SERVICE
    systemctl daemon-reload 2>/dev/null || true
fi

# Clean up sysv/rc.local autostart fallback (from fix_systemd_autostart.sh)
for r in 2 3 4 5; do
    rm -f "/etc/rc$r.d/S99simcom-webui" 2>/dev/null
done
rm -f /etc/init.d/simcom-webui 2>/dev/null
sed -i '\|/etc/init.d/simcom-webui .*|d' /etc/rc.local 2>/dev/null
sed -i '\|simcom-webui|d' /etc/rc.local 2>/dev/null

# Clean up /etc/init.post_boot.sh hook (高通 SDX62 开机钩子)
if [ -f /etc/init.post_boot.sh ]; then
    sed -i '/simcom-webui/d' /etc/init.post_boot.sh 2>/dev/null
    echo "  removed hook from /etc/init.post_boot.sh"
fi

# Kill any running bridge processes
# 先让看门狗自己收摊（它知道 socat/两条搬运腿的确切 pid，也能解除 systemd 冲突单元）
[ -x "$WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh" ] && \
    sh "$WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh" --stop 2>/dev/null || true
pkill -f "bridge_watchdog.sh" 2>/dev/null || true
pkill -f "socat.*ttyIN2" 2>/dev/null || true
pkill -f "cat.*ttyIN2" 2>/dev/null || true
# 看门狗的运行时目录 / pidfile / 探活临时文件（内存 fs，随解析结果而变）
[ -n "$AT_RUN_DIR" ] && rm -rf "$AT_RUN_DIR" 2>/dev/null
# 历史路径兜底（旧版本曾写在这里）
rm -rf /tmp/simcom-webui /tmp/simcom-webui-bridge 2>/dev/null
rm -f /tmp/simcom-webui-autostart.log /tmp/socat-bridge.log 2>/dev/null

# Kill any lighttpd running with our config
pkill -f "lighttpd.*simcom-webui" 2>/dev/null || true
kill $(cat "${AT_RUN_DIR:-/tmp}/simcom-webui-lighttpd.pid" 2>/dev/null) 2>/dev/null || true

# Remove directory
rm -rf "$WEBUI_DIR"

echo "Done."
