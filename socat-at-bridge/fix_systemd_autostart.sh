#!/bin/sh
# =====================================================================
# 开机自愈 / 诊断脚本：修复 socat AT 桥接 + WebUI 开机不自启
#
# 背景：
#   SDX62 / 高通平台 /etc 常为只读 rootfs 或 tmpfs，
#   systemctl enable 的软链写进 /etc/systemd/system/<target>.wants
#   重启后丢失 → 服务能手动起、但开机不自启。
#
# 本脚本做三件事：
#   1. 自检  lighttpd 单元 (simcom-webui.service) 是否存在 / is-enabled / is-active
#   2. 自愈  单元缺失则从安装目录重建；enable 失败则改用
#             "启动式" 方案（sysv init 脚本 / rc.local）兜底
#           ★ AT 桥接不由 systemd 管：那 3 个 socat-*.service 会被**停用并清除**，
#             统一交给 bridge_watchdog.sh（唯一 owner），避免双 owner 抢串口。
#   3. 输出  每一步明确成功/失败原因
#
# 用法（模块上手，需 root）：
#   fix_systemd_autostart.sh
#   可在任意目录运行，脚本自动定位安装目录
# =====================================================================

# ---------- 定位安装目录 ----------
WEBUI_DIR=""
for d in /userdata/simcom-webui /usrdata/simcom-webui /data/simcom-webui /opt/simcom-webui; do
    if [ -d "$d" ] && [ -f "$d/systemd/lighttpd.conf" ]; then
        WEBUI_DIR="$d"; break
    fi
done
[ -z "$WEBUI_DIR" ] && { echo "ERROR: cannot locate simcom-webui install dir"; exit 1; }
echo "Install dir : $WEBUI_DIR"

# ---------- 探测 AT 设备，反推桥接服务名 ----------
AT_DEV=""
for d in /dev/smd8 /dev/smd7 /dev/smd11; do
    [ -c "$d" ] && { AT_DEV="$d"; break; }
done
[ -z "$AT_DEV" ] && { echo "WARN: no AT device (smd8/smd7/smd11) found now."; }
# AT_DEV 可能为空（节点还没出现）。basename "" 会得到空串，拼出来的单元名
# 会变成 "socat-.service"，所以给个安全默认值。
AT_DEV_NAME=$(basename "${AT_DEV:-smd8}" 2>/dev/null)
[ -n "$AT_DEV_NAME" ] || AT_DEV_NAME=smd8
BRIDGE_MAIN="socat-$AT_DEV_NAME.service"          # socat-smd8.service
BRIDGE_TO="socat-$AT_DEV_NAME-to-ttyIN2.service"
BRIDGE_FROM="socat-$AT_DEV_NAME-from-ttyIN2.service"
WEBUI_SVC="simcom-webui.service"
SOCAT_BIN="$WEBUI_DIR/socat-at-bridge/socat-armel-static"

has_systemd=0
command -v systemctl >/dev/null 2>&1 && has_systemd=1

echo "AT device   : ${AT_DEV:-none}"
echo "WebUI unit  : $WEBUI_SVC"
echo "Legacy units: $BRIDGE_MAIN / $BRIDGE_TO / $BRIDGE_FROM  (将被停用，桥改由看门狗守护)"
echo ""

# ---------- 1. 判断 /etc 能否持久化 enable 链接 ----------
# 关键: 只 touch 判"可写"不够 —— rootfs 若为 overlayfs(upperdir 在内存) 或 /etc 为 tmpfs,
#        写入会落在内存上层, 重启即丢(enable 链接消失 -> service 退回 disabled)。
#        这才是"装完 enabled、重启后 disabled"的真正根因。
echo "== [1] Checking filesystem persistence =="
ETC_RO=0
ETC_VOLATILE=0   # 1 表示 /etc 位于易失文件系统(重启丢)

# 1a) 判 /etc 所在文件系统类型（先用 /etc 自己的挂载行，取不到再退回根挂载）
ETC_FS=$(awk '$2=="/etc"{print $3;exit}' /proc/mounts 2>/dev/null)
ETC_OPTS=""
if [ -n "$ETC_FS" ]; then
    ETC_OPTS=$(awk '$2=="/etc"{print $4;exit}' /proc/mounts 2>/dev/null)
