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

### 桥接健康检查与自愈
**看门狗+自检脚本**：

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
