#!/bin/sh
# =====================================================================
# Simcom WebUI - AT 通信公共库
# 供 atcmd / sms 两个 CGI 共享：设备探测、原子锁、清缓冲、发命令
# 并向看门狗上报 web 侧 AT 心跳（供其按需介入，见下面 at_heartbeat 注释）
#
# 用法：CGI 开头 . /path/to/libat.sh （注意不是下划线开头，确保有权限）
# =====================================================================

# ---------- 运行时目录（只落在内存 fs 上，避免磨损 NAND） ----------
# 提供 $AT_RUN_DIR / $AT_STATE_DIR / $AT_LOG_DIR / $AT_TMP_DIR / $AT_LOCK
# 以及 AT_RUN_IS_RAM（0 = 没找到内存 fs，退到了 /tmp）。
# 本文件被每个请求 source，所以它只做 1 个 awk + 几个 mkdir，且不打印任何东西。
_SIMCOM_RUNENV="$(dirname "$0")/../at-runenv.sh"
if [ -f "$_SIMCOM_RUNENV" ]; then
    . "$_SIMCOM_RUNENV"
else
    # 兜底：at-runenv.sh 丢失时仍然要能工作（但不保证是内存目录）
    AT_RUN_DIR=/tmp/simcom-webui
    AT_STATE_DIR="$AT_RUN_DIR/bridge"
    AT_LOG_DIR="$AT_RUN_DIR/log"
    AT_TMP_DIR="$AT_RUN_DIR/tmp"
    AT_LOCK="$AT_RUN_DIR/atcmd.lock"
    AT_RUN_IS_RAM=0
    mkdir -p "$AT_STATE_DIR" "$AT_LOG_DIR" "$AT_TMP_DIR" 2>/dev/null
    TMPDIR="$AT_TMP_DIR"; export TMPDIR
fi
# 日志封顶（at-runenv.sh 里定义；有兜底则此处补一个空实现）
command -v at_log_cap >/dev/null 2>&1 || at_log_cap() { return 0; }

# ---------- URL 解码 ----------
# 注意：不要在 urldecode 里把 + 转成空格！
# AT 命令本身含大量 +（如 AT+CSQ），URL 里它是 %2B 编码。
# 我们在 CGI 场景用 GET + QUERY_STRING，命令里的 + 是原样传入（encodeURIComponent 会编码成 %2B）。
# 若把 + 当空格，AT+CSQ 会变成 AT CSQ → 模块返回 ERROR。
urldecode() {
    printf '%b' "$(printf '%s' "$1" | sed 's/%\(..\)/\\x\1/g')"
}

# ---------- 文本编码工具（短信 UCS2 通路用） ----------
# 设备自带的 busybox 没有 iconv，故用 od + awk 手工解码 UTF-8 码点，
# 再输出 UTF-16BE 的大端十六进制串（UCS2 模式 AT 命令要求的格式）。
# 支持 1~4 字节 UTF-8，含 BMP 之外字符（emoji 会拆成代理对）。
#
# 例：utf8_to_ucs2hex "中文"  → 4E2D6587
utf8_to_ucs2hex() {
    printf '%s' "$1" | od -An -tu1 | awk '
        { for (i=1;i<=NF;i++) b[++n]=$i+0 }
        END {
            i=1
            while (i<=n) {
                c=b[i]
                if (c<128)        { cp=c; i+=1 }
                else if (c<224)   { cp=(c-192)*64 + (b[i+1]-128); i+=2 }
                else if (c<240)   { cp=(c-224)*4096 + (b[i+1]-128)*64 + (b[i+2]-128); i+=3 }
                else              { cp=(c-240)*262144 + (b[i+1]-128)*4096 + (b[i+2]-128)*64 + (b[i+3]-128); i+=4 }
                if (cp<=65535) out = out sprintf("%04X", cp)
                else { c2=cp-65536; out = out sprintf("%04X%04X", 55296+int(c2/1024), 56320+(c2%1024)) }
            }
            print out
        }'
}