else
    ETC_FS=$(awk '$2=="/"{print $3;exit}' /proc/mounts 2>/dev/null)
    ETC_OPTS=$(awk '$2=="/"{print $4;exit}' /proc/mounts 2>/dev/null)
fi
echo "   mount /etc : ${ETC_FS:-n/a} (opts=${ETC_OPTS:--})"
case "$ETC_FS" in
    tmpfs|ramfs)
        ETC_VOLATILE=1
        ;;
    overlay|overlayfs)
        # overlay 上层若是内存分区, 同样重启丢失
        echo "$ETC_OPTS" | grep -qiE 'upperdir=(/tmp|/dev|/run|/tmpfs|/cmb|/mem)[/,]?' && ETC_VOLATILE=1
        ;;
esac

# 1b) 是否可写
TSTAMP=$(date +%s)
if touch "/etc/.autostart_probe_$TSTAMP" 2>/dev/null; then
    rm -f "/etc/.autostart_probe_$TSTAMP"
    echo "   /etc is WRITABLE"
    ETC_RO=0
else
    echo "   /etc is READ-ONLY"
    ETC_RO=1
fi

if [ "$ETC_VOLATILE" = "1" ]; then
    echo "   !! /etc is VOLATILE (tmpfs/overlay-in-memory): systemctl enable will NOT survive reboot"
fi

# ---------- 2. 确保 unit 文件存在（缺失则从安装目录重建） ----------
echo ""
echo "== [2] Ensuring unit files exist =="
ensure_unit() {
    local name="$1"
    if [ -f "/etc/systemd/system/$name" ]; then
        echo "   [OK ] $name already in /etc/systemd/system"
    else
        echo "   [FIX] $name missing, recreating..."
        case "$name" in
            "$BRIDGE_MAIN")
                sed -e "s|SOCAT_PATH|$SOCAT_BIN|g" \
                    "$WEBUI_DIR/socat-at-bridge/socat-smd8.service" > "/etc/systemd/system/$name" 2>/dev/null
                ;;
            "$BRIDGE_TO")
                sed -e "s|smd8|$AT_DEV_NAME|g" \
                    "$WEBUI_DIR/socat-at-bridge/socat-smd8-to-ttyIN2.service" > "/etc/systemd/system/$name" 2>/dev/null
                ;;
            "$BRIDGE_FROM")
                sed -e "s|smd8|$AT_DEV_NAME|g" \
                    "$WEBUI_DIR/socat-at-bridge/socat-smd8-from-ttyIN2.service" > "/etc/systemd/system/$name" 2>/dev/null
                ;;
            "$WEBUI_SVC")
                # 替换 lighttpd 路径与安装路径
                sed -e "s|/opt/sbin/lighttpd|$(command -v lighttpd || echo /opt/sbin/lighttpd)|g" \
                    -e "s|/usrdata/simcom-webui|$WEBUI_DIR|g" \
                    "$WEBUI_DIR/systemd/$WEBUI_SVC" > "/etc/systemd/system/$name" 2>/dev/null
                ;;
        esac
        [ -s "/etc/systemd/system/$name" ] && echo "   [OK ] recreated $name" || echo "   [ERR] failed to write $name"
    fi
}

if [ "$has_systemd" = "1" ]; then
    # lighttpd 仍由 systemd 管理（Restart=always 能自愈）
    ensure_unit "$WEBUI_SVC"
    # AT 桥接统一交给 bridge_watchdog.sh（唯一 owner）—— 旧版那 3 个
    # socat-*.service 单元必须**清除并禁用**：它们和看门狗会同时拉起 socat /
    # 两条 cat 腿，导致"两个 socat 抢 /dev/ttyIN2、多个 cat 抢读 /dev/smd8"，
    # 表现为"时通时不通 / AT 全部转圈圈"。看门狗内部也会 disarm，这里再清一次。
    for _bu in "$BRIDGE_MAIN" "$BRIDGE_TO" "$BRIDGE_FROM"; do
        systemctl is-active "$_bu" >/dev/null 2>&1 && systemctl stop "$_bu" >/dev/null 2>&1
        systemctl is-enabled "$_bu" >/dev/null 2>&1 && systemctl disable "$_bu" >/dev/null 2>&1
        rm -f "/etc/systemd/system/$_bu" 2>/dev/null
    done
    systemctl daemon-reload 2>/dev/null
