# OpenWrt 25.12.5 → Radxa ROCK (Pi) 4B Plus

分支 `radxa-rock-4b-plus`，基线 `v25.12.5`。移植层仓库 —— OpenWrt 树在构建机
`hyv-ub24:/home/max/Code/openwrt`。⚠️ 本移植的设备树**继承上游**，只写 130 行 delta。

**未推送到任何上游 remote。**

---

## 状态：本移植的引导程序**能启动但不稳定**，⚠️ 根因未定位

> ### ⚠️ 本移植的 U-Boot 在真机上跑起来了，但会随机 panic
>
> 2026-10-06 用 Maskrom 把整包镜像刷进 eMMC 后，**本移植的引导程序第一次在真机上执行**。
>
> **`rockchip,sdram-params` 修复确认生效** —— TPL 打出了完整的 LPDDR4 训练过程：
>
> ```
> U-Boot TPL 2025.10-OpenWrt-r33051-f5dae5ece4 (Jun 29 2026 - 12:59:20)
> lpddr4_set_rate: change freq to 400MHz 0, 1
> Channel 0: LPDDR4, 400MHz  BW=32 Col=10 Bk=8 CS0 Row=16 CS=1 Die BW=16 Size=2048MB
> Channel 1: LPDDR4, 400MHz  BW=32 Col=10 Bk=8 CS0 Row=16 CS=1 Die BW=16 Size=2048MB
> ```
>
> 两通道各 2048MB = 4GB，与实物一致。对比当年变砖时的
> `Cannot read rockchip,sdram-params -1 / DRAM init failed: -1` —— **这一项修好了。**
>
> **但 base 版引导程序 6 次只有 1 次挂上 root，3 次内核 panic。**
>
> ⚠️ 这个 6/3 是 **base 构建**的账。后来还有两个构建测过：`+0103` 2 次全崩，
> `+0103+vdd_log` **6 次零 panic**（见下）。**三个是不同的引导程序，不能合并统计。**
>
> ⚠️ **`0103` 已删除**（10-08）—— 它是本移植唯一偏离上游的改动，实测证明它修不好
> 任何东西，删掉是为了让「`vdd_log` 单独是否就够」这个问题能被回答。
> **删除后的构建正在重测中。**
>
> | | 本移植 base | 本移植 +0103 | 本移植 +0103 +vdd_log | Armbian |
> |---|---|---|---|---|
> | 启动次数 | 6 | 2 | **6** | 6 |
> | **挂上 root** | **1** | **0** | **6** | **6** |
> | **内核 panic** | **3** | **2** | **0** | **0** |
> | 日志早断（死活判不出） | 2 | 0 | 0 | 0 |
> | SDIO 相位 | 269（3/3） | 269 | 221–225 | 220–223 |
>
> ⚠️ **每一列是不同的引导程序构建，不能横向相加成"本移植 14 次 5 panic"。**
> `+0103` 已删除，所以将来只剩两列（base 与最终版）。
>
> ⚠️ **「挂上 root」这一行是实测的，「到达 shell」没有单列** —— 重启循环那 5 次是
> 用 ssh 判定的（dmesg 干净 + `VFS: Mounted root` + `boot_id` 变化），能 ssh 上就说明
> 用户态起来了，但"看到 shell 提示符"只在串口那次（tty14）确认过。
> **把两者混成同一列会夸大证据。**
>
> ### 对照实验 —— 变量已经收敛到一个
>
> 最初那次对照（tty11 vs tty12）**有两个共变变量**：引导程序换了，**引导介质也换了**，
> 所以当时无法区分是谁的问题。10-08 把 eMMC 那一列补齐之后，只剩一个变量：
>
> | 引导介质：eMMC | Armbian U-Boot | 本移植 U-Boot |
> |---|---|---|
> | 启动次数 | **7** | 6 |
> | **内核 panic** | **0** | **3** |
>
> （从 U 盘引导那一列 Armbian 也有 6 次零 panic，本移植从未测过，且该格实测走不通：
> boot ROM 不跳过 SPI，板载 SD 卡槽排第三，要让 U 盘赢就得破坏现有恢复路径。）
>
> ⚠️ 剩下要靠实验回答的是**为什么**，不是"是不是"。**根因未定位。**
>
> ### 症状：函数指针被指向垃圾地址
>
> 三次 panic 的形态一致 —— **PC 落到不是代码的地方**：
>
> | 日志 | 异常 | PC |
> |---|---|---|
> | tty8 | `IABT (lower EL)` 取指失败 | `ffff8000819ebb40` |
> | tty10 | `Undefined instruction: 0000000002000000` | `Code: ... cb150035 ...`，`cb` 在 ARM64 里不是合法指令 |
> | tty12 | `IABT (current EL)` + level 0 fault | `0xdfff800080099ee4`，内核声称 *"address between user and kernel address ranges"* |
>
> tty12 的调用链本身完全正常（`rk3x_i2c_irq` → `__wake_up` → `__wake_up_common`），
> 是它调用的**函数指针**是坏的，而且 x4 寄存器里是同一个值。
>
> **内存被写坏或读坏 → 指针被污染 → 取指失败。** 故障点每次都在不同位置
> （`mmc_rescan` 工作线程 / idle 路径 / I2C 中断），这种随机性是硬件类故障的特征。
>
> ### ❌ 实验一：升频时机 —— **没修好，但排除了 DRAM 初始化**
>
> `0103-ram-rockchip-rk3399-lpddr4-configure-before-training.patch`
> 已刷入 eMMC 测过：**2 次启动，2 次 panic。**
> 补丁做的事：删掉通道循环前那次 `lpddr4_set_rate(dram, params, 0)`，
> 并把尾部那一次 `set_rate_index` 变成 ctl0、ctl1 各一次 —— 恢复 v2022.07 的顺序。
>
> 串口确认补丁生效（`50MHz` 变成在 `lpddr4_set_rate` **之前**打印），而 tty13 第二次
> 启动与 tty12 **完全同源** —— 同样的 ESR、同样的 PC `0xdfff800080099ee4`、
> 同样的 `lr: __wake_up_common+0x8c`、同样的 `rk3x_i2c_irq+0x198`。
>
> **⇒ DRAM 初始化被排除。** ⚠️ 补丁暂时保留（两边 DRAM 序列一致，后续对比才只剩
> 一个变量），但它偏离上游，不需要时就该删。
>
> ### ✅ 实验二：`&vdd_log` 电压 —— **6 次连续零 panic，达到判据**
>
> 改动只有一行，在板级 `-u-boot.dtsi` 里（不是新补丁，是改 0102 的 payload）：
>
> ```c
> &vdd_log {
> 	regulator-init-microvolt = <950000>;
> };
> ```
>
> **为什么是它**：内核侧 `vdd_log` 节点（`rk3399-rock-pi-4.dtsi`）是 pwm-regulator、
> `regulator-always-on`，只有 `regulator-min/max-microvolt`（800000～1400000），
> **没有 `regulator-init-microvolt`** —— 所以**内核不选电压，U-Boot 留下什么就是
> 什么**，而我们没设。上游 `rk3399-rock-pi-4-u-boot.dtsi` 和 Radxa 自家
> `rk3399-rock-4c-plus-u-boot.dtsi`（同规格兄弟板）**都设成 950mV**。
>
> ⚠️ **这不是深思熟虑的省略，是一句推理带过的。** 板级 dtsi 原来写着
> 「不 include rock-pi-4 的 dtsi，因为它的 `&sdhci` 时序和 `leds` 不是缺的东西」
> —— 那句话覆盖整个文件，`&vdd_log` 就顺带被丢掉了。
>
> ⚠️ **只加这一项**，`&sdhci` 和 `leds` 故意不加 —— eMMC 已经跑 HS400 且挂上 rootfs，
> leds 是装饰性的，都没有损坏内存的机制。加进去失败就无法归因。
>
> | | 值 |
> |---|---|
> | `idbloader.img` | `7c65ea03783a614c…` |
> | `idbloader-spi.img` | `d3244a0239605349…` |
> | `u-boot.itb` | `d466c390c57eaa5d…` |
> | ext4 镜像 gz | `bd3a6112cb6abca7…`，12811784 字节 |
> | 构建后校验 | **21 项全过** |
> | 上机结果 | ✅ **6 次连续启动 0 panic**，6 次 `MemTotal` 一致、`boot_id` 互不相同 |
>
> ### ⭐ 但真正有意思的不是这次成功，是**SDIO 相位值变了**
>
> `dwmmc_rockchip` 调的那个相位是**时序余量的直接测量**。按引导程序排开：
>
> | 引导程序 | 相位值 | 结局 |
> |---|---|---|
> | Armbian（6 次） | 220 / 221 / 222 / 223 | 6/6 无 panic |
> | 本移植 **带** vdd_log | **221 / 224**（每次启动都不同） | 无 panic |
> | 本移植 **不带** vdd_log（6 次，其中 3 次记到相位） | **269**（3/3 完全一致） | 6 次里 3 panic |
>
> **269 → 221–225，而 Armbian 也在 220–223。** 这是第一条独立于
> 「启动成不成功」的证据 —— 它不需要等满 6 次就能看出改动确实起了作用。
>
> ⭐ **它顺带补上了一个我原以为补不上的缺口。** 串口里**没有任何一行能证明
> 新引导程序上了板**（TPL 只打印版本，不含我们改的属性；电压也不会被打印），
> 「刷了新镜像」此前只有哈希和口头确认支撑。**相位跳出了 269 就是间接证据。**
>
> ⚠️ **⚠️ 我把它叫「刷写指纹」，那是错的，第一次重启就证伪了。** 同一份镜像的
> 第 2 次启动读到 **224**，不是 221。**这个值每次启动都会变** —— 所以它是
> ⚠️ ~~**但它不能代替 6 次判据。** 三条理由：~~ **—— 这三条在只有 1 次成功时是对的，
> 现在已被下面的结果取代，保留是为了看出当时的判断有多保留。**
> - ~~tty8 的**第一次**启动也是相位 269，而它**成功了**。269 是风险因子，不是判决。~~
> - ~~1 次成功和 6 次成功没有可比性 —— 这正是本文开头那条教训。~~
> - ~~我完全不知道 220–224 和 269 哪一族才是「对」的。~~
>
> ⚠️ **剩下那条仍然成立**：我不知道 220 多和 269 哪一族才是「对」的，
> 只能说前者更接近能工作的那个。
>
> ### ✅ 6 次全部干净 —— **达到本仓库定下的判据**
> ### ✅ 6 次全部干净 —— **达到本仓库定下的判据**
>
> | # | 来源 | 相位 | 挂上 root |
> |---|---|---|---|
> | 1 | tty14（串口） | 221 | 1.355s |
> | 2 | `setsid reboot` | 224 | 1.381s |
> | 3 | 重启脚本第 1 轮 | 225 | 1.380s |
> | 4 | 被中断那次（仍起来了） | 223 | 1.381s |
> | 5 | 脚本倒数第 2 轮 | 223 | 1.378s |
> | 6 | 脚本最后一轮 | 223 | 1.375s |
>
> 判据脚本：[`scripts/check-reboot-matrix.sh`](scripts/check-reboot-matrix.sh)，已做负控制。
> **对照基线：base 版 6 次 3 panic（50%），Armbian 7 次零 panic。**
>
> ⚠️ **但「达到判据」不等于「根因找到」。**
> - 假说只是**相容**，**因果链没闭合**：电压轨 → SDIO 相位 → `rk3x_i2c_irq` 附近的崩溃，
>   没有一环被实测证明。
> - **6 次零 panic 不等于故障率为零。** 故障本来就是间歇性的，6 次只说明
>   「在 6 次里没出现」。
> - ⚠️ **上游 PR 仍然不要提** —— 别人复现不了，也就无从判断这个改动是否必要。
>
> ### 逐层比对：四个假设的结论
>
> 拿到 U-Boot **v2022.07** 源码（Armbian 那版）逐层比对：
>
> | 假设 | 结果 |
> |---|---|
> | DRAM 参数（`rk3399-sdram-lpddr4-100.dtsi`）不同 | ❌ **逐字节相同**（sha256 `2874c640…` 两版一致） |
> | DRAM 相关 CONFIG 不同 | ❌ 相同（`CONFIG_RAM_ROCKCHIP_LPDDR4` 只是改过名） |
> | 板级 U-Boot dtsi 不同 | ❌ Armbian 的 `rk3399-rock-pi-4-u-boot.dtsi` include 的是同样两个文件 |
> | 驱动代码大改 | ❌ 93 KB 的文件只差 +64/−48 行（3%） |
> | `cs0_high16bit_row` 被新调用同步（`Row=16/15` vs `Row=16`） | ❌ 该字段在 RK3399 路径里**只用于打印** |
>
> **剩下的唯一差异**（v2025.10 把切 400MHz 提前到了配置写入之前）**也已由实验一排除**。
>
> ⚠️ 两个我自己的更正，别被文档里的旧说法误导：
>
> - **"配置写入时的实际频率不同"是真的** —— 我中途撤回过一次，那是错的。
>   串口上 `50MHz` 在前、`400MHz` 在前，如实反映了当时的状态。本板
>   `base.ddr_freq = 50`（扁平数组下标 34，由结构体总长 `34+5+332+200+959 = 1530`
>   与 dtsi 的 u32 总数吻合，`num_channels=2`、`stride=13`、`odt=1` 三个锚点全部
>   与 `.inc` 一致）。**我一度把它解成 80，那是解析脚本的 bug**，错数字还进了补丁头。
> - **Armbian 的参数与我们不同** —— banner 带 `armbian` 补丁后缀，它自己打的补丁
>   不在我们手上。**能恢复的是 mainline v2022.07 的顺序，不是 Armbian 的实际行为。**
>
> **下一步**：① Maskrom 刷入实验二的镜像，跑 6 次（判据：6 次连续零 panic，
> 一次不算）→ ② 拿 Armbian 真正的 `u-boot.itb`/`idbloader.img` 做语义级设备树比对 →
> ③ 若有实物 TTL 适配器接 UART2，价值最大 —— 现在缺的是 TPL/SPL 自己的输出。
> 详见 [docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md)。
>
---

