#!/bin/sh
# =====================================================================
# AT 桥接看门狗 (bridge_watchdog.sh)
#
# 为什么需要它：
#   原设计把 AT 通路拆成 3 个互不相关的进程，然后谁都不管谁：
#       socat  创建 PTY 对  /dev/ttyIN2 <-> /dev/ttyOUT2
#       cat    读腿  cat /dev/smd8  > /dev/ttyIN2
#       cat    写腿  cat /dev/ttyIN2 > /dev/smd8
#   任何一条腿因 EIO / ENXIO / SIGHUP / 写失败退出，AT 通路就断了，
#   但 socat 还在 —— 于是 `ps | grep socat` 看着一切正常，网页却全部
#   转圈圈。原来的 `while true; do cat ...; sleep 0.5; done` 还有一个
#   0.5s 的盲区：重启那半秒里模块吐出来的响应会被直接丢掉。
#
# 本脚本负责：
#   1. 用 setsid 启动每个部件，脱离父会话 —— 开机钩子退出时不会被
#      SIGHUP 带走（这是"重启后桥没了"的常见原因）
#   2. 分级巡检 + 按需介入（不做无脑轮询，详见下面「分级检查」一节）：
#        L0  每 10s，纯 shell 内建判活 —— 零进程开销，部件死了立刻知道
#        L1  只在 web 真的在用 AT 且刚报错/卡死时，才发环回 AT 探活
#        （早期版本还有「L2 静默期每 300s 兜底探活」，已删除：看门狗不该在没人
#         用的时候主动占串口，否则会和网页请求抢同一把 AT 锁、拖慢正常请求）
#   3. 连续 2 次异常 → 整桥重建（PTY 重建同时把缓冲里的脏数据清空）
#   4. 顺带清理「孤儿读线程」（见下方 sweep_orphans 注释）
#   5. pidfile 放在「运行时目录」（内存 fs，见 at-runenv.sh），供 bridge_status.sh 查询
#
# ============ 分级检查：为什么不每 10s 探活一次 ============
# 早先的实现是每 10s 「全量扫 /proc + 发一条 AT」，实测开销远大于直觉：
#   · 扫 /proc 时每个 pid 都要起一个 tr 去读 cmdline，模块上 150+ 进程
#     → 每轮 ~150 次 fork，共 15 次/秒持续不断，CPU 无法进空闲；
#   · 每 10s 一条 AT 还要和网页请求抢同一把串口锁（$AT_LOCK，内存 fs），
#     纯粹给正常浏览添延迟；而且没人用网页时，这次探活毫无信息量。
# 现在改成：
#   L0  读 pidfile + /proc/<pid>/comm + 字符设备判断，全部是 shell 内建，
#       一次巡检 0 次 fork —— 覆盖了绝大多数真实故障（某条腿退出）。
#   L1  web 侧心跳（由 cgi-bin/libat.sh 写入 $AT_STATE_DIR/at_hb，内存 fs）
#       · ok 且新鲜 → 「web 的成功请求」本身就是最好的探活，不动串口
#       · fail      → 真出问题了，清孤儿 + 探活 + 必要时重建
#       · 开始标记比结果标记新 60s 以上 → 请求卡死，同上
#   L2  超过 120s 没人用 web → 暂停探活，每 300s 兜底一次，
#       保证「没人用的时候桥坏了，用户一打开也不会踩空」。
#
# 用法：
#   sh bridge_watchdog.sh              # 常驻看门狗（开机自启用这个）
#   sh bridge_watchdog.sh --once       # 单次全量巡检+修复，退出码 0=健康
#   sh bridge_watchdog.sh --restart    # 立刻重建整桥
#   sh bridge_watchdog.sh --sweep      # 只清孤儿读线程
#   sh bridge_watchdog.sh --stop       # 停掉整桥+看门狗
# =====================================================================

BRIDGE_DIR=$(cd "$(dirname "$0")" && pwd)
SOCAT_BIN="$BRIDGE_DIR/socat-armel-static"

# ---------- 运行时目录：只落在内存文件系统上（避免磨损 NAND） ----------
# 日志 / pidfile / 心跳 / 探活临时文件全部放这里。解析逻辑在仓库根目录的
# at-runenv.sh（读 /proc/mounts 判定 fs 类型，只在 tmpfs/ramfs 上建目录），
# CGI 侧 source 的是同一个文件，所以两边看到的锁路径、心跳路径一定一致。
_SIMCOM_RUNENV="$BRIDGE_DIR/../at-runenv.sh"
if [ -f "$_SIMCOM_RUNENV" ]; then
    . "$_SIMCOM_RUNENV"
else
    # 兜底：at-runenv.sh 丢失也要能起来（但不保证是内存目录）
    AT_RUN_DIR=/tmp/simcom-webui
    AT_STATE_DIR="$AT_RUN_DIR/bridge"
    AT_LOG_DIR="$AT_RUN_DIR/log"
    AT_TMP_DIR="$AT_RUN_DIR/tmp"
    AT_LOCK="$AT_RUN_DIR/atcmd.lock"
    AT_RUN_IS_RAM=0
    mkdir -p "$AT_STATE_DIR" "$AT_LOG_DIR" "$AT_TMP_DIR" 2>/dev/null
    TMPDIR="$AT_TMP_DIR"; export TMPDIR
fi
command -v at_log_cap >/dev/null 2>&1 || at_log_cap() { return 0; }

RUN_DIR="$AT_STATE_DIR"
LOG="$AT_LOG_DIR/bridge.log"
AT_HB="$RUN_DIR/at_hb"              # "<epoch> ok|fail"
AT_HB_START="$RUN_DIR/at_hb_start"  # "<epoch>" 请求开始时刻
PID_WD="$RUN_DIR/watchdog.pid"
PID_SOCAT="$RUN_DIR/socat.pid"
PID_READER="$RUN_DIR/reader.pid"
PID_WRITER="$RUN_DIR/writer.pid"