fi

# ---------- 3. enable + 校验（若 /etc 只读 / 易失，给出兜底方案） ----------
echo ""
echo "== [3] Enabling autostart =="

# 持久自启脚本：落在 $WEBUI_DIR（/userdata 等持久分区），不依赖 /etc 是否易失。
# /etc/init.post_boot.sh（高通开机钩子）里只做"转发引用"，真正的启动逻辑在此。
PERSIST_START="$WEBUI_DIR/autostart.sh"
_setup_persist_start() {
    # 版本标记：脚本内容升级时递增，保证旧版本能被重新生成覆盖
    # v4: 日志改到内存目录(at-runenv.sh 解析) + 开机清空，不再 append 到 /tmp 无限增长
    # v5: lighttpd 唯一 owner —— systemd 单元已 enable 时不再自己 setsid 拉一份
    #     （否则两个 lighttpd 抢 8888）。**改内容必须递增 _VER**，否则这里会
    #     `grep -q "$_VER" && return` 早退，新内容永远写不进 autostart.sh。
    _VER="v5"
    grep -q "simcom-webui-autostart-$_VER" "$PERSIST_START" 2>/dev/null && return
    echo "   [FALLBACK] writing persistent start script: $PERSIST_START ($_VER)"
    # 用「单引号 heredoc + 事后 sed 替换」生成：
    #   之前用不带引号的 heredoc，脚本里每个 $ 都要写成 \$、反引号还会被当命令
    #   替换执行（踩过：注释里的 `...` 被展开成空串）。改成 quoted heredoc 后
    #   生成的内容与这里看到的一模一样，没有转义陷阱。
    cat > "$PERSIST_START.tmp" <<'AUTOSTART_EOF'
#!/bin/sh
# simcom-webui-autostart-@VER@
# Persistent autostart for SIM8260 WebUI (auto-generated by fix_systemd_autostart.sh)
# 落点在持久分区 @WEBUI_DIR@, 由 /etc/init.post_boot.sh 等开机入口调用。
# 即便 /etc 为易失(tmpfs/内存overlay), 本脚本仍在持久分区, 重启后依然可用。

# ---------- 运行时目录：只落在内存文件系统上（日志不写 NAND） ----------
# 解析逻辑在安装根目录的 at-runenv.sh（读 /proc/mounts 判定 fs 类型）。
_RUNENV="@WEBUI_DIR@/at-runenv.sh"
if [ -f "$_RUNENV" ]; then
    . "$_RUNENV"
else
    AT_LOG_DIR=/tmp/simcom-webui/log
    AT_RUN_IS_RAM=0
fi
[ -n "$AT_LOG_DIR" ] || AT_LOG_DIR=/tmp
mkdir -p "$AT_LOG_DIR" 2>/dev/null

LOG_BRIDGE="$AT_LOG_DIR/socat-bridge.log"
LOG_LIGHTTPD="$AT_LOG_DIR/lighttpd.log"
LOG_SELF="$AT_LOG_DIR/autostart.log"

# 每次开机清空自己的日志。
#   三个日志都是 append 写法（>>）；不清空就会跨重启无限增长 —— 在 tmpfs 上
#   是白吃内存，万一 /tmp 其实落在 NAND 上就是持续磨闪存。这里开机清一次，
#   既保留"本次开机"的排查信息，又保证总量恒定。
: > "$LOG_BRIDGE" 2>/dev/null
: > "$LOG_LIGHTTPD" 2>/dev/null
: > "$LOG_SELF" 2>/dev/null
# 把自身输出也接到日志里（后续所有 echo 自动落盘，供排查开机问题）。
# 先试写再 exec：exec 的重定向若失败会让 shell 直接退出，那样自启就断了。
if : >>"$LOG_SELF" 2>/dev/null; then
    exec >>"$LOG_SELF" 2>&1
fi

echo "[simcom-webui autostart] begin $(date)  logdir=$AT_LOG_DIR ram=$AT_RUN_IS_RAM"

# 0) 等待 AT 设备就绪(init.post_boot.sh 可能在 /dev/smdX 出现前执行)
_i=0
while [ $_i -lt 60 ]; do
    _found=""
    for d in /dev/smd8 /dev/smd7 /dev/smd11; do
        [ -c "$d" ] && { _found="$d"; break; }
    done
    [ -n "$_found" ] && break
    sleep 1
    _i=$((_i+1))
done

# 1) 起 AT 桥 + 常驻看门狗
#    为什么不再用「... &」裸起：
#      · 桥是"1 个 socat + 2 条搬运腿"共 3 个互不相关的进程，没有任何守护；
#        任意一条腿异常退出，桥就断了，但 socat 还活着 —— 于是 ps 看着正常、
#        网页上 AT 却全部转圈圈。
#      · 后台进程若不脱离父会话，开机钩子脚本退出时可能被 SIGHUP 一起带走
#        （"重启后桥没了"的常见原因），所以用 setsid 单独开一个会话。
#    做法：先用 --restart 前台重建整桥（几秒内返回，顺带完成首次 AT 探活），
#          再用 setsid 起常驻看门狗。
_BRIDGE_DIR="@WEBUI_DIR@/socat-at-bridge"
if [ -x "$_BRIDGE_DIR/bridge_watchdog.sh" ]; then
    sh "$_BRIDGE_DIR/bridge_watchdog.sh" --restart >>"$LOG_BRIDGE" 2>&1
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$_BRIDGE_DIR/bridge_watchdog.sh" </dev/null >>"$LOG_BRIDGE" 2>&1 &
    else
        nohup sh "$_BRIDGE_DIR/bridge_watchdog.sh" </dev/null >>"$LOG_BRIDGE" 2>&1 &
    fi
elif [ -x "$_BRIDGE_DIR/start_socat_bridge.sh" ]; then
    sh "$_BRIDGE_DIR/start_socat_bridge.sh" --foreground >>"$LOG_BRIDGE" 2>&1 &
fi
sleep 3

# 2) 起 lighttpd
#    并发上限固定为 8：本模块只有 1 个客户端，默认值（通常几十）没必要，
#    而每个并发 CGI 都是一个 busybox 进程，越小越省内存。
#    ★ 唯一 owner 原则：若 systemd 单元已 enable（说明 /etc 可持久），就交给
#      systemd 管理 —— 它带 Restart=always，崩溃能自愈。只有 systemd 不可用
#      或单元未 enable 时，才由本脚本 setsid 兜底启动。
#      两者同时拉会冒出两个 lighttpd 抢 8888：后 bind 的失败并反复重启。
# 启动前确保 lighttpd 的 tmpdir 存在（at-runenv.sh 已建，但这里再兜底一次：
# tmpfs 重启即清空，且 systemd 拉起本脚本与 lighttpd 的时序不固定，建目录必须抢在
# lighttpd 真正 ExecStart 之前完成，否则 lighttpd 会因 tmpdir 不存在而启动失败）。
[ -n "$AT_RUN_DIR" ] && mkdir -p "$AT_RUN_DIR/lighttpd-tmp" 2>/dev/null
LIGHTTPD=$(command -v lighttpd || echo /opt/sbin/lighttpd)
_SYSD=0
command -v systemctl >/dev/null 2>&1 && systemctl is-enabled simcom-webui.service >/dev/null 2>&1 && _SYSD=1
if [ "$_SYSD" = "1" ]; then
    systemctl start simcom-webui.service >/dev/null 2>&1
    sleep 1
fi
if command -v systemctl >/dev/null 2>&1 && systemctl is-active simcom-webui.service >/dev/null 2>&1; then
    echo "[simcom-webui autostart] lighttpd managed by systemd (simcom-webui.service), skip manual start"
elif [ -x "$LIGHTTPD" ] && [ -f "@WEBUI_DIR@/systemd/lighttpd.conf" ]; then
    pkill -f "lighttpd.*simcom-webui" 2>/dev/null
    sleep 1
    if command -v setsid >/dev/null 2>&1; then
        setsid "$LIGHTTPD" -f "@WEBUI_DIR@/systemd/lighttpd.conf" </dev/null >>"$LOG_LIGHTTPD" 2>&1 &
    else
        nohup "$LIGHTTPD" -f "@WEBUI_DIR@/systemd/lighttpd.conf" </dev/null >>"$LOG_LIGHTTPD" 2>&1 &
    fi
    echo "[simcom-webui autostart] lighttpd started (setsid fallback)"
else
    echo "[simcom-webui autostart] WARN: lighttpd not available"
fi
echo "[simcom-webui autostart] end $(date)"
exit 0
AUTOSTART_EOF
    if [ -s "$PERSIST_START.tmp" ]; then
        sed -e "s|@WEBUI_DIR@|$WEBUI_DIR|g" -e "s|@VER@|$_VER|g" \
            "$PERSIST_START.tmp" > "$PERSIST_START" 2>/dev/null
        rm -f "$PERSIST_START.tmp"
    fi
    chmod +x "$PERSIST_START"
    [ -s "$PERSIST_START" ] && echo "   [OK ] persistent script at $PERSIST_START"
}

