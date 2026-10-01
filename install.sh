#!/bin/sh
# =====================================================================
# Simcom WebUI Installer (runs inside SIM8260 / SDX62 ADB shell)
# Usage:
#   1. adb push simcom-webui /tmp/simcom-webui
#   2. adb shell sh /tmp/simcom-webui/install.sh
# =====================================================================

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SERVICE_FILE=simcom-webui.service
HTPASSWD_FILENAME=.htpasswd

# ------------------------------------------------------------
# 解析「运行时目录」= 内存文件系统上的工作目录（锁/日志/心跳/临时文件）
# 用于把 systemd/lighttpd.conf 里的 @RUNDIR@ 替换成实际落点。
# at-runenv.sh 只读 /proc/mounts 判定 fs 类型，不打印任何输出。
# ------------------------------------------------------------
AT_RUN_DIR=""
if [ -f "$SRC_DIR/at-runenv.sh" ]; then
    . "$SRC_DIR/at-runenv.sh"
fi
[ -n "$AT_RUN_DIR" ] || { AT_RUN_DIR=/tmp/simcom-webui; AT_RUN_IS_RAM=0; }
echo "Runtime dir (logs/locks/tmp): $AT_RUN_DIR (in-RAM=$AT_RUN_IS_RAM)"

# 判断 /etc 是否"易失"(重启即丢)：tmpfs/ramfs，或 overlay 且 upperdir 落在内存分区。
# 返回: 0 = 持久(可依赖 systemctl enable)，1 = 易失(enable 重启丢，需兜底)
etc_is_volatile() {
    _EFS=$(awk '$2=="/etc"{print $3;exit}' /proc/mounts 2>/dev/null)
    _EOPTS=$(awk '$2=="/etc"{print $4;exit}' /proc/mounts 2>/dev/null)
    if [ -z "$_EFS" ]; then
        _EFS=$(awk '$2=="/"{print $3;exit}' /proc/mounts 2>/dev/null)
        _EOPTS=$(awk '$2=="/"{print $4;exit}' /proc/mounts 2>/dev/null)
    fi
    case "$_EFS" in
        tmpfs|ramfs)
            return 1
            ;;
        overlay|overlayfs)
            echo "$_EOPTS" | grep -qiE 'upperdir=(/tmp|/dev|/run|/tmpfs|/cmb|/mem)[/,]?' && return 1
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

echo "=============================================="
echo " Simcom WebUI Installer"
echo " Target: SIM8260 / SDX62"
echo "=============================================="

# ------------------------------------------------------------
# 1. 探测可写目录
# ------------------------------------------------------------
echo "[1/8] Finding writable directory..."
CANDIDATES="/userdata /usrdata /data /opt /home/root /var /mnt/userdata"
WEBUI_DIR=""
for d in $CANDIDATES; do
    if [ -d "$d" ] && mkdir -p "$d/.wtest" 2>/dev/null; then
        rmdir "$d/.wtest" 2>/dev/null
        WEBUI_DIR="$d/simcom-webui"
        echo "  Using: $d"
        break
    fi
done
if [ -z "$WEBUI_DIR" ]; then
    echo "  ERROR: No writable directory found. Tried: $CANDIDATES"
    exit 1
fi
echo "  Install path: $WEBUI_DIR"

# ------------------------------------------------------------
# 2. 创建目录结构
# ------------------------------------------------------------
echo "[2/8] Creating directories..."
mkdir -p "$WEBUI_DIR"
mkdir -p "$WEBUI_DIR/www"
mkdir -p "$WEBUI_DIR/cgi-bin"
mkdir -p "$WEBUI_DIR/systemd"
mkdir -p "$WEBUI_DIR/socat-at-bridge"

# ------------------------------------------------------------
# 3. 拷贝前端 + CGI
# ------------------------------------------------------------
echo "[3/8] Copying frontend and CGI..."
cp -r "$SRC_DIR/www/"* "$WEBUI_DIR/www/"
for cgi in atcmd sms password sysinfo deviceinfo shell libat.sh; do
    cp "$SRC_DIR/cgi-bin/$cgi" "$WEBUI_DIR/cgi-bin/$cgi"
    chmod +x "$WEBUI_DIR/cgi-bin/$cgi"