# 手工兜底建 symlink 时记录两个 ptys（pts 编号），供 restart_bridge 在
# 两条腿起来之后用真实探活纠正方向（见 start_socat 的注释）。
MANUAL_PTY_USED=0
MANUAL_PTY_A=""
MANUAL_PTY_B=""

INTERVAL=10          # L0 巡检周期（秒）
FAIL_MAX=2           # 连续失败多少次就整桥重建
PROBE_TIMEOUT=3      # 探活等待上限（秒）

# ---- 按需检查的门控参数 ----
ACTIVE_WINDOW=120    # 心跳新鲜度阈值：小于它 = web 正在用（L1 生效）
STUCK_SEC=60         # 请求开始后超过这么久仍无结果 = 卡死
LOG_ROTATE_EVERY=30  # 每多少个周期检查一次日志轮转（30 × 10s = 5 分钟）

mkdir -p "$RUN_DIR" "$AT_LOG_DIR" 2>/dev/null
chmod 777 "$RUN_DIR" "$AT_LOG_DIR" 2>/dev/null   # CGI 也要往这里写心跳文件

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*" >> "$LOG"
    [ -t 1 ] && echo "$*"
}

# 日志轮转：既按行数也按字节数封顶。
# 为什么必须封顶：LOG 是 append 写法的，一旦某条腿反复掉线（每次重建都写好
# 几行），不封顶就会一直涨。这在 tmpfs 上是吃内存，在 NAND 上是磨闪存 ——
# 两种情况都不许发生。
rotate_log() {
    [ -f "$LOG" ] || return 0
    _n=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    if [ -n "$_n" ] && [ "$_n" -gt 500 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
    at_log_cap "$LOG"      # 字节数兜底（单行超长时行数判断拦不住）
}

# ---------- 进程工具 ----------

# 脱离父会话启动：setsid 存在就用，否则退回 nohup，再否则裸 &
_spawn() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@"
    elif command -v nohup >/dev/null 2>&1; then
        nohup "$@"
    else
        "$@"
    fi
}

# pid 是否存活
_pid_alive() {
    [ -n "$1" ] && [ -d "/proc/$1" ]
}

# 当前时间戳 / 是否纯数字
_ts_now() { date +%s 2>/dev/null || echo 0; }
_isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ---------- L0：零进程开销的存活判定 ----------
# 只用 read（shell 内建）读 pidfile 和 /proc/<pid>/comm，再用 test 判断，
# 全程不起任何子进程 —— 这是"每 10s 巡检"能便宜下来的关键。
# comm 是内核记的可执行文件名（截断到 15 字符），足以区分 socat 和 cat。
#
# 容错：comm 先当"加速通道"用 —— 命中就立刻返回（零子进程）；不命中
# （读不到 / 内核不给 / 名字对不上）再退回 pidfile_alive 按 cmdline 校验，
# 这样绝不会把活着的部件误判成死的（误判会导致无脑重建）。
COMM_OK=""      # "" 未探测；1 可用；0 不可用

_detect_comm() {
    _ct=""
    read _ct < "/proc/$$/comm" 2>/dev/null
    if [ -n "$_ct" ]; then COMM_OK=1; else COMM_OK=0; fi
    log "L0 判活：/proc/<pid>/comm $([ "$COMM_OK" = "1" ] && echo 可用 || echo 不可用)（读到 '$_ct'）"
}

# _alive <pidfile> <comm 前缀> <cmdline 子串>
_alive() {
    [ -f "$1" ] || return 1
    _ap=""
    read _ap < "$1" 2>/dev/null
    [ -n "$_ap" ] || return 1
    [ -d "/proc/$_ap" ] || return 1
    [ -n "$COMM_OK" ] || _detect_comm
    if [ "$COMM_OK" = "1" ]; then
        _anm=""
        read _anm < "/proc/$_ap/comm" 2>/dev/null
        case "$_anm" in "$2"*) return 0 ;; esac
    fi
    pidfile_alive "$1" "$3"
}

# 桥的 3 个部件 + 2 个 PTY 节点都在？（0 = 齐）
cheap_alive() {
    _alive "$PID_SOCAT"  "socat" "socat-armel-static" || return 1
    _alive "$PID_READER" "cat"   "cat /dev/smd"       || return 1
    _alive "$PID_WRITER" "cat"   "cat /dev/ttyIN2"    || return 1
    [ -c /dev/ttyIN2 ] && [ -c /dev/ttyOUT2 ] || return 1
    return 0
}

# ---------- web 侧心跳判读 ----------
# 回显 active / fail / stuck / idle，含义见文件头「分级检查」。
hb_verdict() {
    _v_now=$(_ts_now)
    _v_ts=""; _v_st=""; _v_beg=""
    [ -f "$AT_HB" ] && read _v_ts _v_st < "$AT_HB" 2>/dev/null
    [ -f "$AT_HB_START" ] && read _v_beg < "$AT_HB_START" 2>/dev/null

    # 卡死优先：请求已经开始了，却迟迟没有结果
    if _isnum "$_v_beg"; then
        if _isnum "$_v_ts"; then
            [ "$_v_beg" -gt "$_v_ts" ] && \
                [ $((_v_now - _v_beg)) -gt "$STUCK_SEC" ] && { echo stuck; return 0; }
        elif [ $((_v_now - _v_beg)) -gt "$STUCK_SEC" ]; then
            { echo stuck; return 0; }
        fi
    fi

    _isnum "$_v_ts" || { echo idle; return 0; }
    [ $((_v_now - _v_ts)) -gt "$ACTIVE_WINDOW" ] && { echo idle; return 0; }
    [ "$_v_st" = "fail" ] && { echo fail; return 0; }
    echo active
}