## 文档地图

按用途分，每个文件一个主题：

| 文件 | 内容 |
|---|---|
| [docs/hardware.md](docs/hardware.md) | 硬件事实、板型辨识、40-pin、版本差异、按键、介质 |
| [docs/device-tree.md](docs/device-tree.md) | 设备树策略、继承 dtsi ≠ 继承 board、U-Boot 板级 dtsi、dtc 坑 |
| [docs/build.md](docs/build.md) | 构建环境、目录结构、21 项校验、包集合、产物、可复现性 |
| [docs/flashing.md](docs/flashing.md) | 烧卡、首次启动该看什么、eMMC 安装、Maskrom |
| [docs/boot-order.md](docs/boot-order.md) | SPI → eMMC → SD、镜像自带引导程序、SPI 读不对 |
| **故障记录** | |
| [docs/postmortem-u-boot-ddr.md](docs/postmortem-u-boot-ddr.md) | U-Boot 变砖的根因（缺 DRAM 参数）与修复 |
| [docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md) | 修好之后发现的随机 panic，根因缩小到 DRAM 初始化 |
| [docs/wifi.md](docs/wifi.md) | WiFi 排查完整记录（证据、测试矩阵、固件许可） |
| [AGENTS.md](AGENTS.md) | 给 AI agent 的工作指南 |

