# SIM8260 WebUI · 5G 模块端管理面板

> 一套跑在 **SIM8260（SDX62 平台）5G 模块**上的 Web 管理界面，直接通过 CGI/shell 发 AT 命令与模块交互，浏览器访问即可。
> A lightweight web management UI for SIM8260 (SDX62) 5G modules — talk to the modem over AT via CGI, no app needed.
>
> 🔗 开源地址：https://github.com/SAddr/sim8260webui

![Platform](https://img.shields.io/badge/platform-SIM8260%20%2F%20SDX62-blue)
![License](https://img.shields.io/badge/license-CC%20BY--NC%204.0-blue)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

---

## 📑 目录

- [特性](#-特性)
- [目录结构](#-目录结构)
- [快速开始](#-快速开始)
- [安装（Windows 一键）](#-安装windows-一键)
- [手动部署](#-手动部署)
- [AT 串口桥接架构](#-at-串口桥接架构)
- [CGI 并发保护](#-cgi-并发保护)
- [NAND 写入治理](#-nand-写入治理)
- [真机验证结果](#-真机验证结果sim8260--sdx62)
- [已修复的缺陷](#-已修复的缺陷)
- [与参考项目的差异](#-与参考项目的差异)
- [注意事项](#-注意事项)
- [致谢](#-致谢)
- [关于作者](#-关于作者)
- [License](#license)

---

## ✨ 特性

- 🎨 **现代深色科技风界面**：玻璃拟态卡片 + 渐变信号环 + 4×4 MIMO 天线柱状图
- 📊 **实时仪表盘**：信号强度、网络模式、流数/调制、IP 地址等每 10 秒自动刷新
- 📡 **信号详情页**：NR/LTE 双制式 RSRP/RSRQ/SINR/RSSI，每根天线单独显示
- 🌐 **网络管理**：QCMAP 连接/断开、APN 配置、网口模式切换、LAN DHCP 查看
- 💻 **AT 命令终端**：浏览器内直接发任意 AT 命令，带历史记录（上下键）和快捷命令
- 💬 **短信收发**：列表 / 读取 / 发送 / 删除
- ⚙️ **设置页**：改密码、USB PID 切换、ADB 开关、QCMAP 自动拨号配置
- 📱 **响应式**：PC 和手机都能用
- 🌏 **中/英双语**：默认中文，可切换并记忆（localStorage）

---

## 📁 目录结构

```
simcom-webui/
├── www/                     # 前端页面
│   ├── index.html           # 总览仪表盘
│   ├── signal.html          # 信号详情 (NR+LTE+4天线)
│   ├── network.html         # 网络配置 (拨号/APN/网口)
│   ├── device.html          # 设备信息 + CFUN
│   ├── atcmd.html           # AT 命令终端
│   ├── sms.html             # 短信
│   ├── settings.html        # 设置 / 改密码
│   ├── css/styles.css       # 样式 (深色科技风)
│   └── js/
│       ├── wb-theme.js      # 主题初始化 + 全局 fetch 超时/串行化封装
│       └── i18n.js          # 中/英双语切换（默认中文，切换后存 localStorage）
├── cgi-bin/
│   ├── libat.sh             # 公共库：设备探测/原子锁/清缓冲/发命令
│   ├── atcmd                # CGI：发任意 AT 命令
│   ├── sms                  # CGI：短信 list/read/send/del
│   ├── deviceinfo           # CGI：设备静态信息（AT 取一次后缓存到内存）
│   ├── shell                # CGI：受限只读 Linux 终端
│   ├── sysinfo              # CGI：系统资源信息（不占串口）
│   └── password             # CGI：改密码 / 查询认证状态
├── systemd/
│   ├── lighttpd.conf        # lighttpd 配置（日志/临时目录指向内存）
│   └── simcom-webui.service # lighttpd 的 systemd 服务
├── socat-at-bridge/         # AT 串口桥接
│   ├── socat-armel-static   # ARM 静态编译 socat 二进制
│   ├── socat-smd8.service   # ⚠️ 参考项目遗留模板，**不再启用**（见"唯一 owner"说明）
│   ├── socat-smd8-to-ttyIN2.service   # ⚠️ 同上
│   ├── socat-smd8-from-ttyIN2.service # ⚠️ 同上
│   ├── start_socat_bridge.sh # 启动入口（内部委托看门狗）
│   ├── bridge_watchdog.sh   # 桥接唯一 owner：拉起 socat+两条腿，巡检+真实AT探活+异常重建
│   ├── bridge_status.sh     # 桥接一键自检 9 项（判断"是不是有服务没起来"）
│   └── fix_systemd_autostart.sh # 开机自愈+诊断（只维护 lighttpd 单元；/etc 只读时兜底）
├── at-runenv.sh             # 运行时目录解析（只落在内存 fs，避免写 NAND）
├── deploy_to_modem.bat      # Windows 一键部署
├── install.sh               # 模块端安装脚本
├── uninstall.sh             # 卸载脚本
└── probe_wwan_smartfren.sh  # WWAN 探测辅助脚本
```

---

## 🚀 快速开始

> 前提：模块已开 ADB（`AT+CUSBCFG=usbadb,1`）、已装 Entware + lighttpd（`opkg install lighttpd`）

1. 把 `adb.exe` + `AdbWinApi.dll` + `AdbWinUsbApi.dll` 放到本项目目录（与 `deploy_to_modem.bat` 同级，可选，否则用 PATH 里的 adb）；
2. 双击 `deploy_to_modem.bat`——脚本会自动探测设备 → `adb root` → 推送文件 → 跑 `install.sh`；
3. 浏览器访问 `http://192.168.225.1:8888/`，默认账号 `admin / admin`。

详见下方 [安装（Windows 一键）](#-安装windows-一键) 与 [手动部署](#-手动部署)。

---

## 🔧 安装（Windows 一键）

> 前提：模块已开 ADB（`AT+CUSBCFG=usbadb,1`）、已装 Entware + lighttpd（`opkg install lighttpd`）

把 `adb.exe` + `AdbWinApi.dll` + `AdbWinUsbApi.dll` 放到本项目目录（与 `deploy_to_modem.bat` 同级，可选，否则用 PATH 里的 adb），然后双击：

```
deploy_to_modem.bat
```

脚本会自动：探测设备 → adb root → 推送文件 → 跑 install.sh。完成后浏览器访问：

```
http://192.168.225.1:8888/
默认账号：admin / admin
```

---

## 🔌 手动部署（不用 bat）

```bash
# 1. 推送到模块
adb push simcom-webui /tmp/simcom-webui
# 2. 安装
adb shell sh /tmp/simcom-webui/install.sh
```

---

## 🔌 AT 串口桥接架构

SIM8260 的 AT 口 `/dev/smdX` 如果和电脑 USB AT COM 口共用通道会冲突，导致两边抢读。本项目采用参考项目同款 **socat PTY 桥接**，把内部 AT 口隔离出来：

```
模块基带 /dev/smd8            socat PTY 桥                CGI
   │                             │                          │
   ├── cat smd8 > ttyIN2 ───────►│  ttyIN2 ──┐              │
   │                             │           └─► ttyOUT2 ───┼──► atcmd/sms 只用 ttyOUT2
   ◄── cat ttyIN2 > smd8 ────────│  ttyIN2 ◄──┘              │
```

- **唯一 owner = `bridge_watchdog.sh`**：由它拉起 1 个 socat + 2 条搬运腿并持续守护。
  ```sh
  # 看门狗内部就是这三条命令
  socat-armel-static -d -d pty,link=/dev/ttyIN2,... pty,link=/dev/ttyOUT2,...
  cat /dev/smd8  > /dev/ttyIN2   # 读腿（模块→桥）
  cat /dev/ttyIN2 > /dev/smd8    # 写腿（桥→模块）
  ```
- ⚠️ **不再使用参考项目的 3 个 `socat-*.service`**（`socat-smd8.service` +
  `-to-ttyIN2` + `-from-ttyIN2`）。原因：它们会和看门狗**同时**拉起同一套部件 → 两个 socat
  抢建 `/dev/ttyIN2`、多个 `cat` 抢读 `/dev/smd8` → **"时通时不通 / AT 全部转圈圈"**。
  三处已对齐成"只有看门狗一个 owner"：① `install.sh` 停用+删除这三个单元；
  ② 看门狗启动时 `disarm_systemd_units()` 兜底；③ `fix_systemd_autostart.sh` 不再
  重建/enable 它们（只保留 `simcom-webui.service` 管 lighttpd）。
  同理 lighttpd 也只有一个 owner（systemd 优先，`autostart.sh` 仅在其未 enable 时 setsid 兜底）。
- **AT 设备探测顺序**（桥接不通时 CGI 直连）：`/dev/ttyOUT2` → `/dev/smd8` → `/dev/smd7` → `/dev/smd11`
- install.sh 会根据实际探测到的设备动态生成命令（不硬编码 smd8）

> 备注：静态编译的 `socat-armel-static` 在本平台上 `pty,link=` 选项可能被静默忽略，
> 看门狗 `bridge_watchdog.sh` 里已做兜底 —— 从 `/proc/<pid>/fd` 解析真实 pts 并手动建 symlink。
> 注意方向只能在**两条搬运腿起来之后**用真实探活判定（见 `restart_bridge`），
> 启动 socat 时探活必然超时，不能拿它当"接反了"的依据。


**看门狗**：

```bash
sh socat-at-bridge/bridge_watchdog.sh            # 常驻（开机自启已接）
sh socat-at-bridge/bridge_watchdog.sh --once     # 单次全量巡检+修复，退出码 0=健康
sh socat-at-bridge/bridge_watchdog.sh --restart  # 立刻重建整桥
sh socat-at-bridge/bridge_watchdog.sh --sweep    # 只清孤儿读线程
sh socat-at-bridge/bridge_watchdog.sh --stop     # 停桥+看门狗
sh socat-at-bridge/bridge_watchdog.sh --status   # 只看健康，不修
sh socat-at-bridge/bridge_watchdog.sh --rundir   # 诊断：日志/心跳/临时文件到底写在哪个 fs（有没有写 NAND）
cat /tmp/simcom-webui/log/bridge.log             # 看门狗日志（含"检查模式：idle → active"切换记录）
```

> 探活会往 AT 口写 `"AT"`，所以看门狗**必须和 CGI 抢同一把锁**（路径由 `at-runenv.sh` 统一解析），
> 否则 `AT`/`OK` 会插进正在执行的 CGI 响应里造成前端解析错乱（已实现；抢不到锁就跳过本轮，
> 不算失败）。L1 之所以优先信 web 侧心跳，也是为了少抢锁、不干扰正常浏览。

> 排障提示：`bridge_status.sh` 的第 [8] 项会直接告诉你**看门狗此刻为什么没在探活**
> （active=web 自己在证明它通 / idle=静默期兜底模式）。

3. **前端没有请求超时 + 并发 AT 排队**：原生 `fetch` 无超时，后端一卡浏览器就永远转圈、且永不报错。
   → 修复：`js/wb-theme.js` 全局包裹 `fetch`，45s 超时自动 abort 并弹出可见提示条（12s 节流）；
   同时在该包装里把 `/cgi-bin/atcmd` 的请求**在客户端排成一条链**（串行化）。
   进入网络页会同时触发 `loadWWAN`/`loadBand`/`loadCell`/`loadNetMode`（`loadBand` 内还有 `Promise.all`），
   若全并发打到串口，后到的请求只能在服务端排队，一条卡住就会一起等到超时；
   串行化后每个请求的超时从「真正开始」计时，行为可预期。
   另外 `libat.sh` 的锁等待上限从 **300 秒收敛到 60 秒**（原值会让页面干转 5 分钟）。


## ⚙️ CGI 并发保护

- 多个页面会并发发 AT 命令 → 后端 CGI 用 `mkdir` 原子锁串行化（锁路径由 `at-runenv.sh` 解析，落在内存 fs）
- 锁带时间戳，超过 30 秒判定僵尸锁自动回收（> 最长命令 sms send 约 20s，避免误回收）；
  锁目录存在但**始终没有 `ts`** 超过 10s 也判定僵尸（持有者死在 `mkdir` 与写 `ts` 之间，旧逻辑回收不掉）
- 锁等待上限 60 秒（正常 12 命令排队 ≈ 36s 够用，异常时快速失败而不是干转 5 分钟）
- 前端 `wb-theme.js` 另外把 `/cgi-bin/atcmd` 请求在客户端串行化成一条链，避免并发堆在服务端排队
- 每次命令前用固定 150ms 短读清空 PTY 残留，避免响应串线/冗余
- `send_at` 用「写命令 + 后台 cat 读 + 轮询 OK/ERROR/超时」，抓到终止符后先读静默再 kill，保证零残留

---

## 💾 NAND 写入治理（日志/心跳/锁/临时文件不写闪存）

> **背景**：本模块是 **1GB NAND + UBIFS**，擦写寿命有限，而本项目的"高频写入"其实不少：
> 每次 AT 往返写心跳（开自动刷新≈每 5s 一次）、每个请求写一次锁时间戳、每条命令一个 `mktemp` 临时文件、
> 以及看门狗/lighttpd/开机自启的 append 日志。这些若落在 UBIFS 上就是持续磨闪存。

关键点：嵌入式平台上 **`/tmp` 不保证是 tmpfs**（有些固件直接把 `/tmp` 放在 rootfs 里），所以**不做任何假设**。
新增 `at-runenv.sh` 统一解析：直接读 `/proc/mounts` 判定 fs 类型，只在 `tmpfs`/`ramfs` 上建目录，
按 `/dev/shm → /run → /tmp → /var/tmp` 顺序取第一个可写的内存目录；全都不行才退回 `/tmp` 并把
`AT_RUN_IS_RAM=0` 暴露给上层**主动告警**（`bridge_status.sh` 第 [9] 项、看门狗启动日志、`--rundir`）。

所有 CGI 与桥脚本 `source` 同一个 `at-runenv.sh`，因此**锁路径、心跳路径、日志目录两边看到的一定一致**。

| 写入源 | 原落点 | 现落点 |
|---|---|---|
| AT 心跳 `at_hb` / `at_hb_start` | `/tmp/simcom-webui-bridge/` | `$RUNDIR/bridge/`（内存，且带 45s 写间隔） |
| 串口互斥锁 `atcmd.lock` | 各自硬编码 `/tmp/...` | `$RUNDIR/atcmd.lock`（CGI 与看门狗共用同一把） |
| 看门狗 pidfile ×4 / bridge.log | `/tmp/simcom-webui-bridge/` | `$RUNDIR/bridge/`、`$RUNDIR/log/` |
| CGI 临时文件（`mktemp`） | 系统默认 | `TMPDIR=$RUNDIR/tmp` |
| lighttpd errorlog / tmpdir | 默认（可能写盘） | `@RUNDIR@/…`（install.sh 安装时替换） |
| lighttpd **accesslog** | 若开启则每请求一次写 | **刻意不开启**（单客户端，排查看 errorlog 即可） |
| 开机自启三份日志 | `/tmp` append，跨重启无限增长 | `$RUNDIR/log/`，且**每次开机 `: >` 清空** |

补充：
- 日志做**字节封顶**（`at_log_cap`：超 256KiB 截断为最近 64KiB），即使兜底落在 `/tmp` 也不会写满分区。
- 看门狗 `_kill_pidfile` 带 cmdline 关键字匹配，避免 pid 复用误杀；探活锁带僵尸回收。
- **密码文件 `.htpasswd` 例外**：它必须持久保存（落 `/userdata`），不属于本次治理范围。

自检（确认真的没在写 NAND）：

```bash
sh .../bridge_watchdog.sh --rundir     # 直接打印日志/心跳/锁/临时文件的落点 + fs 类型 + 是否在内存
sh .../bridge_status.sh                # 第 [9] 项给结论
```

---

## ✅ 真机验证结果（SIM8260 / SDX62）

`/proc/mounts` 实测拓扑：`/dev/shm`、`/run`、`/tmp` **三个都是 tmpfs**；
`/etc`、`/userdata` 是 `ubi2_0`（NAND）。解析器选中的落点 = **`/dev/shm/simcom-webui`**（`AT_RUN_IS_RAM=1`）。

| 验证项 | 结果 |
|---|---|
| `at-runenv.sh` 在设备上 source | `dir=/dev/shm/simcom-webui  fs=tmpfs  ram=1` ✅ |
| lighttpd.conf 的 `@RUNDIR@` 替换 | `server.errorlog`/`tmpdir` 均 = `/dev/shm/simcom-webui/…`，无 accesslog ✅ |
| `bridge_status.sh` 9 项 | 全 `[OK]`（含第 [7] 项真实 AT 环回 **收到 OK**、第 [9] 项内存落点）✅ |
| 端到端 `curl -u admin:admin …/cgi-bin/atcmd?cmd=AT` | 返回 `OK`；首页 `200`；`sysinfo` 正常 ✅ |
| pidfile ↔ `ps` 对应 | socat / reader / writer / watchdog 四个 pid **逐一对应** ✅ |
| 稳定性（≥40s，4 个 L0 周期） | `bridge.log` 行数 **不再增长**（修复前每 10s 重建一次）✅ |
| NAND 审计 | `find /userdata/simcom-webui -name '*.log' -o -name '*.pid' -o -name 'at_hb*'` → **空** ✅ |
| 桥进程唯一性 | 1×socat、1×读腿、1×写腿、1×看门狗守护；旧 `socat-*.service` 已清除 ✅ |

---

## 🐞 已修复的缺陷（本轮代码走查）

**后端 / 桥脚本**

| 缺陷 | 后果 | 修复 |
|---|---|---|
| `send_at_batch` 漏登记后台读线程 | 批量命令（最长 8~20s）期间浏览器切页 → cat 变孤儿偷吃响应，**AT 全部转圈圈** | 补 `AT_BG_PIDS` 登记 |
| `acquire_at_lock` 无法回收"无 ts"僵尸锁 | 持有者死在 `mkdir`↔写 `ts` 之间 → 之后**每个请求都干等满 60s**，重启前不可自愈 | 加 `_lock_nots` ≥10s 强制回收 |
| `pkill`/`kill` 按 pidfile 盲杀 | pid 复用 → 误杀无关进程 | `_kill_pidfile` 增加 cmdline 关键字匹配 |
| 手工建 PTY symlink 时用探活判方向 | 此刻两条腿还没起，探活必然失败 → 方向被**必然交换**（自环） | 改为确定性 fd 顺序；方向纠正移到两条腿起来之后的 `restart_bridge` |
| `socat` 起来但 `pty,link=` 失效 | `/dev/ttyIN2\|ttyOUT2` 不存在，桥不可用 | 从 `/proc/<pid>/fd` 捞 pts 手工建 symlink（回归修复） |
| 日志无限增长 | 长期运行写满分区 / 磨闪存 | `at_log_cap` 字节封顶 + 开机清空 |
| `acquire_at_lock` 参数写死 `/tmp` | 与看门狗抢的不是同一把锁 → 探活插进 CGI 响应 | 统一由 `at-runenv.sh` 解析 |
| `install.sh` 未安装 `at-runenv.sh` / 未替换 `@RUNDIR@` | 所有 CGI 静默退回 `/tmp`（可能是 NAND），**NAND 治理失效** | 补拷贝 + 补 `sed` 替换 |
| **桥接双 owner**：`install.sh` enable 了 3 个 `socat-*.service`，而桥实际归看门狗管 | 两套同时拉起 → 两个 socat 抢 `/dev/ttyIN2`、多个 `cat` 抢读 `/dev/smd8` → **时通时不通 / AT 全部转圈圈**（真机复现） | `install.sh` 改为停用+删除这些单元，走 `start_socat_bridge.sh` 起桥 |
| **`fix_systemd_autostart.sh` 会把上面删掉的单元又重建并 enable** | 前一步的停用被无声撤销 → 双 owner 复现 | 该脚本改为只维护 `simcom-webui.service`，桥接单元一律清除 |
| **`start_socat`/`start_leg` 用 `$!` 记 pid** | `_spawn ...&` 里 `$!` 是 ash 为跑函数而 fork 的**子 shell**，随即退出 → pidfile 存了死 pid → L0 每 10s 判"部件缺失"→**无限重建**（实测 10 分钟 20 次，pts 编号每轮都变，AT 基本不可用） | 新增 `resolve_pid()`：按 `/proc/<pid>/comm` + cmdline 关键字解析**真实** pid |
| `scan_pid "cat" "/dev/ttyIN2"` 找写腿 | socat 的 cmdline 同时含子串 `cat`（在 `socat` 里）与 `/dev/ttyIN2` → **把 socat 认成写腿** | 用 `comm` 精确区分（socat 的 comm 不是 `cat`） |
| `kill_legacy_bridge` 只杀 ppid=1 的启动器 | 旧版**读腿** `cat /dev/smd8` 的 ppid 是启动器不是 1 → 漏杀 → 与新腿抢读 AT 口 | 追加按 cmdline 含 `cat /dev/smd` 清扫，且必须在 `start_leg` 之前 |
| `autostart.sh` 与 `simcom-webui.service` 都拉 lighttpd | 两个 lighttpd 抢 8888，后 bind 的失败并反复重启 | `autostart.sh` 先看 `systemctl is-enabled`，已 enable 就交给 systemd |
| `install.sh` 直接 `cp` 正在运行的 `socat-armel-static` | `Text file busy` → 二进制更新失败 | 先写 `.new` 再 `mv` 覆盖（运行中进程仍持旧 inode，不中断桥） |
| `install.sh` 解析 HTTP 状态用 `wget -O- ... \| tail -1` | 响应正文混进结果 → 打印出 `HTTP status: server` | 改 `-O /dev/null` + 取第一行，并区分 200/30x/401 |

**CGI 安全/健壮性**

| 缺陷 | 后果 | 修复 |
|---|---|---|
| `QUERY_STRING` 未关 glob | URL 里的 `*?[]` 被 shell 当通配符匹配 cgi-bin 文件，**参数被篡改** | 加 `set -f`（atcmd/sms/shell/password） |
| `sms` 的 `index`/`num` 未校验 | `num=1"<CR>AT+CFUN=0` 可**拆出新的 AT 命令**（AT 层注入） | index 纯数字校验、num 白名单 `0-9+*#` |
| `sms` 只校验 ASCII 长度 | UCS2 长短信绕过 70 字上限 | 先编码再数 `${#CMGS_MSG}/4` |
| `shell` 黑名单裸子串 | 既误杀（`cat /proc/arm`），又能用 `wget -O`、`busybox rm`、`find -delete` 绕过 | 改词首锚定 + 补 applet/`find` 动作/敏感文件拦截 |
| `shell` 超时只杀父进程 | `ping` 子进程活着并握着 `$OUT` 写端 → **CGI 挂死** | `_kill_tree` 按 PPid 杀整棵子树 |
| `password` 顶部无条件建 `.htpasswd` | `action=reset` 的 `[ -f ]` 判断恒真 → **reset 是死代码** | `reset` 时跳过自动初始化 |
| `openssl passwd` 用位置参数传密码 | 密码以 `-` 开头会被当选项 | 优先 `-stdin`，失败回退位置参数 |

**前端**

| 缺陷 | 后果 | 修复 |
|---|---|---|
| `sms.html` 合并短信 `onclick` 用 `JSON.stringify` 拼进双引号属性 | 正文含引号/换行时属性被提前截断 → **合并短信点了没反应** | 改 `data-*` + 渲染后 `addEventListener` 绑定 |
| `sms.html` 调用未定义的 `decodeSmsText` | 文本模式回退路径抛 `ReferenceError` → 列表空白 | 补齐 `decodeSmsText` 定义 |
| `network.html` 锁定状态只看"行是否存在" | `+CCELLCFG?` 未锁定时也回该行 → 未锁也显示"**已锁定**" | 改判首参（`pci=0` = 未锁定）；NR 同样处理 |
| 并发 AT 无客户端排队 | 进页面即多路并发，一条卡住全部等到超时 | `wb-theme.js` 对 `/cgi-bin/atcmd` 串行化 |

---

## 📝 与参考项目的差异

| 项目 | Quectel Simple Admin | 本项目 (SIM8260) |
|------|---------------------|-------------------|
| 目标模块 | RM5xxx (SDXLEMUR) | SIM8260 (SDX62) |
| AT 命令前缀 | `AT+QMAP*`, `AT+QCFG*` | `AT+CQCMAP*`, `AT+CW*`, `AT+CS*` |
| 界面风格 | 浅色 Bootstrap 默认 | 深色科技风 + 玻璃拟态 + 渐变 |
| 信号可视化 | 数字为主 | 信号圆环 + 4 天线柱状图 |
| CGI 通信 | cat 重定向轮询 | microcom 一次调用 + 原子锁 + 清缓冲 |

---

## ⚠️ 注意事项

- 首次安装前确认模块有可用的 AT 串口，可用 `ls /dev/smd*` 查看。
- `settings.html` 显示的部署路径是模板默认值 `/usrdata/simcom-webui/`，实际以 probe 为准（多为 `/userdata/simcom-webui/`）。
- 切换 USB PID 会导致 USB 设备重新枚举，网页会短暂断开。
- 发 AT 命令前请了解命令作用，错误配置可能导致模块异常。
- 改密码：设置页，需输入旧密码；忘记密码可 ADB shell 删 `.htpasswd` 后重置。
- **已知行为：socat 可能在"刚起桥后、且无人用网页"时自行退出一次**，看门狗会在 ≤10s 内
  发现并自动重建（`bridge.log` 里表现为一次 `L0 存活检查失败 1/2 → socat 缺失 → 重启`），
  之后长期稳定。原因是 pty 桥的固有特性：模组在空闲时若吐出一条 URC，socat 会把它写给
  `/dev/ttyOUT2` 的**主设备**，而此刻没有任何进程打开该 pty 的从设备 → `EIO` → socat 退出。
  属**自愈**范围，不影响正常使用；若某天觉得这次重建窗口碍事，可让看门狗在 idle 期
  持有一个"只打开不读取"的从设备持有者（注意与 CGI 抢读的时序，目前刻意不做）。

---

## 🙏 致谢

本项目基于 [quectel-rgmii-toolkit-cn](https://github.com/gaoweifan/quectel-rgmii-toolkit-cn)（SDXLEMUR 分支）的 Simple Admin 二次开发，
针对 SIMCom 命令集重写后端、并对界面做了全面升级。在此感谢原作者的开源贡献。

---

## 👤 关于作者

本项目由 **@Valor** 基于参考项目二次开发、维护并开源。

- 🔗 GitHub：https://github.com/SAddr/sim8260webui
- 💡 欢迎通过 Issue / Pull Request 提建议、报 Bug、贡献代码。

---

## 📄 License

[CC BY-NC 4.0](./LICENSE) — Copyright © @Valor.

- ✅ **非商业用途免费**（需署名 @Valor）。
- ⛔ **商业使用需事先获得 @Valor 授权**；如需商业授权，请通过 GitHub 联系。

衍生自 [quectel-rgmii-toolkit-cn](https://github.com/gaoweifan/quectel-rgmii-toolkit-cn)（原项目为 MIT 协议）；本项目在其基础上二次开发，但采用 **CC BY-NC 4.0** 授权以禁止商业使用。
