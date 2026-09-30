#!/bin/sh
# =====================================================================
# simcom-webui 运行时目录解析（只落在内存文件系统上，避免磨损 NAND）
#
# 为什么需要这个文件：
#   本模块的存储是 1GB NAND（页 4KB / 擦除块 256KB）+ UBIFS，擦写寿命有限。
#   而本项目的「高频写入」其实不少：
#       · 每次 AT 往返还一次心跳文件           （自动刷新开着时约每 5s 一次）
#       · 每次请求一次互斥锁时间戳
#       · 每条命令一个 mktemp 临时文件
#       · 看门狗日志、lighttpd 日志、开机自启日志（还是 append 不封顶）
#   这些如果落在 UBIFS 上，就是持续不断的 NAND 写入。而 /tmp 在嵌入式平台上
#   **不保证**是 tmpfs（有些固件直接把 /tmp 放在 rootfs 里）。所以这里不做
#   任何假设：直接读 /proc/mounts 判定文件系统类型，只在 tmpfs/ramfs 上建目录。
#
# 解析顺序（第一个「确认为内存 fs 且可写」的胜出）：
#       /dev/shm  →  /run  →  /tmp  →  /var/tmp
#   · /run 在 systemd 平台上是 tmpfs，且只在开机时清理，比 /tmp 更稳
#     （/tmp 可能被 systemd-tmpfiles 按时间清理，会把 pidfile/心跳清掉）
#   · 全都不是内存 fs 时退回 /tmp，并把 AT_RUN_IS_RAM 置 0 供调用方告警
#
# 用法（CGI 与桥接脚本都用它，保证锁/心跳目录一致）：
#   CGI:  . "$(dirname "$0")/../at-runenv.sh"
#   桥:   . "$(dirname "$0")/../at-runenv.sh"
#   之后统一使用：$AT_RUN_DIR / $AT_STATE_DIR / $AT_LOG_DIR / $AT_TMP_DIR / $AT_LOCK
#
# 注意：本文件被每个 CGI 请求 source，所以必须便宜（只有 1 个 awk + 几个
#       mkdir），并且**绝对不能往 stdout 打印任何东西**（会污染 CGI 响应），
#       也不能写日志。
# =====================================================================

# 从 /proc/mounts 里挑出「白名单内的、内存文件系统」的挂载点。
# 只认 tmpfs/ramfs：devtmpfs 虽然是内存，但把它当工作目录不合适；
# /sys /proc /dev /run/user 之类也不在白名单里。
# 一次 awk 完成，避免逐候选 fork。输出 "<挂载点> <fstype>"。
_simcom_pick_ram_root() {
    awk '
        $3 == "tmpfs" || $3 == "ramfs" {
            if ($2 == "/dev/shm") { print "/dev/shm " $3; exit }
            if ($2 == "/run")     { r = "/run"; fs = $3 }
            else if ($2 == "/tmp"     && r == "") { r = "/tmp";     fs = $3 }
            else if ($2 == "/var/tmp" && r == "") { r = "/var/tmp"; fs = $3 }
        }
        END { if (r != "") print r " " fs }
    ' /proc/mounts 2>/dev/null
}

# 目录可写实测（mkdir + rmdir：比 touch 更贴近真实使用）
_simcom_dir_writable() {
    mkdir -p "$1/.simcom-wtest" 2>/dev/null || return 1
    rmdir "$1/.simcom-wtest" 2>/dev/null
    return 0
}

# 指定路径所在文件系统的类型（从 $1 逐级向上找挂载点）
AT_RUN_FS=""
_simcom_fs_of() {
    _fs_p="$1"
    while : ; do
        _fs_t=$(awk -v m="$_fs_p" '$2 == m { print $3; exit }' /proc/mounts 2>/dev/null)
        [ -n "$_fs_t" ] && { echo "$_fs_t"; return 0; }
        [ "$_fs_p" = "/" ] && return 1
        _fs_p=$(dirname "$_fs_p")
    done
}

AT_RUN_IS_RAM=1
AT_RUN_DIR=""

_simcom_pick=$(_simcom_pick_ram_root)
_simcom_root=${_simcom_pick%% *}
if [ -n "$_simcom_root" ] && _simcom_dir_writable "$_simcom_root"; then
    AT_RUN_FS=${_simcom_pick#* }
    AT_RUN_DIR="$_simcom_root/simcom-webui"
else
    # 没有内存文件系统可用 → 退回 /tmp，并标记非内存（调用方据此告警）
    AT_RUN_IS_RAM=0
    AT_RUN_DIR="/tmp/simcom-webui"
fi

# 建目录树；如果首选位置建不出来（tmpfs 只读 / 空间不足），退到 /tmp
if ! mkdir -p "$AT_RUN_DIR/bridge" "$AT_RUN_DIR/log" "$AT_RUN_DIR/tmp" 2>/dev/null; then
    if [ "$AT_RUN_DIR" != "/tmp/simcom-webui" ]; then
        AT_RUN_IS_RAM=0
        AT_RUN_DIR="/tmp/simcom-webui"
        AT_RUN_FS=$(_simcom_fs_of "$AT_RUN_DIR")
        mkdir -p "$AT_RUN_DIR/bridge" "$AT_RUN_DIR/log" "$AT_RUN_DIR/tmp" 2>/dev/null
    fi
fi
# 兜底：只要不是 tmpfs/ramfs，就一律认为「没落在内存上」，供上层告警
if [ "$AT_RUN_IS_RAM" = "1" ]; then
    [ -n "$AT_RUN_FS" ] || AT_RUN_FS=$(_simcom_fs_of "$AT_RUN_DIR")
    case "$AT_RUN_FS" in
        tmpfs|ramfs) ;;
        *) AT_RUN_IS_RAM=0 ;;
    esac
fi

# 看门狗状态（pidfile / 心跳 / 日志）与临时文件、日志目录
AT_STATE_DIR="$AT_RUN_DIR/bridge"
AT_LOG_DIR="$AT_RUN_DIR/log"
AT_TMP_DIR="$AT_RUN_DIR/tmp"

# 串口互斥锁：CGI 与看门狗探活必须抢同一把锁（否则探活的 AT/OK 会插进
# 正在执行的 CGI 响应里，导致前端解析错乱）。所以两边都从本文件取。
AT_LOCK="$AT_RUN_DIR/atcmd.lock"

# 让 mktemp 也只用内存目录（busybox mktemp 会读 TMPDIR）
TMPDIR="$AT_TMP_DIR"
export TMPDIR

# 权限：CGI 由 lighttpd 以非 root 身份 fork（本平台通常是 root，但别赌），
# 心跳/锁目录必须让所有相关进程都能写。
chmod 777 "$AT_RUN_DIR" "$AT_STATE_DIR" "$AT_LOG_DIR" "$AT_TMP_DIR" 2>/dev/null

# 单个日志文件上限（字节）。日志只用于排查，超限直接截断而不是无限增长 ——
# 即使 /tmp 不是内存，也不会把分区写满。
AT_LOG_MAX=262144        # 256 KiB

# at_log_cap <file>   超过 AT_LOG_MAX 就截断为最近 64 KiB
at_log_cap() {
    [ -f "$1" ] || return 0
    _al_sz=$(wc -c < "$1" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$_al_sz" ] || return 0
    [ "$_al_sz" -gt "$AT_LOG_MAX" ] 2>/dev/null || return 0
    tail -c 65536 "$1" > "$1.cap" 2>/dev/null && mv "$1.cap" "$1" 2>/dev/null
    return 0
}