要动手的话先读 [AGENTS.md](AGENTS.md)。

---

## 已验证可用

以下每一行的证据都来自**板子实测**（OpenWrt 25.12.5 / Linux 6.12.94，2026-10-06/08 复核）。
凡是没有在真机上跑过的，都不在这个表里。

⚠️ **本移植的引导程序有随机 panic 的问题**（base 版 6 次启动 3 次崩），所以下面"启动"和
"eMMC 引导"两行的证据都注明了是由**哪一次**运行给出的。用 Armbian 的引导程序启动
稳定，用本移植的那份不稳定 —— 详见顶部状态节。

| 外设 | 状态 | 关键证据 |
|---|---|---|
| 启动（Armbian 引导程序，**从 U 盘**） | ✅ 稳定 | microSD（USB 读卡器）引导 → `/boot.scr` → `Linux-6.12.94` kernel FIT + `radxa_rock-4b-plus` dtb 63877 B，crc32+sha1 通过 → `procd: - init -`。**6 次启动零 panic**（tty6/tty11 挂上 root，tty4/tty5 到 shell） |
| 启动（Armbian 引导程序，**从 eMMC**） | ✅ 稳定 | Armbian 26.11.0 / Linux 6.18.54，`root=UUID=7043da66-…`、`ubootpart=d2a80aa7-01`。**7 次零 panic**（10-08 连测 6 次，每次 boot_id 都变、`dmesg` oops/panic 计数为 0、`MemTotal` 一致）。⚠️ 无串口，所以是"内核每次都起来"，不是"TPL 每次都正确" |
| **启动（本移植引导程序，从 eMMC）** | ⚠️ **不稳定** | 同一条链路跑通，但 6 次里 1 次挂上 root（tty8）、3 次 panic（tty8/tty10/tty12）、2 次日志早断。**根因未定位**，见顶部状态节 |
| 身份 | ✅ | `model: Radxa ROCK 4B+`、`board_name: radxa,rock-4b-plus` |
| **以太网** | ✅ 1Gbps | `Link is Up - 1Gbps/Full - flow control rx/tx` → `br-lan: ... forwarding state` |
| **eMMC 32G** | ✅ 硬件 + **引导已验** | `mmc0: new HS400 Enhanced strobe MMC card` → `SLD32G 28.9 GiB`；Maskrom 写入整包后 **tty8 从 eMMC 挂上 root**（`VFS: Mounted root (ext4 filesystem) on device 179:2`，`mmc@fe330000.bootdev.part /boot.scr`）；Armbian 从 eMMC 引导亦已验证（`ubootpart=d2a80aa7-01`，1 次） |
| **USB** | ✅ | 2×xHCI(SS) + 2×EHCI + 2×OHCI；microSD 读卡器识别为 `sda`（3.7 GB） |
| USB 介质引导 | ✅ | U-Boot 默认链含 `usb`，零配置找到 `/boot.scr`（⚠️ 板载 SD 卡槽 `mmc1` 未验证） |
| **WiFi** | ✅ | 固件起来 `version 7.84.17.1`，**无 `HT Avail timeout`**；`iw dev wlan0 scan` 扫到 15 个 BSS。MAC `08:fb:ea:65:f8:da`，与 Armbian 下同一颗芯片一致 |
| **BT 硬件层** | ✅ | `ff180000.serial: ttyS0 at MMIO 0xff180000` |
| RK808 PMIC | ✅ | `rk808-regulator` + 2×`fan53555-regulator ... Detected` |
| RTC | ✅ | `rk808-rtc registered as rtc0` |
| rootfs/overlay | ✅ | ext4 → f2fs overlay |
| CPU | ✅ | `SMP: Total of 6 processors activated` |
| **Maskrom 恢复** | ✅ | 官方 `rk3399_loader` + Armbian 引导程序救回过一次起不来的板子 |
| **Maskrom 写 eMMC** | ✅ | `rkdeveloptool db loader` + `wl 0 <整包>` 写入成功，板子从 eMMC 引导 |
| **DRAM 参数（`rockchip,sdram-params`）** | ✅ **已修且生效** | TPL 打出 `lpddr4_set_rate` + 两通道各 `Size=2048MB`（2026-10-06）。⚠️ 但**同一份 TPL 会导致随机 panic**，见顶部状态节 |

