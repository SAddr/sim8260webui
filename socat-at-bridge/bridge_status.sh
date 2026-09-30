#!/bin/sh
# =====================================================================
# AT 桥接一键自检 (bridge_status.sh)
#
# 为什么需要它：
#   AT 通路其实是 4 个独立部件拼起来的，任何一个掉了都会表现为
#   「网页上 AT 全部转圈圈无响应」，但 `ps | grep socat` 只能看到
#   其中 1 个（socat），另外 2 条腿是 busybox 的 cat，永远不会被
#   grep socat 匹配到 —— 所以那条命令无法判断桥有没有问题。
#
#   正确的东西是这 9 项：
#     [1] AT 设备节点      /dev/smd8 (或 smd7/smd11)
#     [2] socat 进程       PTY 对 ttyIN2 <-> ttyOUT2
#     [3] PTY 节点         /dev/ttyIN2, /dev/ttyOUT2 是否为字符设备
#     [4] 读腿             cat <smdX> > /dev/ttyIN2   (模块响应 → 桥)
#     [5] 写腿             cat /dev/ttyIN2 > <smdX>   (桥 → 模块命令)
#     [6] 孤儿读线程       ppid=1 且偷读 ttyOUT2 的 cat（转圈圈的元凶）
#     [7] 真实环回探活     往 ttyOUT2 发 AT，看能否收回 OK
#                          ↑ 前 6 项都 OK 但这项 FAIL = 桥在但路不通
#     [8] web 侧 AT 心跳   看门狗据此决定"现在要不要主动探活"
#     [9] 运行时目录落点   日志/心跳/锁/临时文件有没有落在 NAND 上
#
# 用法（模块上，root）：
#   sh /userdata/simcom-webui/socat-at-bridge/bridge_status.sh
# 退出码：0 = 全部正常；1 = 有异常（可配合看门狗定时跑）
# =====================================================================

BRIDGE_DIR=$(cd "$(dirname "$0")" && pwd)

# 运行时目录与 CGI 共用同一份解析逻辑（仓库根目录 at-runenv.sh），
# 这样自检看到的 pidfile / 心跳 / 锁 就是 CGI 与看门狗实际用的那些。
_SIMCOM_RUNENV="$BRIDGE_DIR/../at-runenv.sh"
if [ -f "$_SIMCOM_RUNENV" ]; then
    . "$_SIMCOM_RUNENV"
else
    AT_RUN_DIR=/tmp/simcom-webui
    AT_STATE_DIR="$AT_RUN_DIR/bridge"
    AT_LOG_DIR="$AT_RUN_DIR/log"
    AT_TMP_DIR="$AT_RUN_DIR/tmp"
    AT_LOCK="$AT_RUN_DIR/atcmd.lock"
    AT_RUN_FS=""
    AT_RUN_IS_RAM=0
    mkdir -p "$AT_STATE_DIR" "$AT_LOG_DIR" "$AT_TMP_DIR" 2>/dev/null
fi

RUN_DIR="$AT_STATE_DIR"
LOG="$AT_LOG_DIR/bridge.log"
PROBE_LOCK="$AT_LOCK"
PROBE_TIMEOUT=3

FAILED=0
ok()   { echo "  [OK  ] $*"; }
bad()  { echo "  [FAIL] $*"; FAILED=1; }
warn() { echo "  [WARN] $*"; }

# 探活锁归属标记：只有本脚本成功 mkdir 出来的锁才会在退出时被清掉。
# （绝不能无条件 rm：另一个 CGI 正持锁时，rm 会把别人的锁删掉。）
_PROBE_MINE=0
_cleanup_probe() { [ "$_PROBE_MINE" = "1" ] && rm -rf "$PROBE_LOCK" 2>/dev/null; return 0; }
trap '_cleanup_probe' EXIT INT TERM HUP

# 读 pidfile 的进程是否真的还活着，且命令行包含指定字符串
# alive <pidfile> <cmdline-substr>
alive() {
    [ -f "$1" ] || return 1
    _p=$(cat "$1" 2>/dev/null)
    [ -n "$_p" ] || return 1
    [ -d "/proc/$_p" ] || return 1
    _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
    case "$_c" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# 按命令行特征扫描进程，回显第一个匹配的 pid
scan_pid() {
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
        case "$_c" in *"$1"*) echo "${_d#/proc/}"; return 0 ;; esac
    done
    return 1
}

# 统计「孤儿读线程」：ppid=1 且正在读 /dev/ttyOUT2 的 cat
# 这些是浏览器切页/刷新时 lighttpd 杀掉 CGI 后遗留的，会偷吃后续所有响应
count_orphan_readers() {
    _n=0
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
        case "$_c" in *"cat /dev/ttyOUT2"*) ;; *) continue ;; esac
        _pp=$(awk '/^PPid:/{print $2}' "$_d/status" 2>/dev/null)
        [ "$_pp" = "1" ] && _n=$((_n + 1))
    done
    echo "$_n"
}