# 判断字符串是否为纯 ASCII（含 GSM 7-bit 可直接发送的字符）。
# 返回 0 = 纯 ASCII；非 0 = 含非 ASCII（中文等），需走 UCS2 通路。
is_ascii_text() {
    printf '%s' "$1" | od -An -tu1 | awk '{for(i=1;i<=NF;i++) if($i>127) f=1} END{exit f?1:0}'
}

# ---------- AT 设备探测 ----------
# 优先 socat 桥接（/dev/ttyOUT2），其次直连 smd8（不与 USB AT 口冲突）
find_at_device() {
    for dev in /dev/ttyOUT2 /dev/smd8 /dev/smd7 /dev/smd11; do
        [ -c "$dev" ] && { echo "$dev"; return 0; }
    done
    return 1
}

# ---------- 被中断的 CGI 会留下「孤儿读线程」 ----------
# 症状：网页上所有 AT 命令全部转圈超时，但 socat 进程看着好好的。
#
# 成因：send_at / flush_at_buffer 用后台 `cat <dev>` 收数据。浏览器切页 /
#   刷新 / 关闭标签，或自动刷新被关掉那一刻正好有请求在飞，都会让 lighttpd
#   直接杀掉 CGI 主进程；后台那个 cat 被 init 收养（ppid=1）却继续握着
#   /dev/ttyOUT2 读。PTY 只有一个读队列 —— 谁先读谁拿到数据，于是之后每个
#   CGI 的读线程都读不到自己的响应，表现为「全部无响应」，而且不会自愈，
#   会一直持续到重启（这正是「有时候 web 上 AT 全部转圈圈」的直接原因）。
#
# 判据：ppid=1 且正在读 /dev/ttyOUT2 的 cat = 没人要的孤儿。
# 安全性：桥接自身的两条腿读的是 /dev/ttyIN2 和 /dev/smdX，从不读
#   /dev/ttyOUT2；活着的 CGI 其读线程 ppid 不是 1。所以不会误杀。
# 枚举「孤儿候选」= init(pid 1) 的子进程。
#
# 内核直接给了一份子进程名单（/proc/1/task/1/children），读一次文件就够；
# 不必遍历 /proc 下每个 pid 各起一个 tr 去读 cmdline —— 模块上有 150+ 个
# 进程，那样每清理一次就要 fork 150 次。这个函数在每次拿锁时都会被调用，
# 所以必须便宜。内核没编 CONFIG_PROC_CHILDREN 时退回全量扫描。
_orphan_candidates() {
    if [ -r /proc/1/task/1/children ]; then
        cat /proc/1/task/1/children 2>/dev/null
        return 0
    fi
    # 内核未编 CONFIG_PROC_CHILDREN。旧实现遍历 /proc 下每个进程、各自 fork
    # tr+awk（181 进程 ≈ 360 次 fork，实测单次 ~1.7s）——这是「页面刷新 CPU 100%」
    # 的直接元凶。改用 pgrep 一次性定位孤儿读线程（ppid=1 且 cmdline 含
    # "cat /dev/ttyOUT2"）。模式必须带空格 "cat /dev/ttyOUT2"，不能写 "cat"，
    # 否则会误命中 socat（"socat" 含 "cat" 子串，且其 cmdline 有 pty,link=/dev/ttyOUT2）。
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f -P 1 "cat /dev/ttyOUT2" 2>/dev/null
        return 0
    fi
    # 兜底：没有 pgrep 时退回旧式全量扫描（慢但正确，极少数固件才会走到这）
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

sweep_orphan_readers() {
    for _op in $(_orphan_candidates); do
        _ocf="/proc/$_op/cmdline"
        [ -r "$_ocf" ] || continue
        _c=$(tr '\0' ' ' < "$_ocf" 2>/dev/null)
        case "$_c" in *"/dev/ttyOUT2"*) ;; *) continue ;; esac
        case "$_c" in *"cat"*) ;; *) continue ;; esac
        kill -9 "$_op" 2>/dev/null
    done
    return 0
}