# ---------- 写 /etc/init.post_boot.sh（高通 SDX62 平台持久开机钩子） ----------
# 模块固件每次开机都会执行该脚本；把自启命令追加进去即可保证跨重启生效，
# 且不依赖 systemctl enable 的链接（那些链接在 /etc 易失时重启即丢）。
_setup_init_post_boot() {
    HOOK=/etc/init.post_boot.sh
    echo "   [HOOK] setting up $HOOK (Qualcomm boot hook)..."
    if [ ! -f "$HOOK" ]; then
        if ! touch "$HOOK" 2>/dev/null; then
            echo "   [WARN] cannot create $HOOK (read-only?), skip"
            return 1
        fi
        echo '#!/bin/sh' > "$HOOK"
    fi
    # 幂等：若已引用过则先清掉旧行，避免重复/指向旧安装路径
    if grep -q "simcom-webui" "$HOOK" 2>/dev/null; then
        sed -i '/simcom-webui/d' "$HOOK" 2>/dev/null
    fi
    echo "" >> "$HOOK"
    echo "# ---- simcom-webui autostart (added by fix_systemd_autostart.sh) ----" >> "$HOOK"
    # 末尾的 & 是必须的：init.post_boot.sh 是开机同步执行的，不加 & 会把开机流程
    # 卡在这里直到自启脚本跑完；但光有 & 还不够 —— 后台进程仍继承同一个会话，
    # 钩子所在会话被回收时可能被 SIGHUP 带走，所以真正的进程树在 autostart.sh
    # 内部统一用 setsid 脱离会话（见 _setup_persist_start 生成的内容）。
    #
    # 输出重定向到 /dev/null：autostart.sh 内部会把自己的输出接到内存目录的
    # 日志上（exec >>"$LOG_SELF"）。这里若再写一份 >>/tmp/xxx.log，就成了一个
    # 跨重启无限增长的追加日志 —— /tmp 万一不是 tmpfs，那就是持续写 NAND。
    echo "[ -x \"$PERSIST_START\" ] && sh \"$PERSIST_START\" </dev/null >/dev/null 2>&1 &" >> "$HOOK"
    chmod +x "$HOOK" 2>/dev/null
    echo "   [OK ] $HOOK -> sh $PERSIST_START & (setsid 脱离会话在本脚本内部)"
}