echo "============================================================"
echo " simcom-webui  AT 桥接自检   $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
echo "============================================================"

# ---------- [1] AT 设备节点 ----------
AT_DEV=""
for d in /dev/smd8 /dev/smd7 /dev/smd11; do
    [ -c "$d" ] && { AT_DEV="$d"; break; }
done
echo "[1] AT 设备节点"
if [ -n "$AT_DEV" ]; then
    ok "$AT_DEV 存在"
else
    bad "smd8/smd7/smd11 都不存在（modem 子系统没起来？）"
fi

# ---------- [2] socat 进程 ----------
echo "[2] socat（PTY 对）"
SOCAT_PID=""
if alive "$RUN_DIR/socat.pid" "socat-armel-static"; then
    SOCAT_PID=$(cat "$RUN_DIR/socat.pid")
    ok "运行中 pid=$SOCAT_PID（看门狗记录）"
elif SOCAT_PID=$(scan_pid "socat-armel-static"); then
    ok "运行中 pid=$SOCAT_PID（扫描到）"
    warn "看门狗 pidfile 缺失（$RUN_DIR/socat.pid）—— 看门狗可能在跑开机自启前被清掉了"
else
    bad "未运行（桥完全没起来）"
fi

# ---------- [3] PTY 节点 ----------
echo "[3] PTY 节点"
if [ -c /dev/ttyIN2 ]; then ok "/dev/ttyIN2"; else bad "/dev/ttyIN2 不存在"; fi
if [ -c /dev/ttyOUT2 ]; then ok "/dev/ttyOUT2"; else bad "/dev/ttyOUT2 不存在（CGI 会 fallback 到 smdX）"; fi

# ---------- [4] 读腿 ----------
echo "[4] 读腿  cat ${AT_DEV:-smdX} > /dev/ttyIN2"
RPID=""
if alive "$RUN_DIR/reader.pid" "cat"; then
    RPID=$(cat "$RUN_DIR/reader.pid"); ok "运行中 pid=$RPID"
elif RPID=$(scan_pid "cat ${AT_DEV:-/dev/smd8}"); then
    ok "运行中 pid=$RPID（扫描到）"
else
    bad "未运行 —— 模块的响应没人搬给桥，所有 AT 都会超时"
fi

# ---------- [5] 写腿 ----------
echo "[5] 写腿  cat /dev/ttyIN2 > ${AT_DEV:-smdX}"
WPID=""
if alive "$RUN_DIR/writer.pid" "cat"; then
    WPID=$(cat "$RUN_DIR/writer.pid"); ok "运行中 pid=$WPID"
elif WPID=$(scan_pid "cat /dev/ttyIN2"); then
    ok "运行中 pid=$WPID（扫描到）"
else
    bad "未运行 —— 命令根本到不了模块，全部 AT 都会超时"
fi

# ---------- [6] 孤儿读线程 ----------
echo "[6] 孤儿读线程（会偷吃响应）"
ORN=$(count_orphan_readers)
if [ "$ORN" = "0" ]; then
    ok "无"
else
    bad "$ORN 个（ppid=1 且读 /dev/ttyOUT2）—— 这就是「全部转圈圈」的直接原因"
    echo "         清理：sh $BRIDGE_DIR/bridge_watchdog.sh --sweep"
fi

# ---------- [7] 真实环回探活 ----------
# 注意：探活要往 AT 口写 "AT"。如果此刻有 CGI 正在用它并读同一个
# /dev/ttyOUT2，我们的 echo/OK 会插进它的响应里把前端解析弄乱。
# 所以这里也抢 CGI 的锁；抢不到就跳过（不算失败）。
echo "[7] 真实环回探活（向 /dev/ttyOUT2 发 AT 等 OK）"
if [ -c /dev/ttyOUT2 ]; then
    if mkdir "$PROBE_LOCK" 2>/dev/null; then
        _PROBE_MINE=1
        # 写时间戳：让 CGI/看门狗的僵尸锁逻辑按 30s 判定，而不是"无 ts"的 10s 快回收
        date +%s > "$PROBE_LOCK/ts" 2>/dev/null
        _f="$RUN_DIR/probe_status.$$"
        mkdir -p "$RUN_DIR" 2>/dev/null
        : > "$_f"
        cat /dev/ttyOUT2 > "$_f" 2>/dev/null &
        _rp=$!
        sleep 0.05
        printf 'AT\r\n' > /dev/ttyOUT2 2>/dev/null
        _i=0; _ok=1
        while [ $_i -lt $((PROBE_TIMEOUT * 10)) ]; do
            if grep -q 'OK' "$_f" 2>/dev/null; then _ok=0; break; fi
            sleep 0.1; _i=$((_i + 1))
        done
        kill $_rp 2>/dev/null; wait $_rp 2>/dev/null
        rm -rf "$PROBE_LOCK" 2>/dev/null
        _PROBE_MINE=0
        if [ $_ok -eq 0 ]; then
            ok "收到 OK（耗时约 $((_i / 10)).$((_i % 10)) s）"
        else
            bad "${PROBE_TIMEOUT}s 内无 OK —— 前 6 项即使都 OK，路也是断的"
            echo "         原始返回：$(tr -d '\r' < "$_f" 2>/dev/null | head -c 200)"
        fi
        rm -f "$_f"
    else
        warn "串口正被 CGI 占用（$PROBE_LOCK 存在），跳过探活以免干扰"
        warn "若持续如此，说明有请求卡住；可 rm -rf $PROBE_LOCK 后重跑本脚本"
    fi