# ---------- web 侧 AT 心跳（看门狗「按需检查」的依据） ----------
# 看门狗默认每 10s 只做零开销的存活检查，不去动串口；只有当 web 真的在用
# AT、而且刚报过错，它才去发一条环回 AT 探活。判断依据就是这里写的两个
# 小文件（都放在看门狗的状态目录里）：
#
#   at_hb        "<epoch> ok"   最近一次 AT 往返成功
#                "<epoch> fail" 最近一次 AT 往返超时（没等到 OK/ERROR 终止符）
#   at_hb_start  "<epoch>"      最近一次"请求开始动串口"的时刻
#
# 为什么需要 at_hb_start：孤儿读线程把响应偷走时，CGI 会一直卡在轮询里，
# 不会写出任何结果 —— 只看 at_hb 会以为"没消息就是好消息"。有了开始标记，
# 看门狗就能识别出「已经开始了 60s 还没有结果」= 卡死。
#
# 写这两个文件不碰串口，因此不会干扰正在执行的其他请求。
#
# 落点：$AT_RUN_DIR（内存文件系统，见仓库根目录 at-runenv.sh）。
#   心跳是「每次 AT 往返写一次」的高频写入，如果 /tmp 恰好在 NAND 上，
#   开着自动刷新（每 5s 一轮）一天就是上万次写入 —— 所以必须落在内存里。
AT_HB_DIR="$AT_STATE_DIR"
AT_HB="$AT_HB_DIR/at_hb"
AT_HB_START="$AT_HB_DIR/at_hb_start"

# 心跳最小写间隔（秒）：看门狗判「web 是否正在用」用的窗口是 120s，
# 所以没必要每次都刷新时间戳。状态没变且时间戳还新鲜时就跳过写入，
# 把「每 5s 一次」降到「每 45s 一次」，写入量降一个数量级。
AT_HB_MIN_INTERVAL=45

# at_heartbeat <ok|fail>
at_heartbeat() {
    [ -d "$AT_HB_DIR" ] || return 0
    _hb_now=$(date +%s 2>/dev/null || echo 0)
    # 读现有状态：内容为 "<epoch> <ok|fail>"，用 read 一次拿两个字段
    _hb_ts=""; _hb_st=""
    if [ -f "$AT_HB" ]; then
        read _hb_ts _hb_st < "$AT_HB" 2>/dev/null
        # 状态未变 + 时间戳还新鲜 → 不必写（省一次 NAND/内存写入）
        if [ "$_hb_st" = "$1" ] && [ -n "$_hb_ts" ] && [ "$_hb_now" != "0" ]; then
            [ $((_hb_now - _hb_ts)) -lt "$AT_HB_MIN_INTERVAL" ] 2>/dev/null && return 0
        fi
    fi
    if [ ! -f "$AT_HB" ]; then
        : > "$AT_HB" 2>/dev/null || return 0
        chmod 666 "$AT_HB" 2>/dev/null
    fi
    printf '%s %s\n' "$_hb_now" "$1" > "$AT_HB" 2>/dev/null
    return 0
}

# at_mark_request_start [epoch]   省略 epoch 时自己取
at_mark_request_start() {
    [ -d "$AT_HB_DIR" ] || return 0
    if [ ! -f "$AT_HB_START" ]; then
        : > "$AT_HB_START" 2>/dev/null || return 0
        chmod 666 "$AT_HB_START" 2>/dev/null
    fi
    _mts="$1"
    [ -n "$_mts" ] || _mts=$(date +%s 2>/dev/null || echo 0)
    printf '%s\n' "$_mts" > "$AT_HB_START" 2>/dev/null
    return 0
}

# ---------- 统一清理：锁 + 本进程的后台读线程 ----------
# 必须在任何退出路径上都执行，否则会留下孤儿读线程偷吃后续请求的响应。
# 注意：shell 收到未捕获的 TERM 时 EXIT trap 不一定执行，所以显式再捕获
# TERM/INT/HUP 并主动 exit。
AT_BG_PIDS=""
LOCKDIR=""

# 回收本进程起的所有后台读线程
_at_bg_kill() {
    for _p in $AT_BG_PIDS; do kill $_p 2>/dev/null; done
    AT_BG_PIDS=""
}