done
# CGI / 桥脚本都会 source "$WEBUI_DIR/at-runenv.sh"（= $(dirname $0)/../at-runenv.sh）。
# 这个文件负责把日志/锁/心跳/临时文件落到内存 fs；少了它，所有 CGI 会退回
# /tmp/simcom-webui（不保证是内存）→ 持续写 NAND。必须一起装。
if [ -f "$SRC_DIR/at-runenv.sh" ]; then
    cp "$SRC_DIR/at-runenv.sh" "$WEBUI_DIR/at-runenv.sh"
    chmod +x "$WEBUI_DIR/at-runenv.sh"
else
    echo "  WARN: at-runenv.sh missing in source -> runtime files may land on NAND!"
fi
# password CGI 中硬编码了 /usrdata，按实际安装路径替换
sed -i "s|/usrdata/simcom-webui|$WEBUI_DIR|g" "$WEBUI_DIR/cgi-bin/password"

# 双保险：在 www 下创建 cgi-bin 软链接
# lighttpd.conf 已配 alias.url，但万一 mod_alias 不可用，软链接也能让 cgi-bin 被找到
if [ ! -e "$WEBUI_DIR/www/cgi-bin" ]; then
    ln -s "$WEBUI_DIR/cgi-bin" "$WEBUI_DIR/www/cgi-bin" 2>/dev/null
fi
echo "  Done."

# 初始化密码文件（如不存在）: 默认 admin/admin
if [ ! -f "$WEBUI_DIR/$HTPASSWD_FILENAME" ]; then
    if command -v openssl >/dev/null 2>&1; then
        HASH=$(openssl passwd -apr1 'admin')
    elif command -v htpasswd >/dev/null 2>&1; then
        HASH=$(htpasswd -nb admin 'admin' | cut -d: -f2)
    else
        HASH=""
        echo "  WARN: no openssl/htpasswd. Password auth won't work until you set it up."
    fi
    if [ -n "$HASH" ]; then
        echo "admin:$HASH" > "$WEBUI_DIR/$HTPASSWD_FILENAME"
        chmod 600 "$WEBUI_DIR/$HTPASSWD_FILENAME"
        echo "  Default login: admin / admin"
    fi
fi

# ------------------------------------------------------------
# 4. 部署 socat AT 串口桥接
# ------------------------------------------------------------
echo "[4/8] Deploying socat AT bridge..."
if [ -d "$SRC_DIR/socat-at-bridge" ]; then
    # 逐项拷贝，跳过 socat 二进制 —— 它可能正被运行中的 socat 进程占用
    # （"Text file busy"），直接 cp 会报错。二进制单独走下面的"remap"路径。
    for _f in "$SRC_DIR/socat-at-bridge/"*; do
        _b=$(basename "$_f")
        [ "$_b" = "socat-armel-static" ] && continue
        cp -r "$_f" "$WEBUI_DIR/socat-at-bridge/$_b"
    done
    # socat-armel-static 可能正在被运行中的 socat 进程占用（"Text file busy"）
    # → 先写 .new 再 mv 覆盖。mv 只替换目录项，运行中的进程仍持有旧 inode，
    #   不会中断当前桥接；下次重启自然用上新二进制。
    if [ -f "$SRC_DIR/socat-at-bridge/socat-armel-static" ]; then
        _NEWBIN="$WEBUI_DIR/socat-at-bridge/socat-armel-static.new"
        if cp "$SRC_DIR/socat-at-bridge/socat-armel-static" "$_NEWBIN" 2>/dev/null; then
            if mv -f "$_NEWBIN" "$WEBUI_DIR/socat-at-bridge/socat-armel-static" 2>/dev/null; then
                :
            else
                echo "  WARN: socat binary in use, kept the running copy (update applies after next bridge restart)"
            fi
            rm -f "$_NEWBIN" 2>/dev/null
        else
            echo "  WARN: cannot stage socat binary (kept existing)"
        fi
    fi
    chmod +x "$WEBUI_DIR/socat-at-bridge/start_socat_bridge.sh" 2>/dev/null
    chmod +x "$WEBUI_DIR/socat-at-bridge/socat-armel-static" 2>/dev/null
    chmod +x "$WEBUI_DIR/socat-at-bridge/fix_systemd_autostart.sh" 2>/dev/null
    # 看门狗/自检脚本会被 autostart.sh 与 init.d 用 [ -x ] 判断，必须带可执行位
    chmod +x "$WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh" 2>/dev/null
    chmod +x "$WEBUI_DIR/socat-at-bridge/bridge_status.sh" 2>/dev/null
    echo "  socat binary: $WEBUI_DIR/socat-at-bridge/socat-armel-static"