# 探活确认正常后，把心跳改写成"已确认正常"，免得同一条旧记录让看门狗
# 每 10s 反复探活 —— 下一次真实失败会由 CGI 重新写进来。
hb_confirm_ok() {
    printf '%s ok\n' "$(_ts_now)" > "$AT_HB" 2>/dev/null
    : > "$AT_HB_START" 2>/dev/null
    return 0
}

# 重建前后清掉 web 侧旧记录（它已经不能代表重建后的桥了）
hb_reset() {
    : > "$AT_HB" 2>/dev/null
    : > "$AT_HB_START" 2>/dev/null
    return 0
}

# 当前 AT 设备（每次巡检都重新判断：modem 重枚举后节点会变）
pick_at_dev() {
    for d in /dev/smd8 /dev/smd7 /dev/smd11; do
        [ -c "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# 扫描进程：所有关键字都命中才算（busybox 的 ps 不可靠，直接读 /proc）
# scan_pid <kw1> [kw2] [kw3]
scan_pid() {
    _kws="$*"
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
        _hit=1
        for _k in $_kws; do
            case "$_c" in *"$_k"*) ;; *) _hit=0; break ;; esac
        done
        [ "$_hit" = "1" ] && { echo "${_d#/proc/}"; return 0; }
    done
    return 1
}

# 列出所有命中的 pid（scan_pid 只返回第一个；清扫时要"全部"）
# scan_all_pids <kw1> [kw2] ...
scan_all_pids() {
    _kws="$*"
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
        _hit=1
        for _k in $_kws; do
            case "$_c" in *"$_k"*) ;; *) _hit=0; break ;; esac
        done
        [ "$_hit" = "1" ] && echo "${_d#/proc/}"
    done
    return 0
}

# ---------- 解析"真实部件 pid" ----------
# 为什么不能信 `$!`：
#   `_spawn ... &` 里的 _spawn 是个 shell 函数，busybox ash 会**先 fork 一个子
#   shell** 去跑函数体（`$!` 就是它），真正的 socat/cat 是它 setsid 出来的孩子。
#   子 shell 随即退出 → pidfile 里留下一个已死的 pid → L0 每轮都判"部件缺失"
#   → ensure_components 反复补、连续两次失败后整桥重建 —— 实测就是"每 10s
#   重建一次"的 restart storm（socat/pts 编号每轮都变，AT 基本不可用）。
# 解决：按 /proc/<pid>/comm（内核记录的可执行名，精确，不会被子串骗到）+
#   cmdline 附加关键字定位真实 pid；同名多个时取 pid 最大者（= 最近启动的）。
#   注意 comm 会被内核截断到 15 字符，所以 socat 只能按前缀 "socat" 匹配。
#   另一个不能用 scan_pid "cat" "/dev/ttyIN2" 的原因：socat 的 cmdline 里既有
#   "socat"（含子串 "cat"）又有 "/dev/ttyIN2" —— 会把 socat 认成写腿。
resolve_pid() {
    _cm="$1"; _kw="$2"; _best=""
    for _d in /proc/[0-9]*; do
        _p="${_d#/proc/}"
        [ "$_p" = "$$" ] && continue
        [ -r "$_d/comm" ] || continue
        _nm=""; read _nm < "$_d/comm" 2>/dev/null
        case "$_nm" in "$_cm"*) ;; *) continue ;; esac
        if [ -n "$_kw" ]; then
            _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
            case "$_c" in *"$_kw"*) ;; *) continue ;; esac
        fi
        if [ -z "$_best" ] || [ "$_p" -gt "$_best" ] 2>/dev/null; then
            _best="$_p"
        fi
    done
    [ -n "$_best" ] && { echo "$_best"; return 0; }
    return 1
}

# pidfile 里的进程是否仍存活且命令行匹配
pidfile_alive() {
    [ -f "$1" ] || return 1
    _p=$(cat "$1" 2>/dev/null)
    _pid_alive "$_p" || return 1
    _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
    case "$_c" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# ---------- 孤儿读线程清理 ----------
# 现象：网页上所有 AT 全部转圈超时，但 ps 里 socat 好端端的。
#
# 成因：CGI 用后台 `cat /dev/ttyOUT2` 收数据。浏览器切页/刷新/关标签时
#       lighttpd 会杀掉 CGI 主进程，那个后台 cat 被 init 收养（ppid=1）
#       却继续握着 /dev/ttyOUT2 读。PTY 只有一个读队列，谁先读谁拿数据，
#       于是之后每个 CGI 的读线程都读不到自己的响应 —— 表现为"全部无响应"，
#       而且不会自愈，会一直持续到重启。
#
# 判据：ppid=1 且正在读 /dev/ttyOUT2 的 cat = 没人要的孤儿。
# 安全性：桥接的两条腿读的是 /dev/ttyIN2 和 /dev/smdX，从不读 ttyOUT2；
#         正在干活的 CGI 其读线程 ppid 不是 1。所以不会误杀。
#
# 枚举方式（见 _orphan_candidates）：优先读 /proc/1/task/1/children，
# 一次文件读就能拿到 init 的全部子进程，避免逐 pid fork。
# 枚举「孤儿候选」= init(pid 1) 的子进程。
#
# 内核直接给了一份子进程名单（/proc/1/task/1/children），读一次文件就够；
# 不必遍历 /proc 下每个 pid 各起一个 tr 去读 cmdline —— 模块上 150+ 个进程，
# 那样每轮要 fork 150 次，是这套看门狗里最大的一笔开销。
# 内核没编 CONFIG_PROC_CHILDREN 时退回全量扫描。
_orphan_candidates() {
    if [ -r /proc/1/task/1/children ]; then
        cat /proc/1/task/1/children 2>/dev/null
        return 0
    fi
    # 内核未编 CONFIG_PROC_CHILDREN。旧实现遍历 /proc 下每个进程、各自 fork
    # tr+awk（181 进程 ≈ 360 次 fork，实测单次 ~1.7s），fail/stuck 模式下每 10s
    # 一次，会显著抬升 CPU。改用 pgrep 一次性定位孤儿读线程（ppid=1 且 cmdline
    # 含 "cat /dev/ttyOUT2"）。模式必须带空格，不能写 "cat"，否则误命中 socat。
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f -P 1 "cat /dev/ttyOUT2" 2>/dev/null
        return 0
    fi
    # 兜底：没有 pgrep 时退回旧式全量扫描（慢但正确）
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
        case "$_c" in *"/dev/ttyOUT2"*) ;; *) continue ;; esac
        case "$_c" in *"cat"*) ;; *) continue ;; esac
        _pp=$(awk '/^PPid:/{print $2}' "$_d/status" 2>/dev/null)
        [ "$_pp" = "1" ] && echo "${_d#/proc/}"
    done
    return 0
}