_setup_fallback() {
    # 0) 先建持久自启脚本（真正的启动逻辑，重启后仍在）
    _setup_persist_start

    # 1) sysv init 脚本（/etc 可写时有效；转发到持久脚本）
    echo "   [FALLBACK] writing /etc/init.d/simcom-webui (thin wrapper)"
    if [ -d /etc/init.d ] && touch /etc/init.d/.probe 2>/dev/null; then
        rm -f /etc/init.d/.probe
        cat > /etc/init.d/simcom-webui <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          simcom-webui
# Required-Start:    \$local_fs \$remote_fs
# Required-Stop:     \$local_fs \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       SIM8260 WebUI + socat AT bridge autostart
### END INIT INFO
case "\$1" in
  start) sh "$PERSIST_START";;
  stop)
      # 桥现在由看门狗统一管理，优先让它自己收摊（含解除 systemd 冲突单元）
      WD="$WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh"
      [ -x "\$WD" ] && sh "\$WD" --stop
      pkill -f "socat.*ttyIN2" 2>/dev/null
      pkill -f "cat.*ttyIN2" 2>/dev/null
      pkill -f "lighttpd.*simcom-webui" 2>/dev/null
      echo stopped;;
  *) echo "Usage: \$0 {start|stop}"; exit 1;;