else
    echo "  WARN: socat-at-bridge not found in source."
fi

# 检测 AT 串口
AT_DEV=""
for d in /dev/smd8 /dev/smd7 /dev/smd11; do
    [ -c "$d" ] && { AT_DEV="$d"; break; }
done
echo "  AT device: ${AT_DEV:-not found}"

# 启动桥接：**唯一 owner = bridge_watchdog.sh**
# 为什么不再用参考项目的「3 个 systemd 单元」（socat + 两条 cat 腿）：
#   · 看门狗本身就会拉起 socat + 两条腿。两套同时生效会出现
#       - 两个 socat 抢 /dev/ttyIN2（谁后建谁覆盖 symlink），
#       - 多个 cat 抢读 /dev/smd8（AT 响应被随机瓜分），
#     表现为"时通时不通 / AT 全部转圈圈"。这正是用户上报过的现象。
#   · 看门狗比 systemd 单元多了：手工 pty 兜底、孤儿读线程回收、心跳感知探活、
#     ttyIN2/ttyOUT2 方向自校验，且 pidfile/日志全部落内存 fs（不磨 NAND）。
# 所以这里显式停用/清除历史遗留的 systemd 桥接单元，统一交给看门狗
# （看门狗内部也有 disarm_systemd_units 兜底，这里再清一次以防它还没跑起来）。
if [ -n "$AT_DEV" ]; then
    # 从 /dev/smd8 提取 "smd8"
    AT_DEV_NAME=$(basename "$AT_DEV")

    if command -v systemctl >/dev/null 2>&1; then
        _DISARMED=0
        for _u in \
            socat-$AT_DEV_NAME.service \
            socat-$AT_DEV_NAME-to-ttyIN2.service \
            socat-$AT_DEV_NAME-from-ttyIN2.service \
            socat-smd8.service socat-smd7.service socat-smd11.service \
            socat-smd8-to-ttyIN2.service socat-smd8-from-ttyIN2.service \
            socat-smd7-to-ttyIN2.service socat-smd7-from-ttyIN2.service \
            socat-smd11-to-ttyIN2.service socat-smd11-from-ttyIN2.service
        do
            if systemctl is-active "$_u" >/dev/null 2>&1; then
                systemctl stop "$_u" >/dev/null 2>&1 || true
                systemctl disable "$_u" >/dev/null 2>&1 || true
                echo "  disabled legacy bridge unit: $_u"
                _DISARMED=1
            fi
            rm -f "/etc/systemd/system/$_u" 2>/dev/null
        done
        [ "$_DISARMED" = "1" ] && systemctl daemon-reload 2>/dev/null || true
    fi

    # 统一由看门狗启动：前台 --restart 重建整桥（含首次探活），再 setsid 起常驻守护
    if [ -x "$WEBUI_DIR/socat-at-bridge/start_socat_bridge.sh" ]; then
        echo "  Starting AT bridge via watchdog..."
        sh "$WEBUI_DIR/socat-at-bridge/start_socat_bridge.sh" > "$AT_RUN_DIR/install-socat-bridge.log" 2>&1
    elif [ -x "$WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh" ]; then
        echo "  Starting bridge watchdog directly..."
        sh "$WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh" --restart > "$AT_RUN_DIR/install-socat-bridge.log" 2>&1
    else
        echo "  WARN: bridge scripts missing (start_socat_bridge.sh / bridge_watchdog.sh)"
    fi

    # 验证桥接是否就绪
    sleep 1
    if [ -c /dev/ttyOUT2 ]; then
        echo "  [OK] bridge ready: /dev/ttyOUT2"
        if [ -f "$AT_STATE_DIR/watchdog.pid" ]; then
            echo "  [OK] watchdog running (pid=$(cat "$AT_STATE_DIR/watchdog.pid" 2>/dev/null))"
        else
            echo "  WARN: watchdog pidfile missing - 桥在跑但无人守护，看 $AT_LOG_DIR/bridge.log"
        fi
    else
        echo "  WARN: /dev/ttyOUT2 not created. Check $AT_RUN_DIR/install-socat-bridge.log"
    fi