# 读线程已由调用方主动回收 → 从登记表里摘掉。
# 必须摘：否则 _at_bg_kill 会去 kill 一个早已消失的 pid，而 pid 会被内核复用
# （一个 CGI 请求期间就 fork 了几十个进程），可能误杀无关进程。
_at_bg_forget() {
    _keep=""
    for _p in $AT_BG_PIDS; do
        [ "$_p" = "$1" ] && continue
        _keep="$_keep $_p"
    done
    AT_BG_PIDS="$_keep"
}

_at_cleanup() {
    _at_bg_kill
    [ -n "$LOCKDIR" ] && rm -rf "$LOCKDIR" 2>/dev/null
    return 0
}

trap '_at_cleanup; exit 130' INT TERM HUP
trap '_at_cleanup' EXIT

# ---------- 原子锁 + 僵尸锁自愈 ----------
# acquire_lock <lockdir>  成功返回 0，超时返回 1（已在内部打印错误）
#
# 注意：
#   - 前端 index.html 会并发发起 12 个 AT 命令，后端 CGI 用此锁串行化
#   - 锁等待上限 600 × 0.1s = 60 秒。
#     原来写的是 3000（=300 秒 / 5 分钟）—— 桥出问题时页面会干转 5 分钟
#     才吐一行 "busy"，配合前端没有请求超时就是「永久转圈圈」。收敛到 60s：
#     正常排队（12 个并发 × 单条最长 3s ≈ 36s）够用，异常时快速失败。
#   - 最长单个命令：sms send 用 20000ms，加上清缓冲 200ms，单条最多 ~20.5 秒
#   - 因此僵尸锁判定必须 > 最长命令时长，这里取 30 秒。
#     否则 A 执行 sms send(20s) 时，B 在第 15 秒回收锁，会造成 A/B 同时操作串口串线。
AT_LOCK_WAIT_TICKS=600      # 60s 后放弃并报 busy
AT_LOCK_ZOMBIE_SEC=30       # ts 时间戳超过 30s 未更新 = 僵尸锁
AT_LOCK_NOTS_TICKS=100      # 锁目录存在但始终没有 ts 超过 10s = 僵尸锁
                            #（持有者在 mkdir 与写 ts 之间被杀，旧代码回收不掉）

acquire_at_lock() {
    LOCKDIR="${1:-$AT_LOCK}"
    LOCK_WAIT=0
    _lock_nots=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        LOCK_WAIT=$((LOCK_WAIT + 1))
        if [ "$LOCK_WAIT" -ge "$AT_LOCK_WAIT_TICKS" ]; then
            echo "ERROR: AT device busy (waited $((AT_LOCK_WAIT_TICKS / 10))s) —— 上个请求可能卡在串口，请稍后重试"
            return 1
        fi
        if [ -f "$LOCKDIR/ts" ]; then
            _lock_nots=0
            # 锁存在超过 30 秒 → 僵尸锁（异常退出未清锁），强制回收
            OLD_TS=$(cat "$LOCKDIR/ts" 2>/dev/null)
            NOW_TS=$(date +%s 2>/dev/null || echo 0)
            if [ -n "$OLD_TS" ] && [ "$NOW_TS" != "0" ] && [ $((NOW_TS - OLD_TS)) -gt "$AT_LOCK_ZOMBIE_SEC" ]; then
                rm -rf "$LOCKDIR" 2>/dev/null
                continue
            fi
        else
            # 锁目录在、但 ts 不存在：持有人刚 mkdir 完还没来得及写（正常，几毫秒）。
            # 若持续这么久都没有 ts，说明持有者在「mkdir 成功 → 写 ts」之间就被杀了。
            # 旧代码只在 ts 存在时才判僵尸 —— 这种锁会永远回收不掉，之后每个请求
            # 都要干等满 60s 才报 busy，表现为页面一直转圈且重启前无法自愈。
            _lock_nots=$((_lock_nots + 1))
            if [ "$_lock_nots" -ge "$AT_LOCK_NOTS_TICKS" ]; then
                rm -rf "$LOCKDIR" 2>/dev/null
                _lock_nots=0
                continue
            fi
        fi
        sleep 0.1
    done
    _lock_ts=$(date +%s 2>/dev/null)
    echo "$_lock_ts" > "$LOCKDIR/ts"
    # 告诉看门狗「有 web 请求开始动串口了」。它靠这个时刻 + at_hb 的结果时刻
    # 识别「请求开始了却一直没结果」的卡死（孤儿读线程偷响应的那种）。
    at_mark_request_start "$_lock_ts"
    # 拿到锁 = 此刻只有我在动串口，可以安全清掉上次被强杀留下的孤儿读线程。
    # 必须在 flush 之前做：孤儿会持续偷吃 ttyOUT2，先清掉才能读到自己的响应。
    sweep_orphan_readers
    # 注意：这里不要再设 trap。文件上方的全局 trap（_at_cleanup）已经负责回收
    # LOCKDIR 和后台读线程；在这儿覆盖 EXIT trap 会导致孤儿读线程泄漏。
    return 0
}