sweep_orphans() {
    _n=0
    for _op in $(_orphan_candidates); do
        _ocf="/proc/$_op/cmdline"
        [ -r "$_ocf" ] || continue
        _c=$(tr '\0' ' ' < "$_ocf" 2>/dev/null)
        case "$_c" in *"/dev/ttyOUT2"*) ;; *) continue ;; esac
        case "$_c" in *"cat"*) ;; *) continue ;; esac
        kill -9 "$_op" 2>/dev/null && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && log "sweep: 清理孤儿读线程 $_n 个"
    return 0
}

# ---------- 起 socat ----------
start_socat() {
    rm -f /dev/ttyIN2 /dev/ttyOUT2 2>/dev/null
    _spawn "$SOCAT_BIN" -d -d \
        pty,link=/dev/ttyIN2,raw,echo=0,group=20,perm=660 \
        pty,link=/dev/ttyOUT2,raw,echo=0,group=20,perm=660 \
        >> "$LOG" 2>&1 &
    sleep 0.4
    # 不能信 $!（那是 ash 为跑 _spawn 函数而 fork 的子 shell，随后就退出）。
    # 始终按 comm=前缀socat + cmdline 含 socat-armel-static 找真实进程。
    _pid=$(resolve_pid socat socat-armel-static)
    [ -z "$_pid" ] && _pid=$(scan_pid "socat-armel-static")
    if [ -z "$_pid" ]; then
        log "socat 启动失败：进程没起来"
        return 1
    fi
    echo "$_pid" > "$PID_SOCAT"

    # 等 PTY 节点出现（最多 5s）
    _i=0
    while [ $_i -lt 50 ]; do
        [ -c /dev/ttyIN2 ] && [ -c /dev/ttyOUT2 ] && {
            log "socat 就绪 pid=$_pid"
            return 0
        }
        sleep 0.1
        _i=$((_i + 1))
    done

    # ------------------------------------------------------------------
    # 兜底：本平台的 socat-armel-static 是静态交叉编译的，实测 pty,link=
    # 选项**可能被静默忽略** —— socat 起来了、两个 pts 也建好了，就是不建
    # /dev/ttyIN2 与 /dev/ttyOUT2 这两个 symlink。这时直接从 socat 进程的
    # /proc/<pid>/fd 把两个 pts 捞出来手工建 symlink。
    #
    # 关键：这一步**绝不能用探活去判定方向**。此刻两条搬运腿还没起来
    # （restart_bridge 的顺序是先 start_socat 再 start_leg），探活必然超时；
    # 拿"超时"当"接反了"去交换，只会把方向随机弄反（= 自环）。
    # 这里改用确定性规则：pts 编号升序，小的给 ttyIN2、大的给 ttyOUT2。
    # 若这样仍不通，由 restart_bridge 在两条腿起来之后用真实探活纠正
    # （那里会交换 MANUAL_PTY_A/B 并重开双腿再探）。
    # ------------------------------------------------------------------
    if [ ! -c /dev/ttyOUT2 ] && [ -d "/proc/$_pid/fd" ]; then
        log "socat 未创建 PTY 节点（link= 被忽略？）→ 从 /proc/$_pid/fd 手工建立"
        _ptys=$(ls -l "/proc/$_pid/fd/" 2>/dev/null \
                | awk '$NF ~ /^\/dev\/pts\// { print $NF }' \
                | sort -u -t/ -k4 -n)
        _pty1=$(echo "$_ptys" | sed -n '1p')
        _pty2=$(echo "$_ptys" | sed -n '2p')
        if [ -n "$_pty1" ] && [ -n "$_pty2" ] && [ "$_pty1" != "$_pty2" ]; then
            ln -sf "$_pty1" /dev/ttyIN2
            ln -sf "$_pty2" /dev/ttyOUT2
            MANUAL_PTY_A="$_pty1"
            MANUAL_PTY_B="$_pty2"
            MANUAL_PTY_USED=1
            log "手工建立： /dev/ttyIN2 -> $_pty1  /dev/ttyOUT2 -> $_pty2"
        else
            log "从 /proc/$_pid/fd 解析 pts 失败（得到 '$_ptys'）"
        fi
    fi

    if [ -c /dev/ttyIN2 ] && [ -c /dev/ttyOUT2 ]; then
        log "socat 就绪（手工兜底）pid=$_pid"
        return 0
    fi
    log "socat 启动失败：/dev/ttyIN2 或 /dev/ttyOUT2 始终未出现"
    return 1
}