else
    echo "  SKIP: no AT device found, bridge not deployed"
fi

# ------------------------------------------------------------
# 5. 检测 lighttpd
# ------------------------------------------------------------
echo "[5/8] Checking web server..."
LIGHTTPD=""
if [ -x /opt/sbin/lighttpd ]; then
    LIGHTTPD=/opt/sbin/lighttpd
    echo "  lighttpd: /opt/sbin/lighttpd (Entware)"
elif [ -x /usr/sbin/lighttpd ]; then
    LIGHTTPD=/usr/sbin/lighttpd
    echo "  lighttpd: /usr/sbin/lighttpd (system)"
elif [ -x /usr/bin/lighttpd ]; then
    LIGHTTPD=/usr/bin/lighttpd
    echo "  lighttpd: /usr/bin/lighttpd"
else
    echo "  WARN: lighttpd not found."
    echo "        Install Entware first, then: opkg install lighttpd"
fi

# ------------------------------------------------------------
# 6. 部署配置（按实际安装路径改写）
# ------------------------------------------------------------
echo "[6/8] Deploying config..."

# lighttpd.conf：替换安装路径 + 运行时目录占位符
#   @RUNDIR@ 是日志/临时目录落点。必须在内存 fs 上 —— 否则 lighttpd 的
#   errorlog/tmpdir 会持续写 NAND。accesslog 在配置里已刻意不开启。
sed -e "s|/usrdata/simcom-webui|$WEBUI_DIR|g" \
    -e "s|@RUNDIR@|$AT_RUN_DIR|g" \
    "$SRC_DIR/systemd/lighttpd.conf" > "$WEBUI_DIR/systemd/lighttpd.conf"
# tmpdir 必须真实存在，lighttpd 不会自己建
mkdir -p "$AT_RUN_DIR/lighttpd-tmp" 2>/dev/null || true

# 尝试部署 systemd 服务
HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1; then
    if [ -n "$LIGHTTPD" ]; then
        sed -e "s|/opt/sbin/lighttpd|$LIGHTTPD|g" \
            -e "s|/usrdata/simcom-webui|$WEBUI_DIR|g" \
            "$SRC_DIR/systemd/$SERVICE_FILE" > /etc/systemd/system/$SERVICE_FILE 2>/dev/null && HAS_SYSTEMD=1
    else
        cp "$SRC_DIR/systemd/$SERVICE_FILE" /etc/systemd/system/$SERVICE_FILE 2>/dev/null && HAS_SYSTEMD=1
    fi
fi

# systemd 不可用 → 写启动脚本
if [ "$HAS_SYSTEMD" = "0" ]; then
    echo "  systemd not available, writing init script..."
    cat > "$WEBUI_DIR/start.sh" <<INITEOF
#!/bin/sh
# auto-generated start script
cd "$WEBUI_DIR"
if [ -n "$LIGHTTPD" ] && [ -x "$LIGHTTPD" ]; then
    $LIGHTTPD -f "$WEBUI_DIR/systemd/lighttpd.conf"
    echo "lighttpd started, pid: \$!"
else
    echo "ERROR: lighttpd not found"
    exit 1
fi
INITEOF
    chmod +x "$WEBUI_DIR/start.sh"
fi

# ------------------------------------------------------------
# 7. 启动 WebUI
# ------------------------------------------------------------
echo "[7/8] Starting WebUI..."

# 先杀旧的
pkill -f "lighttpd.*simcom-webui" 2>/dev/null || true
kill $(cat "$AT_RUN_DIR/simcom-webui-lighttpd.pid" 2>/dev/null) 2>/dev/null || true
sleep 1

# 重建 lighttpd 的 tmpdir（tmpfs 重启即清空；重部署时也必须确保存在，
# 否则下段 systemctl restart / 手动启动会因 tmpdir 不存在而失败）
mkdir -p "$AT_RUN_DIR/lighttpd-tmp" 2>/dev/null || true