else
    warn "跳过（/dev/ttyOUT2 不存在）"
fi

# ---------- [8] web 侧 AT 心跳（决定看门狗现在会不会主动探活） ----------
# 看门狗不做"每 10s 无脑探活"：它每 10s 只做零开销的部件存活检查，
# 只有当 web 真的在用 AT 而且刚报过错，才去发环回 AT。判据就是这两个文件
# （由 cgi-bin/libat.sh 在每次 AT 往返后写入）。
echo "[8] web 侧 AT 心跳（看门狗按需探活的依据）"
_HB="$RUN_DIR/at_hb"; _HB_S="$RUN_DIR/at_hb_start"
if [ -f "$_HB" ]; then
    read _hb_ts _hb_st < "$_HB" 2>/dev/null
    _now=$(date +%s 2>/dev/null || echo 0)
    _beg=""
    [ -f "$_HB_S" ] && read _beg < "$_HB_S" 2>/dev/null
    if [ -n "$_hb_ts" ] && [ "$_now" != "0" ]; then
        _age=$((_now - _hb_ts))
        # 卡死判定要和看门狗保持一致（开始标记比结果标记新 60s 以上）
        if [ -n "$_beg" ] && [ "$_beg" -gt "$_hb_ts" ] 2>/dev/null && [ $((_now - _beg)) -gt 60 ]; then
            bad "有请求开始 $((_now - _beg))s 却一直没有结果 → 疑似卡死，看门狗会清孤儿并探活"
        elif [ "$_hb_st" = "fail" ] && [ "$_age" -le 120 ]; then
            bad "最近一次 AT 往返超时（${_age}s 前）→ 看门狗会主动介入"
        elif [ "$_age" -le 120 ]; then
            ok "最近 ${_age}s 内有成功的 AT 往返 → web 自身已证明桥是通的（不必额外探活）"
        else
            warn "最近一次 web 使用在 ${_age}s 前 → 静默期：只看部件存活 + 每 300s 兜底探活一次"
        fi
    else
        warn "心跳文件为空（CGI 还没写过）"
    fi
else
    warn "无记录 —— 本次开机还没有 web 用过 AT；看门狗处于静默期兜底模式"
fi

# ---------- [9] 运行时目录落点（确认没在写 NAND） ----------
# 日志、pidfile、心跳、锁、临时文件都在 $AT_RUN_DIR 下。这个目录必须是
# tmpfs/ramfs —— 否则每次 AT 往返的心跳、每个请求的锁戳都会变成 NAND 写入，
# 长期运行会磨损闪存（本模块是 1GB NAND / UBIFS，擦写寿命有限）。
echo "[9] 运行时目录（日志/心跳/锁/临时文件 的落点）"
echo "     $AT_RUN_DIR  (fs=${AT_RUN_FS:-未知})"
if [ "$AT_RUN_IS_RAM" = "1" ]; then
    ok "落在内存文件系统上（每次请求的写入都不会碰 NAND）"
else
    bad "不在内存文件系统上（fs=${AT_RUN_FS:-未知}）—— 写入会落到 NAND！"
    echo "         检查 /proc/mounts 是否有 tmpfs 可用（/run、/dev/shm、/tmp）"
fi
_bd_log="$AT_LOG_DIR"
if [ -d "$_bd_log" ]; then
    echo "     日志目录大小：$(du -sh "$_bd_log" 2>/dev/null | awk '{print $1}')"
fi

echo "------------------------------------------------------------"
if [ "$FAILED" = "0" ]; then
    echo " 结论：桥接正常。"
else
    echo " 结论：桥接异常。修复："
    echo "   sh $BRIDGE_DIR/bridge_watchdog.sh --restart    # 立即重建整桥"
    echo "   sh $BRIDGE_DIR/bridge_watchdog.sh --sweep      # 只清孤儿读线程"
    echo "   看落点：sh $BRIDGE_DIR/bridge_watchdog.sh --rundir"
    echo "   日志：$LOG"
fi
echo "============================================================"
exit $FAILED