# ---------- 起搬运腿 ----------
# kind: r = 读腿 cat <smdX> > /dev/ttyIN2
#       w = 写腿 cat /dev/ttyIN2 > <smdX>
start_leg() {
    _kind="$1"; _dev="$2"
    case "$_kind" in
        r) _spawn cat "$_dev" > /dev/ttyIN2 2>/dev/null &
           _pf="$PID_READER"; _kw="$_dev" ;;
        w) _spawn cat /dev/ttyIN2 > "$_dev" 2>/dev/null &
           _pf="$PID_WRITER"; _kw="/dev/ttyIN2" ;;
        *) return 1 ;;
    esac
    sleep 0.3
    # 同样不能信 $!（见 resolve_pid 注释）。按 comm=cat + cmdline 关键字找真实 cat：
    # socat 的 comm 不是 "cat"，所以不会被误认成腿；CGI 的 cat 读的是 ttyOUT2，
    # 关键字是 ttyIN2/smdX，也不会撞上。
    _pid=$(resolve_pid cat "$_kw")
    [ -z "$_pid" ] && _pid=$(scan_pid "cat" "$_kw")
    if [ -n "$_pid" ]; then
        echo "$_pid" > "$_pf"
    elif [ "$_kind" = "r" ]; then
        _pid=$(scan_pid "cat" "$_dev")
        [ -n "$_pid" ] && echo "$_pid" > "$_pf"
    else
        _pid=$(scan_pid "cat" "/dev/ttyIN2")
        [ -n "$_pid" ] && echo "$_pid" > "$_pf"
    fi
    _pid_alive "$_pid" && return 0
    log "${_kind}腿启动失败（dev=$_dev）"
    return 1
}

# ---------- 与 systemd 三件套互斥 ----------
# install.sh 会尝试用 socat-smd8.service + socat-smd8-to/from-ttyIN2.service
# 来拉起同一套东西。如果它们和看门狗同时生效，会出现两个 socat 抢
# /dev/ttyIN2（谁后建谁覆盖 symlink），表现为"有时候通、有时候全挂"。
# 看门狗是唯一的 owner，所以启动时把旧单元停掉；失败一律忽略。
disarm_systemd_units() {
    command -v systemctl >/dev/null 2>&1 || return 0
    for u in \
        socat-smd8.service socat-smd8-to-ttyIN2.service socat-smd8-from-ttyIN2.service \
        socat-smd7.service socat-smd7-to-ttyIN2.service socat-smd7-from-ttyIN2.service \
        socat-smd11.service socat-smd11-to-ttyIN2.service socat-smd11-from-ttyIN2.service
    do
        if systemctl is-active "$u" >/dev/null 2>&1; then
            systemctl stop "$u" >/dev/null 2>&1
            systemctl disable "$u" >/dev/null 2>&1
            log "已停用与看门狗冲突的 systemd 单元：$u"
        fi
    done
    return 0
}

# ---------- 清理"老版"桥接残留 ----------
# 旧版 start_socat_bridge.sh 用
#   ( while true; do cat $AT_DEV > /dev/ttyIN2; sleep 0.5; done ) &
# 拉起两条腿，然后自己就退出了 —— 这些循环子 shell 被 init 收养（ppid=1），
# 却仍然握着 /dev/smd8。部署新版后如果不杀掉它们，就会和看门狗的腿
# 抢读同一个 AT 口，数据被随机瓜分，表现为"时通时不通"。
#
# 实战补丁：旧版的**读腿** `cat /dev/smd8` 是启动器 fork 出来的孩子
# （ppid 是启动器而不是 1），只按 "start_socat_bridge.sh" 匹配杀不到它。
# 而它恰恰是"抢读 AT 口"的那一个 —— 必须一起清掉。判据：cmdline 里出现
# `cat /dev/smd`。
#
# ⚠️ 但必须**放行我们自己 pidfile 里记录的部件**：`run_daemon` 启动时也会调
# 本函数，而它前面刚由 `--restart` 拉起过一整套部件（pidfile 记得好好的）。
# 不放行就会把自家读腿当"旧版残留"杀掉 → 下一轮 L0 又判"读腿缺失"→ 补一条，
# 而旧的那条往往还没死透 → **两条 `cat /dev/smd8` 抢读，AT 直接不可用**。
kill_legacy_bridge() {
    # 收集我们自己部件的 pid，稍后放行
    _own=" "
    for _pf in "$PID_READER" "$PID_WRITER" "$PID_SOCAT"; do
        [ -f "$_pf" ] || continue
        _v=$(cat "$_pf" 2>/dev/null)
        case "$_v" in ''|*[!0-9]*) ;; *) _own="$_own$_v " ;; esac
    done
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _p="${_d#/proc/}"
        [ "$_p" = "$$" ] && continue
        case "$_own" in *" $_p "*) continue ;; esac
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
        case "$_c" in
            *"start_socat_bridge.sh"*)
                # 旧版启动器/它的循环子 shell：只杀 ppid=1 的，
                # 活着的启动器不动（否则会误杀正在跑 --restart 的调用方父进程）
                _pp=$(awk '/^PPid:/{print $2}' "$_d/status" 2>/dev/null)
                [ "$_pp" = "1" ] || continue
                kill -9 "$_p" 2>/dev/null && log "清理旧版桥接循环子 shell pid=$_p"
                ;;
            *"cat /dev/smd"*)
                kill -9 "$_p" 2>/dev/null && log "清理旧版读腿 pid=$_p ($_c)"
                ;;
        esac
    done
    return 0
}

# _kill_pidfile <pidfile> [cmdline 关键字]
# 关键字用来防「pid 复用误杀」：pidfile 里的 pid 可能早已退出，并且被内核
# 复用给了一个完全无关的进程；这时只凭 /proc/<pid> 存在就 kill -9 会误杀它。
_kill_pidfile() {
    [ -f "$1" ] || return 0
    _p=$(cat "$1" 2>/dev/null)
    if _pid_alive "$_p"; then
        if [ -z "$2" ]; then
            kill -9 "$_p" 2>/dev/null
        else
            _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
            case "$_c" in
                *"$2"*) kill -9 "$_p" 2>/dev/null ;;
            esac
        fi
    fi
    rm -f "$1"
    return 0
}