if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable $SERVICE_FILE 2>/dev/null || true
    systemctl restart $SERVICE_FILE 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet $SERVICE_FILE 2>/dev/null; then
        echo "  [OK] service started"
    else
        echo "  service failed, trying manual launch..."
        if [ -n "$LIGHTTPD" ] && [ -x "$LIGHTTPD" ]; then
            $LIGHTTPD -f "$WEBUI_DIR/systemd/lighttpd.conf"
            echo "  lighttpd started manually (pid: $!)"
        fi
    fi

    # ---- 易失性检测：/etc 若为 tmpfs/内存 overlay，enable 重启即丢 ----
    # 这是"装完 enabled、重启 disabled"的真正根因。检测到易失则提示，
    # 但持久自启已统一走 /etc/init.post_boot.sh 钩子（见下方 7.5 步），不受影响。
    if ! etc_is_volatile; then
        echo "  [WARN] /etc is volatile - systemctl enable links will be LOST on reboot."
        echo "         (自启已通过 /etc/init.post_boot.sh 钩子兜底，见 [7.5/8])"
    fi
else
    if [ -n "$LIGHTTPD" ] && [ -x "$LIGHTTPD" ]; then
        $LIGHTTPD -f "$WEBUI_DIR/systemd/lighttpd.conf" &
        echo "  lighttpd started (pid: $!)"
    else
        echo "  cannot start: lighttpd not available"
    fi
fi

# ------------------------------------------------------------
# 7.5 持久开机钩子：写入 /etc/init.post_boot.sh（高通 SDX62 开机脚本）
# ------------------------------------------------------------
# 无论 systemd enable 是否跨重启持久，都通过 fix_systemd_autostart.sh：
#   1) 生成持久自启脚本 $WEBUI_DIR/autostart.sh（含等待 AT 设备就绪）
#   2) 把 `sh .../autostart.sh &` 幂等追加到 /etc/init.post_boot.sh
# 模块固件每次开机都会执行 init.post_boot.sh，从而保证跨重启自启。
if [ -x "$WEBUI_DIR/socat-at-bridge/fix_systemd_autostart.sh" ]; then
    echo "[7.5/8] Hooking autostart into /etc/init.post_boot.sh ..."
    sh "$WEBUI_DIR/socat-at-bridge/fix_systemd_autostart.sh" || true
    if grep -q simcom-webui /etc/init.post_boot.sh 2>/dev/null; then
        echo "  [OK] /etc/init.post_boot.sh hooked"
    else
        echo "  [WARN] /etc/init.post_boot.sh not writable/hooked, check manually"
    fi
fi

# ------------------------------------------------------------
# 8. 验证
# ------------------------------------------------------------
echo "[8/8] Verifying..."
sleep 1
if command -v wget >/dev/null 2>&1; then
    # 注意：-O- 会把响应体也写到 stdout，和 --server-response 的头混在一起，
    # 用 tail -1 会取到正文里的"HTTP/"字样（曾输出 "HTTP status: server"）。
    # 改为 -O /dev/null 丢弃正文，取**第一行** HTTP 状态行。
    CODE=$(wget -S -O /dev/null --timeout=5 http://127.0.0.1:8888/ 2>&1 | grep -i "HTTP/" | head -1 | awk '{print $2}')
    case "$CODE" in
        200|30[0-9]) echo "  HTTP status: $CODE (web OK)" ;;
        401)         echo "  HTTP status: 401 (web OK - basic auth required, 默认 admin/admin)" ;;
        "")          echo "  HTTP status: no response (lighttpd 可能没起来)" ;;
        *)           echo "  HTTP status: $CODE" ;;
    esac
elif command -v curl >/dev/null 2>&1; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8888/ 2>/dev/null)
    echo "  HTTP status: ${CODE:-unknown}"
else
    echo "  (no wget/curl, skip HTTP check)"
fi

# 获取模块 IP
# 注意：busybox grep 不支持 -P (Perl 正则)，用 awk 提取
MODULE_IP=""
if command -v ip >/dev/null 2>&1; then
    MODULE_IP=$(ip -4 addr show rmnet0 2>/dev/null | awk '/inet /{gsub(/\/.*/,"",$2); print $2; exit}')
    [ -z "$MODULE_IP" ] && MODULE_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{gsub(/\/.*/,"",$2); print $2; exit}')
fi
[ -z "$MODULE_IP" ] && MODULE_IP="192.168.225.1"

echo ""
echo "=============================================="
echo " Install complete!"
echo " Path     : $WEBUI_DIR"
echo " AT device: ${AT_DEV:-unknown}"
echo " URL      : http://$MODULE_IP:8888/"
echo " User     : admin / admin"
echo "=============================================="
