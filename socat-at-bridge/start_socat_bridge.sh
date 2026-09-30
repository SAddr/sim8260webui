#!/bin/sh
# =====================================================================
# AT 串口桥接启动器 (start_socat_bridge.sh)
#
# 架构（1 个 socat + 2 条搬运腿）：
#         socat 创建 PTY 对:  /dev/ttyIN2  <->  /dev/ttyOUT2
#         读腿  cat /dev/smd8  > /dev/ttyIN2    (模块响应 → 桥)
#         写腿  cat /dev/ttyIN2 > /dev/smd8     (桥 → 模块命令)
#         CGI 读写 /dev/ttyOUT2 与模块交互
#
# 本脚本现在只是「启动入口」，实际拉起与守护交给 bridge_watchdog.sh：
#   · 原来这里用 `( while true; do cat ...; sleep 0.5; done ) &` 自己拉起两条腿，
#     有两个致命问题：
#       1) 没有任何进程负责"腿还活着吗" —— 腿掉了桥就断了，而 socat 还在，
#          于是 ps 看着正常、网页却全部转圈圈；
#       2) `sleep 0.5` 的重启盲区里，模块吐出来的响应会被直接丢掉。
#   · 更要紧的是子 shell 里的后台进程没有脱离父会话：开机钩子退出时可能被
#     SIGHUP 一起带走（"重启后桥没了"的常见原因）。看门狗内部一律用 setsid。
#
# 用法：
#   sh start_socat_bridge.sh              # 起桥 + 常驻看门狗（幂等）
#   sh start_socat_bridge.sh --foreground # 只起桥，不起看门狗（调试用）
# =====================================================================

BRIDGE_DIR=$(cd "$(dirname "$0")" && pwd)
WATCHDOG="$BRIDGE_DIR/bridge_watchdog.sh"

# 运行时目录：与看门狗/CGI 共用同一份解析（仓库根目录 at-runenv.sh），
# 只落在内存文件系统上，日志不会写进 NAND。
_SIMCOM_RUNENV="$BRIDGE_DIR/../at-runenv.sh"
if [ -f "$_SIMCOM_RUNENV" ]; then
    . "$_SIMCOM_RUNENV"
else
    AT_RUN_DIR=/tmp/simcom-webui
    AT_STATE_DIR="$AT_RUN_DIR/bridge"
    AT_LOG_DIR="$AT_RUN_DIR/log"
    AT_RUN_FS=""
    AT_RUN_IS_RAM=0
fi
RUN_DIR="$AT_STATE_DIR"
LOG="$AT_LOG_DIR/bridge.log"

mkdir -p "$RUN_DIR" "$AT_LOG_DIR" 2>/dev/null

# ---------- 探测 AT 串口 ----------
AT_DEV=""
for d in /dev/smd8 /dev/smd7 /dev/smd11; do
    [ -c "$d" ] && { AT_DEV="$d"; break; }
done
if [ -z "$AT_DEV" ]; then
    echo "ERROR: 未找到 AT 串口（smd8/smd7/smd11 都不存在）"
    exit 1
fi
echo "Using AT device: $AT_DEV"

if [ ! -f "$WATCHDOG" ]; then
    echo "ERROR: 缺少 $WATCHDOG（看门狗脚本未部署）"
    exit 1
fi

# ---------- 起桥（看门狗负责启动 socat + 两条腿，并做首次探活） ----------
echo "[1/2] 通过看门狗重建桥接..."
sh "$WATCHDOG" --restart
RC=$?

if [ ! -c /dev/ttyOUT2 ]; then
    echo "ERROR: /dev/ttyOUT2 未创建，详见 $LOG"
    exit 1
fi
echo "  [OK] /dev/ttyOUT2 就绪"

# ---------- 常驻看门狗 ----------
if [ "$1" = "--foreground" ]; then
    echo "[2/2] --foreground：跳过常驻看门狗"
    echo "AT bridge ready.（无守护，腿掉了不会自动恢复）"
    exit $RC
fi

echo "[2/2] 启动常驻看门狗（setsid 脱离会话，避免被开机钩子退出带走）..."
if command -v setsid >/dev/null 2>&1; then
    setsid sh "$WATCHDOG" </dev/null >> "$LOG" 2>&1 &
else
    nohup sh "$WATCHDOG" </dev/null >> "$LOG" 2>&1 &
fi

sleep 1
if [ -f "$RUN_DIR/watchdog.pid" ]; then
    echo "  [OK] 看门狗已启动 pid=$(cat "$RUN_DIR/watchdog.pid")"
else
    echo "  [WARN] 看门狗 pidfile 未生成，检查 $LOG"
fi

echo ""
echo "AT bridge ready."
echo "  用 /dev/ttyOUT2 收发 AT"
echo "  自检： sh $BRIDGE_DIR/bridge_status.sh"
echo "  日志： $LOG"
exit $RC