# ---------- 整桥重启 ----------
restart_bridge() {
    log "==> 整桥重建"
    disarm_systemd_units
    # 先按 pidfile 精确回收「我们自己的」部件（日志干净、不会误伤），
    # 再做广谱清扫（旧版残留）。顺序反了会把自家腿当成"旧版读腿"记一笔。
    _kill_pidfile "$PID_READER" "cat"
    _kill_pidfile "$PID_WRITER" "cat"
    _kill_pidfile "$PID_SOCAT" "socat-armel-static"
    kill_legacy_bridge
    # 兜底：按特征再扫一遍，防止 pidfile 丢失后的残党
    # （必须排在 start_socat/start_leg 之前，否则会杀掉刚起的腿）
    for _pat in "cat /dev/ttyIN2" "cat /dev/smd" "socat-armel-static"; do
        for _p in $(scan_all_pids $_pat); do
            kill -9 "$_p" 2>/dev/null
        done
    done
    sleep 0.5
    # 再扫一遍：清掉上一轮里"刚被 kill、但还没被 init 收尸"的漏网者
    for _pat in "cat /dev/ttyIN2" "cat /dev/smd" "socat-armel-static"; do
        for _p in $(scan_all_pids $_pat); do
            kill -9 "$_p" 2>/dev/null
        done
    done

    _dev=$(pick_at_dev) || _dev=""
    if [ -z "$_dev" ]; then
        log "无 AT 设备（smd8/smd7/smd11），稍后重试"
        return 1
    fi
    MANUAL_PTY_USED=0
    start_socat || return 1
    start_leg r "$_dev"
    start_leg w "$_dev"
    sweep_orphans
    hb_reset                    # 旧心跳不再代表重建后的桥
    probe_safe
    _pr=$?
    # 只有在「手工兜底建 symlink」时才可能方向接反（fd 顺序无保证，= 自环）。
    # 此时两条腿都已起来，探活结果才有意义：不通就交换 pts、重开双腿再探一次。
    # 正常路径（socat 的 link= 生效）不需要、也不应该做这个交换。
    if [ "$_pr" = "1" ] && [ "$MANUAL_PTY_USED" = "1" ] && [ -n "$MANUAL_PTY_A" ]; then
        log "手工 symlink 方向疑似接反（探活不通）→ 交换 ttyIN2/ttyOUT2 并重开双腿"
        ln -sf "$MANUAL_PTY_B" /dev/ttyIN2
        ln -sf "$MANUAL_PTY_A" /dev/ttyOUT2
        _kill_pidfile "$PID_READER" "cat"
        _kill_pidfile "$PID_WRITER" "cat"
        start_leg r "$_dev"
        start_leg w "$_dev"
        probe_safe
        _pr=$?
        [ "$_pr" = "0" ] && log "交换后探活通过（ttyIN2 -> $MANUAL_PTY_B / ttyOUT2 -> $MANUAL_PTY_A）"
    fi
    if [ "$_pr" = "0" ]; then
        hb_confirm_ok           # 刚实测通，直接记成"已确认正常"，避免下一轮又探
        log "整桥重建成功（dev=$_dev）"
        return 0
    fi
    if [ "$_pr" = "2" ]; then
        log "整桥重建完成，但 CGI 正占用串口，本轮跳过探活（dev=$_dev）"
        return 0
    fi
    log "整桥重建后探活仍失败"
    return 1
}

# ---------- 真实环回探活 ----------
# 往 /dev/ttyOUT2 发一个 AT，能在 PROBE_TIMEOUT 内收回 OK 才算通
probe() {
    [ -c /dev/ttyOUT2 ] || return 1
    _f="$RUN_DIR/probe.$$"
    : > "$_f"
    cat /dev/ttyOUT2 > "$_f" 2>/dev/null &
    _rp=$!
    sleep 0.05
    printf 'AT\r\n' > /dev/ttyOUT2 2>/dev/null
    _i=0; _ok=1
    while [ $_i -lt $((PROBE_TIMEOUT * 10)) ]; do
        if grep -q 'OK' "$_f" 2>/dev/null; then _ok=0; break; fi
        sleep 0.1
        _i=$((_i + 1))
    done
    kill $_rp 2>/dev/null
    wait $_rp 2>/dev/null
    rm -f "$_f"
    return $_ok
}

# ---------- 带锁探活 ----------
# 探活要往 AT 口写 "AT"，如果此刻某个 CGI 正在跑（它读的是同一个
# /dev/ttyOUT2），我们这条 AT 的 echo/OK 会插进它的响应里，导致前端解析错乱。
# 所以探活必须和 CGI 抢同一把锁（路径由 at-runenv.sh 统一解析，两边一致）：
#   返回 0 = 通  1 = 不通  2 = 锁被占用（跳过本轮，不算失败）
PROBE_LOCK="$AT_LOCK"
probe_safe() {
    if ! mkdir "$PROBE_LOCK" 2>/dev/null; then
        # 僵尸锁兜底：超过 30s 没人释放就强行回收再试一次
        _old=$(cat "$PROBE_LOCK/ts" 2>/dev/null)
        _now=$(date +%s 2>/dev/null || echo 0)
        _stale=0
        if [ -n "$_old" ] && [ "$_now" != "0" ] && [ $((_now - _old)) -gt 30 ]; then
            _stale=1
        elif [ -z "$_old" ]; then
            # ts 缺失：正常持锁流程是「mkdir 后立刻写 ts」，所以缺 ts = 持有者
            # 死在中间。用锁目录自身的 mtime 估算年龄。若本平台 date 不支持 -r，
            # 就只跳过本轮（不算失败）—— CGI 侧 10s 内会回收它，这里不必冒险抢锁。
            _dm=$(date -r "$PROBE_LOCK" +%s 2>/dev/null)
            [ -n "$_dm" ] && [ "$_now" != "0" ] && [ $((_now - _dm)) -gt 30 ] && _stale=1
        fi
        if [ "$_stale" = "1" ]; then
            rm -rf "$PROBE_LOCK" 2>/dev/null
            mkdir "$PROBE_LOCK" 2>/dev/null || return 2
        else
            return 2
        fi
    fi
    echo "$(date +%s 2>/dev/null)" > "$PROBE_LOCK/ts"
    probe
    _rc=$?
    rm -rf "$PROBE_LOCK" 2>/dev/null
    return $_rc
}

