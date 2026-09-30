/* =============================================================
   i18n.js — 中 / 英双语支持（默认中文，切换后存入 localStorage）
   · localStorage key: wb-lang（'zh' | 'en'）
   · 暴露 window.wbI18n.get() / set(lang) / toggle() / t(text)
   · 在顶栏自动注入「中 / EN」切换按钮

   设计说明（为什么用「中文原文 → English」字典 + DOM 扫描）：
     · 全站 7 个页面有大量内联中文文案，逐个加 data-i18n 属性改动面太大；
     · 用原文做 key，未收录的文案自动保持中文，不会因缺词条而报错（优雅降级）；
     · MutationObserver 监听 DOM 变化，JS 动态写入的状态文案（如「已连接」）
       也能自动翻译，无需改业务 JS；
     · 原文存在 WeakMap 里，切回中文时精确还原，不做「英译中」二次查表。
   ============================================================= */
(function () {
  'use strict';

  var KEY = 'wb-lang';
  var ZH = 'zh';
  var EN = 'en';
  var DEFAULT = ZH;

  /* =============================================================
     字典：中文原文 → English
     说明：key 必须是「渲染后 trim 掉的完整文本」；未命中的文案保持中文。
     ============================================================= */
  var DICT = {
    /* ---- 顶栏 / 导航 / 页面标题 ---- */
    '管理面板': 'Control Panel',
    '总览': 'Overview',
    '信号': 'Signal',
    '网络': 'Network',
    '设备': 'Device',
    '短信': 'SMS',
    'AT 命令': 'AT Commands',
    '设置': 'Settings',
    'SIM8260 控制面板': 'SIM8260 Control Panel',
    '仪表盘': 'Dashboard',
    '实时监控模块运行状态与信号质量': 'Real-time module status and signal quality',
    '信号详情 · SIM8260': 'Signal Details · SIM8260',
    '信号详情': 'Signal Details',
    '实时监测当前制式信号质量与各天线状态': 'Live signal quality and per-antenna status for the current RAT',
    '网络配置 · SIM8260': 'Network Config · SIM8260',
    '网络配置': 'Network Config',
    '拨号管理、APN 设置、网口模式': 'Dial-up, APN settings, Ethernet mode',
    '设备信息 · SIM8260': 'Device Info · SIM8260',
    '模块身份标识、固件版本与系统资源占用': 'Module identity, firmware version and system resource usage',
    '短信 · SIM8260': 'SMS · SIM8260',
    '收件箱，发送与删除短信': 'Inbox, send and delete SMS',
    'AT 命令终端 · SIM8260': 'AT Terminal · SIM8260',
    'AT 命令控制台 + 受限 Linux 终端': 'AT console + restricted Linux shell',
    '设置 · SIM8260': 'Settings · SIM8260',
    'USB 网卡形态、自动拨号等高级配置': 'USB NIC mode, auto-dial and other advanced settings',

    /* ---- 通用操作 / 按钮 ---- */
    '刷新': 'Refresh',
    '⟳ 刷新': '⟳ Refresh',
    '⟳ 立即刷新': '⟳ Refresh Now',
    '⟳ 刷新小区': '⟳ Refresh Cell',
    '⟳ 自动刷新': '⟳ Auto Refresh',
    '⟳ 刷新中': '⟳ Refreshing',
    '查询支持': 'Query Support',
    '执行': 'Run',
    '发送': 'Send',
    '📤 发送': '📤 Send',
    '发送短信': 'Send SMS',
    '发送中...': 'Sending...',
    '提交中...': 'Submitting...',
    '重置中...': 'Resetting...',
    '保存': 'Save',
    '删除': 'Delete',
    '清空': 'Clear',
    '清空记录': 'Clear Log',
    '全选': 'Select All',
    '应用': 'Apply',
    '应用模式': 'Apply Mode',
    '应用所选': 'Apply Selected',
    '应用网口模式': 'Apply Ethernet Mode',
    '应用 USB 配置': 'Apply USB Config',
    '写入': 'Write',
    '连接': 'Connect',
    '断开': 'Disconnect',
    '查询中…': 'Querying…',
    '检测中': 'Detecting',
    '检测中…': 'Detecting…',
    '加载中…': 'Loading…',
    '加载中...': 'Loading...',
    '检查中': 'Checking',
    '搜索中': 'Searching',
    '扫描中（列表可见运营商），可能需要数十秒…': 'Scanning (visible operators), may take tens of seconds…',
    '支持频段查询中…': 'Querying supported bands…',
    '导出记录': 'Export Log',
    '详情 →': 'Details →',
    '管理 →': 'Manage →',

    /* ---- 状态 / 结果 ---- */
    '已连接': 'Connected',
    '已断开': 'Disconnected',
    '未连接': 'Not Connected',
    '已注册(本地)': 'Registered (Home)',
    '已注册(漫游)': 'Registered (Roaming)',
    '未注册': 'Not Registered',
    '无服务': 'No Service',
    '脱网': 'Offline',
    '已锁定': 'Locked',
    '未锁定': 'Unlocked',
    '锁定': 'Lock',
    '已启用': 'Enabled',
    '未启用': 'Disabled',
    '已开启': 'On',
    '已关闭': 'Off',
    '开启': 'Enable',
    '关闭': 'Disable',
    'enable - 开启': 'enable - On',
    'disable - 关闭': 'disable - Off',
    '已开启 (enable)': 'On (enable)',
    '已关闭 (disable)': 'Off (disable)',
    '已读': 'Read',
    '未读': 'Unread',
    '已输入': 'Entered',
    '已插入并激活': 'Inserted & Activated',
    '已插入未激活': 'Inserted, Not Activated',
    '未插入': 'Not Inserted',
    '无激活 SIM': 'No Active SIM',
    'SIM 错误': 'SIM Error',
    '未知': 'Unknown',
    '未知号码': 'Unknown Number',
    '(空)': '(Empty)',
    '无数据': 'No Data',
    '无数据（接口无返回）': 'No Data (empty response)',
    '暂无短信': 'No messages',
    '暂无当前小区信息，请先等待刷新或点击「刷新小区」': 'No cell info yet — wait for refresh or click "Refresh Cell"',
    '未读到 PDP 上下文': 'No PDP context read',
    '读取失败': 'Read Failed',
    '请求失败': 'Request Failed',
    '删除成功': 'Deleted',
    '✅ 发送成功': '✅ Sent Successfully',
    '✅ 密码修改成功！下次登录请使用新密码': '✅ Password changed! Use the new password next login',
    '✅ 已重置为 admin/admin': '✅ Reset to admin/admin',
    '❌ 关闭': '❌ Off',
    '✅ 开启 (Profile': '✅ On (Profile',
    '上网中': 'In Use',
    '空闲': 'Idle',
    '系统保留': 'Reserved',
    '未分配': 'Not Assigned',
    '未聚合': 'No CA',
    'EN-DC 双连接 (4G+5G)': 'EN-DC Dual Connectivity (4G+5G)',
    '5G 独立组网 (SA)': '5G Standalone (SA)',
    'LTE 单载波': 'LTE Single Carrier',
    '4G+5G 双连接': '4G+5G Dual Connectivity',
    '4G 单独 (LTE)': '4G Only (LTE)',
    '优秀': 'Excellent',
    '良好': 'Good',
    '一般': 'Fair',
    '差': 'Poor',
    '强 -40 dBm': 'Strong -40 dBm',
    '弱 -140 dBm': 'Weak -140 dBm',
    '立即生效': 'Effective Immediately',
    '已应用：': 'Applied: ',
    '已保存：\n': 'Saved:\n',
    '保存失败：\n': 'Save failed:\n',
    '设置失败：\n': 'Setup failed:\n',
    '写入失败：\n': 'Write failed:\n',
    '指令已发送：\n': 'Command sent:\n',
    '拨号指令已发送：\n': 'Dial command sent:\n',
    '断开指令已发送：\n': 'Disconnect command sent:\n',
    '请求失败：': 'Request failed: ',
    '查询出错：': 'Query error: ',
    '扫描出错：': 'Scan error: ',
    '切换指令返回异常：\n': 'Switch command returned error:\n',
    '锁定失败：\n': 'Lock failed:\n',
    '锁定失败，请检查命令/参数：\n': 'Lock failed, check command/params:\n',
    '锁定失败（或该命令不支持）：\n': 'Lock failed (or unsupported):\n',
    '设置失败（模块可能支持 IPA 硬件加速，SFE 不可用）：\n': 'Setup failed (module may use IPA HW accel, SFE unavailable):\n',
    '恢复频段结果：\n': 'Restore bands result:\n',
    '清除结果：\nLTE:': 'Clear result:\nLTE:',
    '删除结果：': 'Delete result: ',
    '不支持或未返回（可能支持 IPA 硬件加速）': 'Unsupported or no response (IPA HW accel may be in use)',
    '未扫描到结果或模块未返回（': 'No scan result or module returned nothing (',
    '模块未返回该频段组（': 'Module did not return this band group (',
    '：未查询到支持列表': ': no supported list returned',
    '：空列表': ': empty list',
    '已设置 CFUN=1': 'CFUN=1 set',
    '已设置 CFUN=0': 'CFUN=0 set',
    '已设置 CFUN=4': 'CFUN=4 set',
    '已设置网口模式为': 'Ethernet mode set to ',
    '已设置 NR 模式:': 'NR mode set:',
    '已设置 RAT 优先级:': 'RAT priority set:',
    'IMEI 写入指令已受理（重启后生效）：\n': 'IMEI write accepted (effective after reboot):\n',
    'SIM 切换指令已受理：\n': 'SIM switch accepted:\n',
    '重启指令已发送，模块将在几秒后重启...': 'Reboot command sent, module restarts in a few seconds...',
    'SFE 已设置为': 'SFE set to ',

    /* ---- 首页 / 总览 ---- */
    '网络连接': 'Network',
    '运营商 / 频段': 'Operator / Band',
    '网络模式': 'Network Mode',
    '信号强度 (RSRP)': 'Signal (RSRP)',
    '信号强度': 'Signal Strength',
    '参考信号接收功率': 'Reference Signal Received Power',
    '下行流数 / 调制': 'DL Layers / Modulation',
    '下行调制方式': 'DL Modulation',
    '下行调制:': 'DL modulation:',
    '上行发射功率': 'UL Tx Power',
    '载波聚合': 'Carrier Aggregation',
    '注册状态': 'Registration',
    '工作模式': 'Work Mode',
    '网络制式': 'RAT',
    '当前 RAT': 'Current RAT',
    '运营商 PLMN': 'Operator PLMN',
    'WWAN IPv4': 'WWAN IPv4',
    'WWAN IPv6': 'WWAN IPv6',
    'LN IP / 网关': 'LAN IP / Gateway',
    'WWAN 拨号': 'WWAN Dial-up',
    'LAN 设置': 'LAN',
    'IPv4 地址': 'IPv4 Address',
    'IPv6 地址': 'IPv6 Address',
    'LAN 网关 IP': 'LAN Gateway IP',
    'DHCP 起始': 'DHCP Start',
    'DHCP 结束': 'DHCP End',
    '网口模式': 'Ethernet Mode',
    '0 - LAN 路由器': '0 - LAN Router',
    '1 - WAN 路由器': '1 - WAN Router',
    '2 - eth0 WAN + eth1 LAN': '2 - eth0 WAN + eth1 LAN',
    'LAN 路由器': 'LAN Router',
    'WAN 路由器': 'WAN Router',
    'Profile ID': 'Profile ID',
    'Profile': 'Profile',
    '原始应答（CPSI / CRSSI / CNWINFO）点击展开': 'Raw response (CPSI / CRSSI / CNWINFO) click to expand',
    '📄 原始应答（CPSI / CRSSI / CNWINFO）点击展开': '📄 Raw response (CPSI / CRSSI / CNWINFO) click to expand',

    /* ---- 信号页 ---- */
    '5G NR 信号质量': '5G NR Signal Quality',
    '信号质量': 'Signal Quality',
    '质量评级': 'Quality Rating',
    '频段': 'Band',
    '频段 Band': 'Band',
    '频段:': 'Band:',
    '带宽': 'Bandwidth',
    '状态': 'Status',
    '类型': 'Type',
    '规则': 'Rule',
    '模式': 'Mode',
    '架构参考': 'Reference',
    '流': 'Layers',
    '· 上行': '· UL',
    '天线信号分布 (4×4 MIMO)': 'Antenna Signal (4×4 MIMO)',
    'LTE 各天线 RSSI': 'LTE Antenna RSSI',
    'NR 各天线 RSSI (4×4 MIMO)': 'NR Antenna RSSI (4×4 MIMO)',
    '每根天线信号': 'Per-antenna Signal',
    'PRX (主)': 'PRX (Main)',
    'PRX0 (主)': 'PRX0 (Main)',
    'LTE 锚点（EN-DC）': 'LTE Anchor (EN-DC)',
    '📡 LTE 锚点（EN-DC）': '📡 LTE Anchor (EN-DC)',
    '为 ×10 上报，需 /10': 'reported ×10, divide by 10',
    '→ 已 ×10 上报，展示前需 /10': '→ reported ×10, divided by 10 for display',
    '(NR) 取值 -23~40 即整数 dB、': '(NR) range -23~40, integer dB,',

    /* ---- 网络页 ---- */
    'APN 配置（全部 Profile）': 'APN (All Profiles)',
    'APN 名称': 'APN Name',
    'PDP 类型': 'PDP Type',
    'IPV4V6 (双栈)': 'IPV4V6 (Dual Stack)',
    'IP (IPv4)': 'IP (IPv4)',
    'IPV6': 'IPV6',
    '留空 = 不设置 APN': 'Empty = no APN',
    '请选择 PDP 类型': 'Please select a PDP type',
    '操作': 'Action',
    '网络模式 (3G/4G/5G)': 'Network Mode (3G/4G/5G)',
    '当前模式': 'Current Mode',
    '自动 (2)': 'Auto (2)',
    '3G+4G+5G (55)': '3G+4G+5G (55)',
    '4G+5G (109)': '4G+5G (109)',
    '3G+4G (54)': '3G+4G (54)',
    '仅 4G LTE (38)': 'LTE Only (38)',
    '仅 5G NR (71)': 'NR Only (71)',
    '仅 3G WCDMA (14)': 'WCDMA Only (14)',
    '确定切换网络模式为「': 'Switch network mode to "',
    '」？\n切换后模块会重新搜网，可能短暂断网。': '"?\nModule will re-scan; brief disconnection is normal.',
    'NR 模式': 'NR Mode',
    'NR 禁用模式': 'NR Disable Mode',
    '0 - 允许 SA 和 NSA': '0 - Allow SA & NSA',
    '1 - 禁用 SA': '1 - Disable SA',
    '2 - 禁用 NSA': '2 - Disable NSA',
    '允许 SA+NSA': 'Allow SA+NSA',
    '禁用 SA': 'Disable SA',
    '禁用 NSA': 'Disable NSA',
    'RAT 优先级': 'RAT Priority',
    '如 12:9:5 (NR:LTE:WCDMA)': 'e.g. 12:9:5 (NR:LTE:WCDMA)',
    '请输入优先级，如 12:9:5（NR:LTE:WCDMA）': 'Enter priority, e.g. 12:9:5 (NR:LTE:WCDMA)',
    '优先级格式应为数字冒号分隔，如 12:9:5': 'Priority must be colon-separated numbers, e.g. 12:9:5',
    '锁频 (Band Lock)': 'Band Lock',
    '恢复所有频段默认': 'Restore All Bands',
    '刷新频段': 'Refresh Bands',
    '支持 LTE 频段': 'Supported LTE Bands',
    '支持 NR SA 频段': 'Supported NR SA Bands',
    '支持 NR NSA 频段': 'Supported NR NSA Bands',
    '支持 NRDC 频段': 'Supported NRDC Bands',
    '支持 WCDMA 频段': 'Supported WCDMA Bands',
    'LTE 频段': 'LTE Bands',
    'NR SA 频段': 'NR SA Bands',
    'NR NSA 频段': 'NR NSA Bands',
    'NRDC 频段': 'NRDC Bands',
    'WCDMA 频段': 'WCDMA Bands',
    '支持频段（': 'Supported bands (',
    '请至少勾选一个频段': 'Select at least one band',
    '频段格式应为数字冒号分隔，如 1:3:5 或 B1:B3 / n1:n3': 'Bands must be colon-separated, e.g. 1:3:5 or B1:B3 / n1:n3',
    '频段，如 1:3:5 或 B1:B3 / n1:n3': 'Bands, e.g. 1:3:5 or B1:B3 / n1:n3',
    '确定恢复所有频段为默认？尚未设置特定频段时请勿操作。': 'Restore all bands to default? Do not proceed if no band was set.',
    '小区扫描 / 锁小区': 'Cell Scan / Cell Lock',
    '扫描运营商 (COPS=?)': 'Scan Operators (COPS=?)',
    '小区 ID': 'Cell ID',
    'PCI (物理小区)': 'PCI (Physical Cell)',
    'EARFCN (频点)': 'EARFCN',
    '频点': 'ARFCN',
    '锁定状态': 'Lock Status',
    '当前小区快速填入：': 'Fill from current cell: ',
    '锁 LTE 小区': 'Lock LTE Cell',
    '锁 NR 小区': 'Lock NR Cell',
    '请输入 PCI 和 EARFCN': 'Enter PCI and EARFCN',
    '请填写 PCI、FREQ、BAND': 'Fill in PCI, FREQ, BAND',
    'LTE 小区锁定成功：\n': 'LTE cell locked:\n',
    'NR 小区锁定成功：\n': 'NR cell locked:\n',
    'LTE 已锁定': 'LTE Locked',
    'NR 已锁定': 'NR Locked',
    '清除 ALL 小区锁定': 'Clear All Cell Locks',
    '确定清除所有小区锁定？解锁命令在重启后生效。': 'Clear all cell locks? Unlock takes effect after reboot.',
    '确定锁 LTE 小区 PCI=': 'Lock LTE cell with PCI=',
    '确定锁 NR 小区？PCI=': 'Lock NR cell with PCI=',
    '当前无 LTE 小区（当前 RAT:': 'No LTE cell now (current RAT:',
    '当前无 NR 小区（当前 RAT:': 'No NR cell now (current RAT:',
    '如 n41:n78': 'e.g. n41:n78',
    '如 B1:B3:B5': 'e.g. B1:B3:B5',
    '如 B1:B3:B5:B8': 'e.g. B1:B3:B5:B8',
    '填 LTE 锁定框': 'Fill LTE lock fields',
    '填 NR 锁定框': 'Fill NR lock fields',
    '网络与小区': 'Network & Cell',
    '拨号状态': 'Dial Status',
    '是系统保留 APN': 'is a reserved APN',
    '修改可能导致 IMS 或紧急呼叫异常。确定继续？': 'This may break IMS or emergency calls. Continue?',

    /* ---- 设备页 ---- */
    '基本信息': 'Basic Info',
    '设备信息': 'Device Info',
    '厂商': 'Manufacturer',
    '型号': 'Model',
    '固件版本': 'Firmware',
    'ICCID (SIM卡)': 'ICCID (SIM)',
    'SIM 状态': 'SIM Status',
    '模块电压': 'Module Voltage',
    '模块温度': 'Module Temp',
    'CPU 分区温度': 'CPU Zone Temps',
    '资源占用 (Linux)': 'Resource Usage (Linux)',
    'CPU 占用': 'CPU Usage',
    '内存': 'Memory',
    '存储 /': 'Storage /',
    '存储 /etc/machine-id': 'Storage /etc/machine-id',
    '负载 (1/5/15)': 'Load (1/5/15)',
    '运行时长': 'Uptime',
    '系统时间': 'System Time',
    '系统信息': 'System Info',
    '系统操作': 'System Actions',
    '天': 'd',
    '时': 'h',
    '分': 'm',
    '重启模块': 'Reboot Module',
    '🔄 重启模块': '🔄 Reboot Module',
    // ---- 链路速率估算（signal.html）----
    '链路速率估算': 'Link Rate Estimate',
    '🚀 链路速率估算': '🚀 Link Rate Estimate',
    '载波带宽': 'Carrier Bandwidth',
    '下行调制': 'DL Modulation',
    '上行调制': 'UL Modulation',
    '下行流数': 'DL Layers (MIMO)',
    '频谱效率': 'Spectral Efficiency',
    '估算下行': 'Est. Downlink',
    '估算上行': 'Est. Uplink',
    '层': 'layers',
    '理论估算，不是实测速率，也不是运营商签约速率。': 'Theoretical estimate only — not measured throughput, not your subscribed rate.',
    '⚠️ 理论估算，不是实测速率，也不是运营商签约速率。': '⚠️ Theoretical estimate only — not measured throughput, not your subscribed rate.',
    '下行流数（MIMO 层数）AT 指令读不到，按 RSRP/SNR 推断。': 'DL layers (MIMO rank) is not exposed by any AT command; inferred from RSRP/SNR.',
    '实测吞吐通常为估算值的 60%~85%（调度、核心网限速、TCP 开销）。': 'Real throughput is typically 60%~85% of this (scheduling, core-network policy, TCP overhead).',
    '准确速率请用 iperf3 或测速工具实测。': 'For an accurate figure, measure with iperf3 or a speed test.',
    'NSA 为 NR 与 LTE 锚点之和，实际分流比例由网络决定。': 'NSA total = NR + LTE anchor; the actual split is decided by the network.',
    '当前未取到调制方式，无法估算（CNWINFO 未返回）。': 'Modulation unavailable — cannot estimate (CNWINFO returned none).',
    '3G（WCDMA/HSPA）不使用 LTE/NR 的资源块调度模型，无法按此方式估算。': '3G (WCDMA/HSPA) does not use the LTE/NR resource-block model; cannot be estimated this way.',
    '⚠️ 3G（WCDMA/HSPA）不使用 LTE/NR 的资源块调度模型，无法按此方式估算。': '⚠️ 3G (WCDMA/HSPA) does not use the LTE/NR resource-block model; cannot be estimated this way.',
    '无可用链路数据。': 'No link data available.',
    '⚠️ 无可用链路数据。': '⚠️ No link data available.',
    // ---- 预设命令库（拨号 / USB / 锁网 / 调试）----
    '拨号链路状态': 'Dial Link Status',
    '启动拨号': 'Start Dial-up',
    '断开拨号': 'Stop Dial-up',
    'PS 域附着状态': 'PS Attach Status',
    'CS 域注册': 'CS Domain Registration',
    '支持的 USB 模式': 'Supported USB Modes',
    '切 RNDIS（电脑拨号）': 'Switch to RNDIS (PC dial-up)',
    '切 9001（备份 QCN）': 'Switch to 9001 (QCN backup)',
    '开启 ADB': 'Enable ADB',
    '锁 5G': 'Lock to 5G',
    '锁 4G': 'Lock to 4G',
    '锁 n79': 'Lock to n79',
    '解锁全部频段': 'Unlock All Bands',
    '查询 5G 支持频段': 'Query Supported 5G Bands',
    '写 IMEI（需先修改）': 'Write IMEI (edit first)',
    '确认执行？': 'Confirm execution?',
    '该操作会改变模块配置。': 'This changes module configuration.',
    '会立即断开数据连接，正在上网会掉线。': 'Drops the data connection immediately.',
    'USB 会重新枚举，当前 ADB / 网页连接可能中断，需重新连接。': 'USB will re-enumerate; current ADB / web connection may drop and need reconnecting.',
    'USB 会重新枚举，当前连接可能中断。': 'USB will re-enumerate; the current connection may drop.',
    '锁定网络制式，若当地无 5G 覆盖会直接掉网。': 'Locks the RAT. No 5G coverage here means losing the connection.',
    '锁定网络制式，若当地无 4G 覆盖会直接掉网。': 'Locks the RAT. No 4G coverage here means losing the connection.',
    '锁定 5G 频段，频段不匹配会直接掉网。': 'Locks the 5G band. A mismatch means losing the connection.',
    '恢复全频段搜索。': 'Restores full-band search.',
    '写入 IMEI 是不可逆操作，且示例值是占位符（全 0）。直接发送会把 IMEI 写成无效值。': 'Writing IMEI is irreversible, and the sample value is a placeholder (all zeros). Sending it as-is will write an invalid IMEI.',
    '已载入输入框，请修改后再回车执行': 'loaded into the input box, edit it before pressing Enter',
    '已取消：': 'Cancelled: ',
    '确定要重启模块吗？': 'Reboot the module?',
    '✅ CFUN=1 (全功能)': '✅ CFUN=1 (Full)',
    '⏸ CFUN=0 (最小功能)': '⏸ CFUN=0 (Minimum)',
    '💤 CFUN=4 (飞行模式)': '💤 CFUN=4 (Airplane)',
    '设置 CFUN=0（最小功能）？': 'Set CFUN=0 (minimum function)?',
    '设置 CFUN=4（飞行模式，关闭射频）？': 'Set CFUN=4 (airplane mode, RF off)?',
    'CFUN 0: 最小功能 / 4: 飞行模式(关闭射频) / 1: 全功能': 'CFUN 0: minimum / 4: airplane (RF off) / 1: full',
    '每次返回 +CCPUTEMP:': 'Each response +CCPUTEMP:',
    '原始:': 'Raw:',

    /* ---- 短信页 ---- */
    '收件箱': 'Inbox',
    '短信中心': 'SMS Center',
    '短信内容': 'Message',
    '短信详情': 'Message Details',
    '收件人号码': 'Recipient',
    '号码': 'Number',
    '时间': 'Time',
    '合并': 'Merged',
    '长短信（分片已自动合并）': 'Long SMS (segments auto-merged)',
    '输入短信内容...': 'Enter message...',
    '请输入收件人号码': 'Please enter a recipient number',
    '请输入短信内容': 'Please enter message content',
    '含中文/表情单条上限 70 字符': 'Max 70 chars per SMS with CJK/emoji',
    '纯英文/数字单条上限 160 字符': 'Max 160 chars per SMS (ASCII)',
    '确定删除短信 #': 'Delete SMS #',
    '· UCS2 中文': '· UCS2 Chinese',
    '字': ' chars',
    '个）': ')',

    /* ---- AT 命令页 ---- */
    '命令终端': 'Terminal',
    '命令行': 'Command Line',
    '💻 AT 控制台': '💻 AT Console',
    '🐧 Linux 终端': '🐧 Linux Shell',
    'Linux 终端': 'Linux Shell',
    '预设命令库': 'Preset Commands',
    '输入 AT 命令，例如 AT+CSQ': 'Enter AT command, e.g. AT+CSQ',
    '输入 Linux 命令，例如 free -m': 'Enter Linux command, e.g. free -m',
    '筛选预设命令…': 'Filter presets…',
    '命令必须以 AT 开头': 'Command must start with AT',
    '命令': 'Command',
    '显示模块 ID 信息': 'Module ID Info',
    '版本查询': 'Version',
    'QCN 版本查询': 'QCN Version',
    '读取 CPU 区域温度': 'CPU Zone Temperature',
    '查询 IMEI': 'Query IMEI',
    '查询 IMSI': 'Query IMSI',
    '查询 SIM 卡状态': 'Query SIM Status',
    '查询功能模式': 'Query Function Mode',
    '读取电源电压': 'Read Supply Voltage',
    '网络详情': 'Network Details',
    'APN 列表': 'APN List',
    '5G 注册': '5G Registration',
    'USB 配置': 'USB Config',
    '重启模块 ': 'Reboot Module ',
    '⚠️ 出于安全考虑，本终端仅允许只读/查询命令，写操作与危险命令会被拒绝。': '⚠️ For safety this shell allows read-only commands; write/dangerous commands are rejected.',
    '警告：请在了解命令作用后再执行，错误的命令可能导致模块异常。': 'Warning: understand a command before running it — wrong commands may break the module.',
    'SIM8260 AT Terminal v1.1': 'SIM8260 AT Terminal v1.1',
    '输入 AT 命令后回车执行，或从下方预设命令选择': 'Type an AT command and press Enter, or pick a preset below',

    /* ---- 设置页 ---- */
    '关于': 'About',
    'WebUI 版本': 'WebUI Version',
    '部署路径': 'Deploy Path',
    '技术栈': 'Tech Stack',
    'HTTPS + Basic 认证': 'HTTPS + Basic Auth',
    '登录与密码': 'Login & Password',
    '登录认证': 'Authentication',
    '修改密码': 'Change Password',
    '当前密码': 'Current Password',
    '新密码': 'New Password',
    '确认新密码': 'Confirm New Password',
    '请输入当前密码': 'Please enter current password',
    '请输入新密码': 'Please enter a new password',
    '新密码至少 6 位': 'New password must be at least 6 chars',
    '两次输入的新密码不一致': 'New passwords do not match',
    '重置为默认 (admin/admin)': 'Reset to Default (admin/admin)',
    '将密码重置为 admin/admin？\n（仅在认证未启用时可用）': 'Reset password to admin/admin?\n(only when auth is disabled)',
    '认证已启用，需通过 ADB shell 删除 .htpasswd 才能重置': 'Auth is enabled — delete .htpasswd via ADB shell to reset',
    '无认证（首次访问会提示设置）': 'No auth (prompted on first visit)',
    '认证类型': 'Auth Type',
    '默认用户名': 'Default User',
    '⚠️ 修改密码只会影响 WebUI 登录认证（.htpasswd），不会改变模块本身。请牢记新密码。': '⚠️ Changing the password only affects WebUI login (.htpasswd), not the module itself. Remember it.',
    '「重置为默认」仅在认证未启用（首次初始化）时可用；已启用后如需恢复，请通过 ADB shell 删除 .htpasswd 文件。': '"Reset to default" only works when auth is disabled (first init). Afterwards, delete .htpasswd via ADB shell.',
    'USB 网卡形态': 'USB NIC Mode',
    'USB 速率': 'USB Speed',
    '当前 VID:PID': 'Current VID:PID',
    '将修改 USB PID 为': 'Change USB PID to ',
    '特点和 Linux 节点': 'Notes / Linux Nodes',
    '特点 / Linux 节点': 'Notes / Linux Nodes',
    '接口组合': 'Interface Composition',
    '网卡类型': 'NIC Type',
    '总线/诊断': 'Bus / Diag',
    '9001 - NDIS/QMI · 出厂默认，高通QMI，高速率/QMAP': '9001 - NDIS/QMI · Factory default, QMI, high rate / QMAP',
    '9003 - MBIM(另一组合) · Linux cdc_mbim': '9003 - MBIM (alt) · Linux cdc_mbim',
    '9011 - RNDIS/ECM · 免驱，需 AT+NETACT 开链路': '9011 - RNDIS/ECM · Driver-free, needs AT+NETACT',
    '901E - MBIM · Win8/10/11 自带，枚举 WWAN 网卡': '901E - MBIM · Built-in on Win8/10/11, WWAN NIC',
    '902B - RNDIS+UAC · 带 USB 声卡': '902B - RNDIS+UAC · With USB audio',
    '9B2A - 诊断/下载模式 · 工厂烧录/EDL': '9B2A - Diag/Download · Factory flash / EDL',
    'MBIM(另一)': 'MBIM (alt)',
    '诊断/下载模式': 'Diag / Download',
    '出厂默认，速度快、支持 QMAP，Win 需 Simcom 驱动 · wwan0/qmiwwan0 + ttyUSB0~3': 'Factory default, fast, QMAP; needs Simcom driver on Win · wwan0/qmiwwan0 + ttyUSB0~3',
    '接口组合略异，不同固件默认值可能不同 · Linux cdc_mbim · wwan0+若干 ttyUSB': 'Slightly different composition, varies by firmware · Linux cdc_mbim · wwan0 + ttyUSBx',
    '免驱即插即用，默认需 AT+NETACT=1 开链路 · usb0': 'Driver-free; needs AT+NETACT=1 by default · usb0',
    '多枚举一个 USB 声卡，可语音通话/采集 · usb0 + snd_usb_audio': 'Extra USB audio card for voice · usb0 + snd_usb_audio',
    '较少用，工厂烧录/紧急下载(EDL/9008)或诊断 · 不枚举常规网卡': 'Rarely used: factory flash / EDL (9008) or diag · no regular NIC',
    'AT+Modem+NMEA+DIAG+RNDIS+UAC 音频': 'AT+Modem+NMEA+DIAG+RNDIS+UAC Audio',
    '将修改 USB PID 为 ': 'Change USB PID to ',
    '⚠️ 切换 USB PID 后模块会重新枚举 USB 设备，网页会短暂断开。MBIM 模式取决于 PID + 驱动的组合，需安装 Windows 驱动后由系统枚举。': '⚠️ After switching USB PID the module re-enumerates and the page disconnects briefly. MBIM depends on PID + driver; install the Windows driver first.',
    '⚠️ 切换': '⚠️ Switch',
    '\n切换后 USB 设备会重新枚举，网页可能断开。确定吗？': '\nUSB re-enumerates after switching; the page may disconnect. Continue?',
    '\n\n设备将重新枚举 USB，请稍后刷新页面。': '\n\nDevice will re-enumerate USB — refresh the page later.',
    'QCMAP 自动拨号': 'QCMAP Auto Dial',
    '自动拨号': 'Auto Dial',
    '规则 0 自动拨号': 'Rule 0 Auto Dial',
    '规则 1 自动拨号': 'Rule 1 Auto Dial',
    '规则 2 自动拨号': 'Rule 2 Auto Dial',
    '规则 3 自动拨号': 'Rule 3 Auto Dial',
    'SFE 软件加速': 'SFE Software Accel',
    'SIM 卡切换 (SMSIMCFG)': 'SIM Switch (SMSIMCFG)',
    'SIM 槽': 'SIM Slot',
    'SIM 槽 1': 'SIM Slot 1',
    'SIM 槽 2': 'SIM Slot 2',
    '当前 SIM 槽': 'Current SIM Slot',
    '切换 SIM': 'Switch SIM',
    '切换到 SIM 槽': 'Switch to SIM Slot ',
    '确定切换到 SIM 槽': 'Switch to SIM slot ',
    '槽 1 状态': 'Slot 1 Status',
    '槽 2 状态': 'Slot 2 Status',
    'DSSA (双卡单待)': 'DSSA (Dual SIM Single Active)',
    'DSSA（双卡单待）': 'DSSA (Dual SIM Single Active)',
    'SSSA (单卡单待)': 'SSSA (Single SIM Single Active)',
    'SSSA（单卡单待）': 'SSSA (Single SIM Single Active)',
    'ADB 状态': 'ADB Status',
    '修改 IMEI': 'Change IMEI',
    '当前 IMEI': 'Current IMEI',
    '新 IMEI（15 位数字）': 'New IMEI (15 digits)',
    '请输入 15 位数字 IMEI': 'Please enter a 15-digit IMEI',
    '确定写入新 IMEI': 'Write new IMEI',
    '修改 IMEI 属敏感操作，请确保符合当地法规与运营商要求。': 'Changing IMEI is sensitive — comply with local regulations and operator requirements.',
    '？\n⚠️ 修改 IMEI 可能违反当地法规，请确认合规。\n写入后需重启模块生效。': '?\n⚠️ Changing IMEI may violate local law — confirm compliance.\nEffective after reboot.',
    '（15 位数字，不带引号），修改后需重启模块生效。': '(15 digits, no quotes); effective after reboot.',
    '例如 864680060000480': 'e.g. 864680060000480',
    '当前状态': 'Current Status',
    '可选': 'Optional',

    /* ---- 提示 / 说明 ---- */
    'ⓘ 修改 APN 后需要重新拨号才会生效。IMS / SOS 为系统保留 Profile，修改可能导致 IMS 或紧急呼叫异常，保存时会二次确认。': 'ⓘ Re-dial after changing APN. IMS / SOS are reserved profiles — changing them may break IMS or emergency calls (a confirmation is required).',
    'ⓘ 立即生效且掉电保存；切换后模块重新搜网，短暂断网属正常。': 'ⓘ Effective immediately and persisted; the module re-scans afterwards — brief disconnection is normal.',
    '⚠️ 频段用': '⚠️ Bands use',
    '分隔（如 B1:B3:B5）。部分频段/命令需重启或随 RAT 选择顺序生效。误锁可能': ' separated (e.g. B1:B3:B5). Some bands/commands need a reboot or take effect per RAT order. Wrong locks may ',
    '勾选所需频段，点击「应用所选」写入锁定。': 'Check the bands you need, then click "Apply Selected" to lock.',
    '⚠️ 「扫描运营商」使用': '⚠️ "Scan Operators" uses',
    '运营商/网络': 'Operator/Network',
    '列表（PLMN），并非相邻小区扫描。本模块未提供 AT 级"小区扫描"命令；锁小区需用下方 PCI + EARFCN/频率。NR 锁小区命令手册标注「尚未验证」，部分固件可能不支持。': ' list (PLMN), not neighbor-cell scanning. This module has no AT-level "cell scan" command; lock cells via PCI + EARFCN/frequency below. The NR cell-lock command is marked "unverified" and may be unsupported.',
    '本模块未提供 AT 级': 'This module has no AT-level ',
    '和': ' and ',
    '或': ' or ',
    '至少 6 位': 'At least 6 chars',
    '被拒绝': 'Rejected',
    '无': 'None',
    '、': ', ',
    '；': '; ',
    '：': ': ',
    '吗？': '?',
    '1=连接 0=断开；': '1=connected 0=disconnected; ',

    /* ---- 语言切换自身 ---- */
    '切换为中文': 'Switch to Chinese',
    'Switch to English': 'Switch to English',
    '语言': 'Language',
    'Language': 'Language',

    /* ---- 补充：动态拼接句中的片段 / 短句 ---- */
    '再次输入': 'Re-enter',
    '冒号 :': 'Colon :',
    '请输入': 'Please enter ',
    '如 13800138000': 'e.g. 13800138000',
    '- 未知': '- Unknown',
    '📶 连接方式：': '📶 Connection:',
    '切换立即生效，仅一个槽激活，可能短暂脱网。': 'Effective immediately; only one slot can be active — brief disconnection is possible.',
    '若有其它 SIM 操作正在进行则不允许切换。8300G 5G 模块及 DSDA/DSDA 平台不支持本命令。': 'Switching is rejected while another SIM operation is running. Not supported on 8300G 5G modules or DSDS/DSDA platforms.',
    '若有其它 SIM 操作正在进行则不允许切换。8300G 5G 模块及 DSDS/DSDA 平台不支持本命令。': 'Switching is rejected while another SIM operation is running. Not supported on 8300G 5G modules or DSDS/DSDA platforms.',
    '该命令手册标注尚未验证，可能不支持。': 'This command is marked unverified in the manual and may be unsupported.',
    '设备将重新枚举 USB，请稍后刷新页面。': 'The device will re-enumerate USB — refresh the page later.',
    '切换后 USB 设备会重新枚举，网页可能断开。确定吗？': 'USB re-enumerates after switching; the page may disconnect. Continue?',
    '当前是系统保留 APN「': 'is a reserved APN "',
    '」，修改可能导致 IMS 或紧急呼叫异常。确定继续？': '" — changing it may break IMS or emergency calls. Continue?',
    '切换后模块会重新搜网，可能短暂断网。': 'The module re-scans after switching; brief disconnection is possible.',
    '立即生效，可能脱网。': 'Effective immediately; may go offline.',
    '，仅一个槽可被激活。切换成功后模块返回': ', only one slot can be active. After switching the module returns ',
    '，返回的是可见': ', which returns visible ',
    '，当前': ', current '
  };

  /* ---- 预构建匹配表，按长度降序 ----
     · PREFIX：key 长度 >= 4，用于「前缀 + 动态值」文案（如「请求失败：xxx」）
     · SUBSTR：key 长度 >= 6，用于「动态值 + 中文片段」文案
       （如「Profile 1 当前是系统保留 APN「IMS」…」，中文不在开头）
       长度门槛 6 是为了避免「流」「分」这类单字 key 误伤其它词。 */
  var PREFIX_KEYS = Object.keys(DICT).filter(function (k) { return k.length >= 4; })
                    .sort(function (a, b) { return b.length - a.length; });
  var SUBSTR_KEYS = Object.keys(DICT).filter(function (k) { return k.length >= 6; })
                    .sort(function (a, b) { return b.length - a.length; });

  /* =============================================================
     核心
     ============================================================= */
  var lang = DEFAULT;
  var _textOrig = new WeakMap();   // Text node -> 原始中文
  var _attrOrig = new WeakMap();   // Element -> { placeholder: 原文, title: 原文, ... }
  var _titleOrig = null;
  var _applying = false;

  var ATTRS = ['placeholder', 'title', 'alt', 'aria-label'];

  function get() {
    try { return localStorage.getItem(KEY) || DEFAULT; }
    catch (e) { return DEFAULT; }
  }

  // 查表：精确 → 前缀 → 子串（依次放宽，覆盖动态拼接的文案）
  function lookup(s) {
    if (!s) return null;
    var v = DICT[s];
    if (v !== undefined) return v;
    var i, k;
    for (i = 0; i < PREFIX_KEYS.length; i++) {
      k = PREFIX_KEYS[i];
      if (s.length > k.length && s.indexOf(k) === 0) return s.replace(k, DICT[k]);
    }
    for (i = 0; i < SUBSTR_KEYS.length; i++) {
      k = SUBSTR_KEYS[i];
      if (s.indexOf(k) >= 0) return s.replace(k, DICT[k]);
    }
    return null;
  }

  // 翻译任意字符串（不命中则原样返回）
  function t(s) {
    if (!s || lang === ZH) return s;
    var trimmed = String(s).trim();
    var v = lookup(trimmed);
    return (v === null) ? s : String(s).replace(trimmed, v);
  }

  // 带 data-i18n-skip 的元素（如语言切换按钮本身）不参与翻译。
  // 必须向上查整条祖先链，不能只看直接父元素：AT 终端、短信原文这些展示区
  // 的内容是 JS 动态生成的深层节点（<div id=terminal><div><span>响应</span>），
  // 只判直接父元素挡不住，会把模块原始返回（中文短信正文、运营商名等）翻掉。
  // 不缓存结果：缓存持有元素强引用会阻止 DOM 节点回收，页面上长时间刷新会涨内存。
  function skip(el) {
    var cur = el;
    while (cur && cur.nodeType === 1) {
      if (cur.getAttribute && cur.getAttribute('data-i18n-skip') !== null) return true;
      cur = cur.parentNode;
    }
    return false;
  }

  function trTextNode(node) {
    if (!node || node.nodeType !== 3) return;
    var parent = node.parentNode;
    if (!parent) return;
    var tag = parent.nodeName;
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEXTAREA') return;
    if (skip(parent)) return;

    var orig = _textOrig.get(node);
    if (orig === undefined) { orig = node.nodeValue; _textOrig.set(node, orig); }
    var trimmed = orig.trim();
    if (!trimmed) return;

    var target;
    if (lang === ZH) {
      target = orig;
    } else {
      var v = lookup(trimmed);
      target = (v === null) ? orig : orig.replace(trimmed, v);
    }
    if (node.nodeValue !== target) node.nodeValue = target;
  }

  function trAttrs(el) {
    if (!el || el.nodeType !== 1 || skip(el)) return;
    var tag = el.nodeName;
    // 按钮类 input 的 value 也是可见文案
    var list = ATTRS;
    if (tag === 'INPUT') {
      var ty = (el.getAttribute('type') || '').toLowerCase();
      if (ty === 'button' || ty === 'submit' || ty === 'reset') list = ATTRS.concat(['value']);
    }
    var store = _attrOrig.get(el);
    if (!store) { store = {}; _attrOrig.set(el, store); }
    for (var i = 0; i < list.length; i++) {
      var a = list[i];
      if (!el.hasAttribute(a)) continue;
      if (store[a] === undefined) store[a] = el.getAttribute(a) || '';
      var orig = store[a];
      var trimmed = orig.trim();
      if (!trimmed) continue;
      var target;
      if (lang === ZH) {
        target = orig;
      } else {
        var v = lookup(trimmed);
        target = (v === null) ? orig : orig.replace(trimmed, v);
      }
      if (el.getAttribute(a) !== target) el.setAttribute(a, target);
    }
  }

  // 遍历并翻译（不检查 _applying，由调用方控制重入）
  function applyTo(root) {
    var walker = document.createTreeWalker(
      root || document.body,
      NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT,
      null, false
    );
    var n;
    while ((n = walker.nextNode())) {
      if (n.nodeType === 3) trTextNode(n);
      else trAttrs(n);
    }
  }

  function trTitle() {
    if (!document.title) return;
    if (_titleOrig === null) _titleOrig = document.title;
    document.title = (lang === ZH) ? _titleOrig : t(_titleOrig);
  }

  function apply() {
    if (_applying) return;
    _applying = true;
    try {
      if (document.body) applyTo(document.body);
      trTitle();
    } catch (e) {}
    _applying = false;
  }

  function set(next) {
    lang = (next === EN) ? EN : ZH;
    try { localStorage.setItem(KEY, lang); } catch (e) {}
    document.documentElement.setAttribute('lang', lang === ZH ? 'zh-CN' : 'en');
    apply();
    syncBtn();
  }

  function toggle() { set(get() === ZH ? EN : ZH); }

  /* =============================================================
     顶栏注入「中 / EN」切换按钮
     ============================================================= */
  function injectBtn() {
    var foot = document.querySelector('.topbar-foot');
    if (!foot || foot.querySelector('.lang-toggle')) return;
    var btn = document.createElement('button');
    btn.className = 'lang-toggle';
    btn.type = 'button';
    btn.setAttribute('data-i18n-skip', '1');   // 按钮自身文案不参与翻译
    btn.setAttribute('aria-label', 'Language');
    foot.insertBefore(btn, foot.firstChild);
    btn.addEventListener('click', toggle);
    syncBtn();
  }

  function syncBtn() {
    var btn = document.querySelector('.lang-toggle');
    if (!btn) return;
    var cur = get();
    btn.textContent = (cur === ZH) ? 'EN' : '中';
    btn.title = (cur === ZH) ? 'Switch to English' : '切换为中文';
  }

  /* =============================================================
     alert / confirm / prompt 包装：原生对话框 DOM 扫描不到，
     在调用处直接翻译消息文本（含拼接文案的前缀匹配）。
     ============================================================= */
  (function wrapDialogs() {
    try {
      var _alert = window.alert, _confirm = window.confirm, _prompt = window.prompt;
      if (typeof _alert === 'function') {
        window.alert = function (msg) { return _alert.call(window, t(msg)); };
      }
      if (typeof _confirm === 'function') {
        window.confirm = function (msg) { return _confirm.call(window, t(msg)); };
      }
      if (typeof _prompt === 'function') {
        window.prompt = function (msg, def) { return _prompt.call(window, t(msg), def); };
      }
    } catch (e) {}
  })();

  /* =============================================================
     MutationObserver：JS 动态写入的状态文案（「已连接」「加载中…」等）
     也能自动翻译，业务 JS 无需改动。
     ============================================================= */
  function startObserve() {
    if (typeof MutationObserver === 'undefined' || !document.body) return;
    var obs = new MutationObserver(function (muts) {
      if (_applying) return;                 // 忽略自己触发的变更，避免死循环
      _applying = true;
      try {
        for (var i = 0; i < muts.length; i++) {
          var m = muts[i];
          if (m.type === 'characterData') { trTextNode(m.target); continue; }
          var added = m.addedNodes || [];
          for (var j = 0; j < added.length; j++) {
            var n = added[j];
            if (n.nodeType === 3) trTextNode(n);
            else if (n.nodeType === 1) applyTo(n);
          }
        }
      } catch (e) {}
      _applying = false;
    });
    obs.observe(document.body, { childList: true, subtree: true, characterData: true });
  }

  /* =============================================================
     初始化
     ============================================================= */
  lang = get();
  document.documentElement.setAttribute('lang', lang === ZH ? 'zh-CN' : 'en');

  function boot() {
    injectBtn();
    apply();
    startObserve();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  window.wbI18n = {
    get: get, set: set, toggle: toggle, t: t,
    ZH: ZH, EN: EN,
    apply: apply,
    dict: DICT
  };
})();