esac
exit 0
EOF
        chmod +x /etc/init.d/simcom-webui
        for r in 2 3 4 5; do
            [ -d "/etc/rc$r.d" ] && ln -sf /etc/init.d/simcom-webui "/etc/rc$r.d/S99simcom-webui" 2>/dev/null
        done
        echo "   [OK ] /etc/init.d/simcom-webui installed"
    else
        echo "   [WARN] /etc/init.d not writable, skip sysv init (rely on persistent script)"
    fi

    # 2) rc.local（若可写）
    if [ -f /etc/rc.local ]; then
        # 输出丢给 /dev/null —— autostart.sh 自己会写到内存目录里的日志
        grep -q simcom-webui /etc/rc.local || echo "sh $PERSIST_START >/dev/null 2>&1 &" >> /etc/rc.local
        echo "   [OK ] appended to /etc/rc.local"
    fi

    echo "   [HINT] if /etc is volatile, call $PERSIST_START from a persistent boot hook, e.g. add to firmware /rcS or vendor autostart."
    echo "   [HINT] alternative: run '$WEBUI_DIR/socat-at-bridge/fix_systemd_autostart.sh' after every reboot to re-enable services."
}

# 持久自启脚本 + 高通开机钩子：无条件生成/写入，作为跨重启兜底
# （不依赖 systemd 是否可用、/etc 是否易失 —— 这是自启失效时的最终保障）
_setup_persist_start
_setup_init_post_boot

if [ "$has_systemd" = "1" ]; then
    # 只 enable lighttpd 单元；桥接不 enable（走看门狗，见上）
    systemctl enable "$WEBUI_SVC" >/dev/null 2>&1
    if systemctl is-enabled "$WEBUI_SVC" >/dev/null 2>&1; then
        echo "   [OK ] $WEBUI_SVC enabled"
    else
        echo "   [WARN] $WEBUI_SVC enable failed (rootfs likely read-only)"
    fi
    # 汇总：只要有失败 / 或 /etc 是易失的(tmpfs/内存overlay，重启必丢)，就上持久兜底
    if ! systemctl is-enabled "$WEBUI_SVC" >/dev/null 2>&1; then
        echo "   -> $WEBUI_SVC not enabled: running fallback"
        _setup_fallback
    elif [ "$ETC_VOLATILE" = "1" ]; then
        echo "   -> /etc is volatile: enable links vanish on reboot, running fallback too"
        _setup_fallback
    fi
else
    _setup_fallback
fi

# ---------- 4. 状态汇总 ----------
echo ""
echo "== [4] Current status =="
if [ "$has_systemd" = "1" ]; then
    for svc in "$WEBUI_SVC"; do
        EN=$(systemctl is-enabled "$svc" 2>/dev/null || echo "not-enabled")
        AC=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        echo "   $svc  enabled=$EN  active=$AC"
    done
    echo "   (AT 桥接不由 systemd 管理，改由 bridge_watchdog.sh 守护)"
fi

echo ""
echo "============================================================"
echo " 自愈完成。建议立即重启验证："
echo "   reboot"
echo " 重启后复检："
echo "   systemctl is-enabled simcom-webui.service"
echo "   ls -la /dev/ttyIN2 /dev/ttyOUT2"
echo "   grep simcom-webui /etc/init.post_boot.sh   # 应能看到自启钩子"
echo "   sh $WEBUI_DIR/socat-at-bridge/bridge_status.sh   # 桥接自检（9 项）"
echo " 自启已写入 /etc/init.post_boot.sh（高通开机钩子），重启后会自动拉起："
echo "   /etc/init.post_boot.sh"
echo " 持久启动脚本: $PERSIST_START"
echo " AT 桥接守护: $WEBUI_DIR/socat-at-bridge/bridge_watchdog.sh（唯一 owner）"
echo "============================================================"