# ---------- 内部：等待设备输出静默 ----------
# 后台 cat 已把设备输出导到 $out，这里轮询 $out 大小：
#   连续 $stable_needed 轮（每轮 0.1s）无增长 = 静默 → 返回
#   最多 $max_wait 轮强制返回（防 URC 持续涌入时卡死）
_wait_silent() {
    local out="$1" max_wait="$2" stable_needed="$3"
    local waited=0 stable=0 last=0 cur=0
    while [ $waited -lt $max_wait ]; do
        sleep 0.1
        waited=$((waited + 1))
        cur=$(wc -c < "$out" 2>/dev/null | tr -d ' \t\r\n')
        [ -z "$cur" ] && cur=0
        if [ "$cur" = "$last" ]; then
            stable=$((stable + 1))
        else
            stable=0
            last=$cur
        fi
        [ $stable -ge $stable_needed ] && return 0
    done
    return 0
}

# ---------- 清缓冲 ----------
# 关键：吸掉 ttyOUT2 里上一次命令的残留回显，防止读到上次结果。
#
# 为什么用「固定短读」而不是「等静默」？
#   之前 _wait_silent 30 3（最多 3s、连续 300ms 静默才停）在模块开机后
#   持续吐 URC（网络注册/信号上报）时永远等不到"连续静默"，每次 flush
#   都跑满 3s 上限 → 单命令 2.8~4.3s 的慢源。
#
#   环回已修（socat echo=0）后，残留来源基本消失，flush 只需固定读
#   300ms 把 PTY 缓冲读空即可，不再依赖"静默"判断。send_at 收尾的
#   _wait_silent 仍是主要防线。
flush_at_buffer() {
    local dev="$1"
    local tmp
    tmp=$(mktemp 2>/dev/null) || tmp="$AT_TMP_DIR/flush_$$.out"
    cat "$dev" > "$tmp" 2>/dev/null &
    local pid=$!
    AT_BG_PIDS="$AT_BG_PIDS $pid"
    sleep 0.15                   # 固定读 150ms，读空缓冲（环回已修后残留极少）
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    _at_bg_forget "$pid"
    rm -f "$tmp"
}