### 主动划出范围

| 项 | 性质 | 恢复成本 |
|---|---|---|
| **HDMI 视频** | 内核 `CONFIG_DRM` 全关 + OpenWrt **无 `kmod-drm-rockchip`** | 新建 1 个 kmod 包，可进上游 |
| **音频** | 缺 `kmod-sound-soc-es8316` + `kmod-sound-soc-rockchip` | 新建 2 个 kmod 包，工作量最大 |

两者都**不阻塞使用**：SSH/串口 + 1Gbps 网口 + WiFi 均已可用。详见
[docs/hardware.md](docs/hardware.md#hdmi--音频内核里根本没编译)。

---

## 还剩什么

**本移植 U-Boot 的随机 panic 是唯一还没解决的问题**，而且它比别的都重要 ——
引导程序不稳定意味着镜像不能算可交付。

**对照组已经补齐**（10-08）：两列都从 eMMC 引导，Armbian 7 次零 panic、本移植 6 次
3 panic，**唯一变量是引导程序本身**。所以"是本移植引导程序的问题"现在有证据了。

⚠️ **但"为什么"仍未定位。** DRAM 参数、DRAM 的 CONFIG、板级 dtsi 已确认与 Armbian
逐字节相同，唯一找到的差异是 **LPDDR4 升频与训练的时机**（新增一次 PHY 配置 + 训练，
跑在配置写入之前）。下一步是把它挪回去重建，跑 6 次 —— 这是改上游代码，必须可回退。
详见 [docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md)。

**eMMC 安装**已验证（Maskrom 写整包 tty8 挂上 root；Armbian 从 eMMC 引导 7 次零 panic），
`dd` 流程另见 [docs/flashing.md](docs/flashing.md)。

⚠️ **eMMC 上现在是 Armbian**（2026-10-08 重装，单个 28.6 GB ext4，
`root=UUID=7043da66-…`），**不是** OpenWrt 镜像。本文上面几处写"eMMC 上是 OpenWrt
镜像"的记录描述的是 10-06 那天的状态，已过时 —— 变迁见
[docs/hardware.md](docs/hardware.md#emmc-状态的变迁实测)。

板子当前可达 **`192.168.3.8`，`root`，无密码** —— eMMC 上现在是本移植的 OpenWrt
镜像（不是 Armbian）。⚠️ 地址和密码都变过：Armbian 时期是 `.184` / `armbian`，
写 OpenWrt 整包之后 DHCP 给了 `.8`，且新系统首次启动生成了新的 host key。
**旧 host key 指纹 `SHA256:bkOdpYyr9UyIDOegCfoiUWODxIED3JB6zD7grt2jFIM`
（已归档到 `~/.ssh/known_hosts.retired`），新的是
`SHA256:qgJ+OCni5jPRbNeEMxzKRAyFW+3TZdzzZHed/xXvUnE`。**
host key 变了先确认是不是重装系统，别直接 `StrictHostKeyChecking=no`。

---

## 上机验证（七次）

| 次 | 镜像 | 结果 |
|---|---|---|
| 1 | — | U-Boot/内核跑通，rootfs 读不了（手写 DTS，PMIC 未探测） |
| 2 | `6386de59` | SD 卡 I/O 错误 + 供电链修复 → 系统完整启动（WiFi/BT 仍死） |
| 3 | `06b61b20` | 补 4 个板级 override → WiFi/BT 硬件层打通 |
| 4 | `9932b3da` | 删 gpio-keys + 包集合修正 → 全部符合预期 |
| 5 | `50092eba` | 加 43456 固件包 → 固件上传成功，芯片不启动 |
| 6 | `aaf2298` 树 | 补 `&spi1` + `flash@0` → SPI 在 OpenWrt 下可见，同时查明**读不到正确内容** |
| 7 | `5a09fc41` | Maskrom 写入 eMMC → **本移植 U-Boot 首次真机执行**：DRAM 初始化成功，但 6 次启动 3 次 panic |

⚠️ **第 5 次的"芯片不启动"是当时的状态，后来修好了**（`lpo` → `ext_clock`）。第 7 次才是
当前镜像的状态，而它暴露了 U-Boot 的 DRAM 问题。

第四次的关键验证点：

```
  gpio-138 (|Recovery)                    ← 消失了，证明 gpio-keys 节点已删
  gpio-10  (|reset     ) out hi           ← WiFi 芯片出复位
[    0.326067] dwmmc_rockchip fe310000.mmc: allocated mmc-pwrseq
[    0.813709] mmc2: new ultra high speed SDR104 SDIO card at address 0001
[    0.252633] ff180000.serial: ttyS0 at MMIO 0xff180000      ← BT 的 uart0
  Data Size:  63787 Bytes                ← dtb 与构建产物一致
```

`/sys/kernel/debug/gpio` 里列出的 GPIO 从 11 个降到 10 个，正好是删掉的那个。

---

## WiFi 一句话

**已修复并实测可用。** 根因是设备树里一个属性名：上游 Radxa 写 `"lpo"`，而
`mmc-pwrseq-simple` **只**查 `"ext_clock"` —— 查找返回 `-ENODEV` 被 `!IS_ERR()` 容忍，
32.768 kHz 时钟**静默地从未使能**，没有任何报错。BCM43456 没有 32 kHz 参考也能接受固件
上传，但 datapath 起不来。

关键一步是拿 Armbian 做对照：它在**同一块板**上用同一个 brcmfmac、**逐字节相同**的
固件/NVRAM 能正常工作，而 live device tree 只差这一个属性。在此之前测的 6 组固件组合
全是在测错的变量。

完整记录见 [docs/wifi.md](docs/wifi.md)。

---

## 进度

- [x] 调研与可行性核实
- [x] remote 修正（gitee 停更 → 官方源）
- [x] 基线锁定 tag `v25.12.5`，新建分支
- [x] Phase 1：`armv8.mk` 新增 `radxa_rock-4b-plus`
- [x] Phase 2：**DTS 改为继承上游两个 dtsi**（当前 130 行 delta）
- [x] Phase 3：U-Boot 变体 + defconfig + DTS 复制进 `dts/upstream`
- [x] 补丁在 6.12.94 上干净应用（零 `.rej`）
- [x] Phase 4：**上机验证通过，系统完整启动**（1Gbps 网口 + eMMC HS400 + USB）
- [x] Phase 5a：WiFi **硬件层**打通
- [x] Phase 5b：BCM43456 固件包做好并验证进镜像
- [x] Phase 5c：WiFi **固件运行** —— 根因是 pwrseq 时钟名（`lpo` → `ext_clock`），已修
- [x] Phase 5d：recovery/Maskrom 按键定性，猜的 gpio-keys 已删
- [x] Phase 5h：查明镜像**自带**引导程序（LBA 0x40 + 0x4000），并加断言盯住
      —— 后又从板上的 SD 卡实测确认了这两个 magic 真的在盘上
- [x] Phase 5i：给内核补上 `&spi1` + `flash@0`，让 SPI 闪存在 OpenWrt 下可见
      （同时查明 Linux 读不到它的正确内容）
- [x] Phase 5j：文档准确性复核 —— 逐条比对真机实测
- [x] Phase 5k：文档按用途拆分，新增 `AGENTS.md`
- [x] Phase 5g：**本移植的 U-Boot 上真机复验** —— Maskrom 写入 eMMC 后首次执行，
      `rockchip,sdram-params` 修复**确认生效**（两通道各 2048MB）
- [x] Phase 6：eMMC 安装验证 —— **已通过**（tty8 从 `mmc@fe330000` 挂上 root）
- [x] Phase 5l：诊断随机 panic —— 12 次启动对照实验；**随后推翻了自己的归因**，
      并与 v2022.07 逐层比对排除三个假设
- [x] Phase 5n：补齐对照组 —— Armbian TPL + eMMC 连测 6 次（连之前共 7 次零 panic），
      **变量收敛到只剩引导程序**
- [x] Phase 5m-1：DRAM 初始化 —— 补丁 `0103` **已上机测过：2 次启动 2 次 panic，没修好**。
      **但它排除了 DRAM 初始化** —— 两边 DRAM 序列一致而故障依旧，tty13#2 与 tty12
      完全同源。⚠️ **补丁已于 10-08 删除**：它是本移植唯一偏离上游的改动，留着是负债，
      且挡住了「`vdd_log` 单独是否就够」这个问题。测量记录留在
      [docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md)
- [x] Phase 5o：`&vdd_log` 电压 —— **6 次连续启动零 panic，达到判据**。
      ⭐ 附带拿到一条独立信号：SDIO 相位从 269 跳出到 221–225（Armbian 也在 220–223），
      这是「改动确实起了作用」的间接证据。⚠️ 但相位**每次启动都会变**，所以它是
      电压轨指示器，不是构建指纹
- [x] Phase 5p：**删掉 `0103` 后重测** —— 让「`vdd_log` 单独是否就够」这个问题有答案。
      🧪 构建中，待 Maskrom 刷入与 6 次重测
- [ ] Phase 5e：HDMI 视频（需新建 `kmod-drm-rockchip`）
- [ ] Phase 5f：音频（需新建两个 kmod 包）
- [ ] Phase 7：上游 PR（Linux 主线 DTS + OpenWrt 设备支持，DTS 已符合上游风格）
      ⚠️ **在 DRAM 问题解决之前不要提** —— 提交一个引导不稳定的移植不合适

---

## 给下次的提醒

按"这个坑是否已经填过"排序。最贵的几条排在前面。

1. **"构建成功"不等于"能启动"。** `rockchip,sdram-params` 缺失时构建返回 0、
   `idbloader.img` 正常产出、既有 9 项校验全过。缺陷只在刷进 SPI 后才暴露，那时已经
   无法自救。**加校验项的标准是"这个缺陷能不能溜过去"**，不是"我改了什么"。
2. **静默降级比报错危险。** `arch/arm/dts/<board>-u-boot.dtsi` 不存在时，U-Boot 的
   `wildcard` 回退到通用文件，不警告、不失败、产物大小正常。去找那些"找不到就用兜底"
   的地方。
3. **查位置别只看最明显的那个。** "Armbian 镜像里没有引导程序"这个结论是错的：引导程序
   在 LBA 0x40（字节 0x8000），我只查了偏移 0。这个错误结论把恢复方向带偏成"必须从
   外部另找一份引导程序"，差点放弃。
4. **"结果一致"不等于"结果正确"。** 这块 SPI 两次读取（不同块大小）**字节完全相同**、
   几何信息也对、所有稳定性检查满分通过 —— 但整个 4 MiB 里没有 rkimage 头、没有 FIT
   magic、没有 U-Boot banner，而这块芯片上明明有能跑的引导程序。**确定性失败每次返回
   一样的错误数据，所以它能通过任何"读是否稳"的检查。** 验证必须有"结果是否符合预期"
   这一步。
5. **别拿 sha256 当"同一份东西"的判据。** 两次构建 sha256 不同（`b8fa872f…` →
   `76bf3bcf…`），中间只隔一个改注释的提交；查下来 DTB 属性 82/82 全同、code 区 0 字节
   变化，**只是 DTB 字符串表重排**。可复现的是语义，不是字节。
6. **测试 WiFi 必须冷启动**：`poweroff` + 拔电 + 等 10 秒 + 上电。`reboot` 和 reset 键
   都不算。
7. **配置缺失和硬件故障长得一模一样。** `wlan0 state DOWN` + 扫到 0 个网络，既可能是芯片
   死，也可能只是 `disabled='1'`。**先排除配置再谈硬件。** 同类：busybox `ip` 不支持
   `-br`，`ip -br link show | grep wlan` 返回空，看起来像没有无线网卡 —— 先确认工具支持
   你要的语法。
8. **别信没验证过对照组的"证据"。** 排查里用过 `.packageinfo`、未选中的
   `cypress-firmware`、`dmesg -C` 后的缓存内容，三个都不是有效信号。
9. **构建后看校验块**，不要只看 `REAL_EXIT_CODE`。日志还要看第一行的时间戳 ——
   有一次 `setsid nohup` 在 `ssh` 里静默失败，校验块读的是上一轮的日志，报了 9 项 OK。
10. **shell 里注意同名变量。** `sh` 没有局部作用域，函数里用了和顶层同名的计数器会
    直接覆盖 —— `check-patch-sources.sh` 因此把一次真实的漂移报成"全部匹配"且 exit 0，
    只因为被检查的最后一个文件恰好是匹配的那个。负控制要挑**中间**那个文件做。
11. **危险路径要能只读地跑一遍。** 管理员门禁会把写盘那段挡在评审之外，于是
    `write-idbloader-sd.ps1` 里的两个 bug 一直没人看见。加 `-Preview` 之后两分钟就暴露。
12. **文档会过期，而且过期得比人记得快。** 本次复核发现 WiFi 章节还在写修复前的"芯片不肯
    运行固件"（与同文件另两处直接矛盾）、eMMC 章节还在描述一个早已被覆盖的布局、校验项
    数量停在 16（实际 17）。**每次动真机就该顺手复核相关段落。**