# ---------- 健康判定（全量：判活 + 探活） ----------
# 用于 --once / --status 这类人工诊断，以及 L1/L2 需要探活时。
# 返回 0 = 健康；1 = 不健康（回显原因）；2 = CGI 正占用串口，本轮跳过
health_check() {
    _dev=$(pick_at_dev) || _dev=""
    [ -n "$_dev" ] || { echo "no AT device"; return 1; }

    _alive "$PID_SOCAT" "socat" "socat-armel-static" || { echo "socat 不在"; return 1; }
    [ -c /dev/ttyIN2 ] && [ -c /dev/ttyOUT2 ] || { echo "PTY 节点缺失"; return 1; }
    _alive "$PID_READER" "cat" "cat /dev/smd" || { echo "读腿不在"; return 1; }
    _alive "$PID_WRITER" "cat" "cat /dev/ttyIN2" || { echo "写腿不在"; return 1; }

    probe_safe
    _pr=$?
    [ "$_pr" = "2" ] && return 2
    [ "$_pr" = "0" ] || { echo "环回探活无响应"; return 1; }
    return 0
}

# ---------- 按需介入：探活 + 记账 + 必要时重建 ----------
# 只在「web 侧 AT 超时(fail)/卡死(stuck)」时调用，不在每个巡检周期都调，
# 也不做静默期兜底 —— watchdog 不主动占串口，只在网页请求确实异常时介入。
# 返回 0 = 确认健康（或本轮被 CGI 占用而无结论）；1 = 探活失败
verify_bridge() {
    _vr_reason="$1"
    probe_safe
    _vr=$?
    case "$_vr" in
        0)
            _probe_fails=0
            hb_confirm_ok          # 已实测正常，清掉 web 侧那条旧告警
            return 0
            ;;
        2)
            # CGI 正占用串口：不下结论（既不算好也不算坏），留到下一轮
            return 0
            ;;
    esac
    hb_reset
    _probe_fails=$((_probe_fails + 1))
    log "环回探活无响应（触发原因：$_vr_reason）$_probe_fails/$FAIL_MAX"
    if [ "$_probe_fails" -ge "$FAIL_MAX" ]; then
        restart_bridge
        _probe_fails=0
    fi
    return 1
}

# ---------- 确保部件都在（不重建，缺谁补谁） ----------
# 注意：判"缺失"后先 `sleep 0.5` **复核一次**再动手。
# 实测踩过坑：刚 `--restart` 出一整套部件、把 pidfile 写下去的瞬间，或某个进程
# 刚被 kill、pidfile 尚未来得及更新时，_alive 会读到"瞬态缺失"。若立刻 start_leg，
# 就变成"旧腿还没死透 + 新腿已起来" → 两条 `cat /dev/smd8` 抢读 → AT 反而不可用。
# 复核一次几乎零成本，却能滤掉这类瞬态。
ensure_components() {
    _dev=$(pick_at_dev) || return 1

    if ! _alive "$PID_SOCAT" "socat" "socat-armel-static"; then
        sleep 0.5
        if _alive "$PID_SOCAT" "socat" "socat-armel-static"; then
            log "socat 判活瞬态波动 → 复核后仍在，跳过重建"
        else
            log "socat 缺失 → 重启"
            start_socat || return 1
            # socat 重建后 PTY 是新的，两条腿必须跟着重开
            _kill_pidfile "$PID_READER" "cat"
            _kill_pidfile "$PID_WRITER" "cat"
        fi
    fi

    if ! _alive "$PID_READER" "cat" "cat /dev/smd"; then
        sleep 0.5
        if _alive "$PID_READER" "cat" "cat /dev/smd"; then
            log "读腿判活瞬态波动 → 复核后仍在，跳过重建"
        else
            log "读腿缺失 → 重启"
            start_leg r "$_dev"
        fi
    fi
    if ! _alive "$PID_WRITER" "cat" "cat /dev/ttyIN2"; then
        sleep 0.5
        if _alive "$PID_WRITER" "cat" "cat /dev/ttyIN2"; then
            log "写腿判活瞬态波动 → 复核后仍在，跳过重建"
        else
            log "写腿缺失 → 重启"
            start_leg w "$_dev"
        fi
    fi
    return 0
}

