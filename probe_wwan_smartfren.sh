#!/bin/sh
# =====================================================================
# WWAN IPv4/IPv6 诊断探针（Smartfren 专用）
#
# 用途：在 Smartfren 卡的那台设备上跑，把输出整段贴回。
# 走的是和 WebUI 完全相同的 AT 通道（libat.sh 的 send_at），
# 所以这里看到什么，网页上就拿得到什么 —— 能真实复现首页的现象。
#
# 用法（电脑端）：
#   adb push probe_wwan_smartfren.sh /userdata/simcom-webui/probe.sh
#   adb shell "sh /userdata/simcom-webui/probe.sh"
# 跑完记得：adb shell "rm -f /userdata/simcom-webui/probe.sh"
# =====================================================================

D=/userdata/simcom-webui

echo "################ 0. 部署版本核对 ################"
if [ -f "$D/www/settings.html" ]; then
  echo -n "WebUI 版本: "
  grep -o 'v1\.0\.[0-9]' "$D/www/settings.html" | head -1
else
  echo "!! 找不到 $D/www/settings.html"
fi
for f in index.html network.html; do
  if [ -f "$D/www/$f" ]; then
    echo "$f : 大小=$(wc -c < "$D/www/$f")  修改时间=$(date -r "$D/www/$f" '+%F %T' 2>/dev/null)"
    echo -n "   含 splitAddr 修复(IPv6按段数判型): "
    grep -c 'splitAddr' "$D/www/$f"
    echo -n "   含 loadWWANIP : "
    grep -c 'loadWWANIP' "$D/www/$f"
  else
    echo "!! 找不到 $D/www/$f"
  fi
done

echo ""
echo "################ 1. 环境 ################"
if [ -f "$D/cgi-bin/libat.sh" ]; then
  . "$D/cgi-bin/libat.sh"
else
  echo "!! 找不到 $D/cgi-bin/libat.sh，退出"
  exit 1
fi
DEV=$(find_at_device)
if [ -n "$DEV" ]; then
  echo "AT 设备节点: $DEV"
else
  echo "!! 找不到 AT 设备节点（/dev/ttyOUT2 等），退出"
  exit 1
fi
echo "运行时目录: $AT_RUN_DIR  (IS_RAM=$AT_RUN_IS_RAM)"
echo "当前时间  : $(date '+%F %T')"

# 发一条命令并原样打印。第二参数是超时秒数（CGPADDR 慢，给足）。
probe() {
  echo ""
  echo "=====[ CMD: $1 ]====="
  send_at "$DEV" "$1" "${2:-5}" | sed -e 's/\r/<CR>/g'
  echo "=====[ END: $1 ]====="
}

echo ""
echo "################ 2. 运营商 / 注册 ################"
probe 'AT+COPS?' 5
probe 'AT+CEREG?' 5

echo ""
echo "################ 3. 首页取 IPv4 的两条数据源 ################"
echo "--- 3.1 主数据源：AT+CQCMAP=\"WWAN\"（首页 net-ip4 主要靠它）---"
probe 'AT+CQCMAP="WWAN"' 5
echo "--- 3.2 兜底数据源：AT+CGPADDR（慢，给 10s）---"
probe 'AT+CGPADDR' 10

echo ""
echo "################ 4. PDP 上下文全貌 ################"
probe 'AT+CGDCONT?' 6
probe 'AT+CGACT?' 6

echo ""
echo "################ 5. 辅助（LAN / 网络信息）################"
probe 'AT+CQCMAP="LANIP"' 5
probe 'AT+CNWINFO?' 5

echo ""
echo "################ 6. 首页合并命令整条（复现 refreshAll 那条）################"
probe 'AT+CNWINFO=1;+CPSI?;+CRSSI?;+CQCMAP="LANIP";+CEREG?;+C5GREG?;+CNWINFO?;+CGDCONT?' 8

echo ""
echo "################ 完成 ################"
echo "请把上面 =====[...]===== 之间的内容原样贴回（尤其是第 3 段）。"