# ---------- 发 AT 命令 ----------
# send_at <device> <command> [timeout_s]
#
# 思路：cat 后台轮询（参考项目 socat-at-bridge/atcmd 的快速方案）。
#   - 先起后台 cat 占住读端（不漏读）
#   - 再写命令
#   - 轮询 grep 命中 OK/ERROR/CMS ERROR/CMGS 即进入收尾
#
# 修重复残留的关键（与旧版的区别）：
#   旧版 grep 命中后立即 kill cat —— 此时 PTY 里往往还有收尾字节未读，
#   kill 后残留，下次又被读出来 → 越积越多（你之前贴的几百份循环）。
#   现在命中后不立即杀，先 _wait_silent 把收尾读干（连续静默 200ms），
#   再 kill，保证本次往返完整消费、零残留。
send_at() {
    local dev="$1" cmd="$2" timeout_s="${3:-3}"
    local tmp
    tmp=$(mktemp 2>/dev/null) || tmp="$AT_TMP_DIR/at_$$.out"
    : > "$tmp"

    # 1) 先起后台 cat 读设备输出（先于写命令，不漏读）
    cat "$dev" > "$tmp" 2>/dev/null &
    local pid=$!
    AT_BG_PIDS="$AT_BG_PIDS $pid"   # 登记，保证 CGI 被强杀时也能被兜底回收
    sleep 0.05

    # 2) 写命令
    printf '%s\r\n' "$cmd" > "$dev" 2>/dev/null

    # 3) 轮询命中 OK/ERROR/CMS ERROR/CMGS
    local elapsed=0 hit=0
    while [ $elapsed -lt $((timeout_s * 10)) ]; do
        if grep -qE '(^|[^A-Z])OK([^A-Z]|$)|ERROR|CMS ERROR|\+CMGS:' "$tmp" 2>/dev/null; then
            hit=1
            break
        fi
        sleep 0.1
        elapsed=$((elapsed + 1))
    done

    # 4) 命中后读干收尾字节（关键：避免 kill 时 PTY 残留）
    if [ $hit -eq 1 ]; then
        _wait_silent "$tmp" 5 2   # 最多 0.5s，连续 200ms 静默
    fi

    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    _at_bg_forget "$pid"

    cat "$tmp" 2>/dev/null
    rm -f "$tmp"
    # 把本次往返结果告诉看门狗：超时（hit=0）才是桥有问题的信号；
    # 用户敲错命令得到的 ERROR 里含 "ERROR" → hit=1，属于正常往返。
    if [ $hit -eq 1 ]; then at_heartbeat ok; else at_heartbeat fail; fi
    return 0
}

# ---------- 发整条分号组合命令（一次往返） ----------
# send_at_batch <device> <cmd;+cmd;...> [timeout_s]
#
# SIM82XX 手册 1.4.4：可在同一命令行组合多条 AT 命令，只需开头一个 AT，分号后不带 AT。
#   例：AT+CGMI;+CGMM;+CGMR  模块依次返回每条的子响应（各带 OK/ERROR）。
#
# 与 send_at 的区别：不能用「命中第一个 OK/ERROR 就停」（会漏掉后续子响应），
# 必须读静默（连续静默代表模块停止输出）才算整批完成。
send_at_batch() {
    local dev="$1" cmd="$2" timeout_s="${3:-4}"
    local tmp
    tmp=$(mktemp 2>/dev/null) || tmp="$AT_TMP_DIR/atb_$$.out"
    : > "$tmp"

    cat "$dev" > "$tmp" 2>/dev/null &
    local pid=$!
    # 必须登记：批量命令最长会跑 8~20s，这段时间正是「浏览器切页/关标签 →
    # lighttpd 杀掉 CGI 主进程」最容易发生的窗口。不登记的话这个 cat 会变成
    # ppid=1 的孤儿读线程，一直握着 /dev/ttyOUT2 偷吃后续所有请求的响应
    # —— 就是「AT 全部转圈圈」的根因。旧代码这一处漏登记。
    AT_BG_PIDS="$AT_BG_PIDS $pid"
    sleep 0.05

    # 整条发送（分号组合，一次往返）
    printf '%s\r\n' "$cmd" > "$dev" 2>/dev/null

    # 等「已出现终止符 且 读静默」或超时
    local waited=0 hit=0
    while [ $waited -lt $((timeout_s * 10)) ]; do
        sleep 0.1
        waited=$((waited + 1))
        if grep -qE '(^|[^A-Z])OK([^A-Z]|$)|ERROR|CMS ERROR|\+CMGS:' "$tmp" 2>/dev/null; then
            # 连续 2 轮(200ms)静默即完成。慢命令（+CGPADDR 遍历 profile 约 2.9s）
            # 已改由前端独立 send 单命令查询，合并命令里都是快命令，200ms 足够，
            # 不必长等拖慢整批响应。
            hit=1
            _wait_silent "$tmp" 20 2
            break
        fi
    done

    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    _at_bg_forget "$pid"

    cat "$tmp" 2>/dev/null
    rm -f "$tmp"
    if [ $hit -eq 1 ]; then at_heartbeat ok; else at_heartbeat fail; fi
    return 0
}