# ---------- 常驻模式 ----------
run_daemon() {
    echo $$ > "$PID_WD"
    log "看门狗启动 pid=$$  安装目录=$BRIDGE_DIR"
    log "  分级检查：L0 每 ${INTERVAL}s（零开销判活）/ L1 仅 web 侧超时或卡死时探活"
    log "  运行目录：$AT_RUN_DIR (fs=${AT_RUN_FS:-未知} 内存=$AT_RUN_IS_RAM)"
    if [ "$AT_RUN_IS_RAM" != "1" ]; then
        log "  !! 警告：运行目录不在内存文件系统上（fs=${AT_RUN_FS:-未知}）"
        log "     日志/心跳/临时文件的写入会落到 NAND，长期运行会磨损闪存。"
        log "     可检查 /proc/mounts 是否有可用的 tmpfs（如 /run、/dev/shm）。"
    fi
    disarm_systemd_units
    kill_legacy_bridge

    # 等 AT 设备就绪（开机时 post_boot 可能跑在 /dev/smdX 出现之前）
    _i=0
    while [ $_i -lt 60 ]; do
        [ -n "$(pick_at_dev)" ] && break
        sleep 1
        _i=$((_i + 1))
    done

    ensure_components || restart_bridge
    hb_reset
    _l0_fails=0        # L0「部件存活」连续失败计数
    _probe_fails=0     # 环回探活连续失败计数（与 L0 分开，互不冲掉）
    _cycle=0
    _prev_mode=""

    while true; do
        _cycle=$((_cycle + 1))
        [ $((_cycle % LOG_ROTATE_EVERY)) -eq 0 ] && rotate_log

        # ---------- L0：零进程开销的存活检查（每个周期都做） ----------
        # 只读 pidfile + /proc/<pid>/comm + 判断字符设备，全是 shell 内建。
        # 这一层覆盖了绝大多数真实故障（某条腿退出 / PTY 节点消失）。
        if ! cheap_alive; then
            _l0_fails=$((_l0_fails + 1))
            log "L0 存活检查失败 $_l0_fails/$FAIL_MAX：部件或 PTY 节点缺失"
            if [ "$_l0_fails" -ge "$FAIL_MAX" ]; then
                restart_bridge
                _l0_fails=0
            else
                ensure_components
            fi
            sleep "$INTERVAL"
            continue
        fi
        _l0_fails=0        # L0 通过即清计数（保证只统计"连续"失败）

        # ---------- L1 / L2：按需介入（默认不动串口） ----------
        _mode=$(hb_verdict)
        if [ "$_mode" != "$_prev_mode" ]; then
            log "检查模式：${_prev_mode:-启动} → $_mode"
            _prev_mode="$_mode"
        fi

        case "$_mode" in
            active)
                # web 的成功往返已经是活体证明 —— 一次串口都不碰，
                # 也就不会和网页请求抢同一把串口锁($AT_LOCK)
                _probe_fails=0
                ;;
            fail)
                # 只在第一次尝试时打日志；若串口正被 CGI 占用会连续几轮，
                # 不必每轮重复刷同样的行
                [ "$_probe_fails" = "0" ] && log "web 侧 AT 往返超时 → 清孤儿读线程并探活"
                sweep_orphans
                verify_bridge "web 侧超时" || true
                ;;
            stuck)
                [ "$_probe_fails" = "0" ] && log "web 请求卡死（开始 ${STUCK_SEC}s 内无结果）→ 清孤儿读线程并探活"
                sweep_orphans
                verify_bridge "请求卡死" || true
                ;;
            *)
                # idle：没人用 web 就不碰串口。AT 探活只在 web 侧真的
                # 超时(fail)/卡死(stuck)时才做（见上两个分支），不做静默期
                # 周期性兜底 —— 避免 watchdog 主动占串口、与网页请求抢锁。
                ;;
        esac

        sleep "$INTERVAL"
    done
}

# ---------- 停桥 ----------
stop_bridge() {
    _kill_pidfile "$PID_WD" "bridge_watchdog.sh"
    _kill_pidfile "$PID_READER" "cat"
    _kill_pidfile "$PID_WRITER" "cat"
    _kill_pidfile "$PID_SOCAT" "socat-armel-static"
    for _pat in "cat /dev/ttyIN2" "socat-armel-static" "bridge_watchdog.sh"; do
        for _p in $(scan_pid "$_pat"); do kill -9 "$_p" 2>/dev/null; done
    done
    rm -f /dev/ttyIN2 /dev/ttyOUT2 2>/dev/null
    hb_reset
    log "桥接已停止"
    return 0
}

# ---------- 入口 ----------
case "$1" in
    --once)
        sweep_orphans
        ensure_components || restart_bridge
        echo "运行目录：$AT_RUN_DIR (fs=${AT_RUN_FS:-未知} 内存=$AT_RUN_IS_RAM)"
        echo "web 侧心跳判读：$(hb_verdict)   [active=web 在用且正常 / fail=刚超时 / stuck=请求卡死 / idle=近期没人用]"
        if ! cheap_alive; then
            echo "unhealthy: 部件或 PTY 节点缺失"
            exit 1
        fi
        _r=$(health_check)
        _hr=$?
        if [ "$_hr" = "0" ]; then
            echo "healthy"
            exit 0
        elif [ "$_hr" = "2" ]; then
            echo "busy（有 CGI 正在用串口，本轮跳过探活）"
            exit 0
        else
            echo "unhealthy: $_r"
            exit 1
        fi
        ;;
    --restart)
        restart_bridge
        exit $?
        ;;
    --sweep)
        sweep_orphans
        exit 0
        ;;
    --stop)
        stop_bridge
        exit 0
        ;;
    --status)
        health_check; exit $?
        ;;
    --rundir)
        # 诊断用：确认日志/心跳/临时文件到底写在哪个文件系统上（有没有落在 NAND）
        echo "运行目录   : $AT_RUN_DIR"
        echo "状态/心跳  : $RUN_DIR"
        echo "日志目录   : $AT_LOG_DIR"
        echo "临时文件   : $AT_TMP_DIR"
        echo "串口互斥锁 : $AT_LOCK"
        echo "文件系统   : ${AT_RUN_FS:-未知}"
        echo "在内存上   : $AT_RUN_IS_RAM  (1=是，0=否——会写 NAND！)"
        ;;
    ""|--daemon)
        # 幂等：已有看门狗在跑就不再起第二个
        if pidfile_alive "$PID_WD" "bridge_watchdog.sh"; then
            log "看门狗已在运行（pid=$(cat $PID_WD)），退出"
            exit 0
        fi
        run_daemon
        ;;
    *)
        echo "用法: $0 [--daemon|--once|--restart|--sweep|--stop|--status|--rundir]"
        exit 2
        ;;
esac
