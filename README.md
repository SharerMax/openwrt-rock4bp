# OpenWrt 25.12.5 → Radxa ROCK (Pi) 4B Plus

分支 `radxa-rock-4b-plus`，基线 `v25.12.5`。移植层仓库 —— OpenWrt 树在构建机
`hyv-ub24:/home/max/Code/openwrt`。⚠️ 本移植的设备树**继承上游**，只写 130 行 delta。

**未推送到任何上游 remote。**

---

## 状态：本移植的引导程序**能启动但不稳定**，根因已缩小到 DRAM 参数

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
> **但 12 次启动里，本移植的引导程序 6 次只有 1 次挂上 root，3 次内核 panic。**
>
> | | 本移植 U-Boot | Armbian U-Boot |
> |---|---|---|
> | 启动次数 | 6 | 6 |
> | **挂上 root** | **1** | 2 |
> | 到达 shell | 0 | 2 |
> | **内核 panic** | **3** | **0** |
> | 日志早断（无法判定死活） | 2 | 2 |
>
> ### 决定性对照：唯一变量是 TPL
>
> ```
> tty11  Armbian TPL → 引导 U 盘 → VFS: Mounted root (ext4) on device 8:2 → 进 shell
> tty12  本移植 TPL → 引导 eMMC → 0.54 秒 panic
> ```
>
> **同一份内核、同一份 dtb（63877 字节，两边 crc32+sha1 哈希完全相同）、同一个 rootfs。**
> 唯一差别是 TPL/SPL。
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
> ### 定位到 DRAM 参数，但还没修
>
> Armbian 的 TPL 先跑 50MHz 再升频：
>
> ```
> Channel 0: LPDDR4, 50MHz
> lpddr4_set_rate: change freq to 400000000 mhz 0, 1
> lpddr4_set_rate: change freq to 800000000 mhz 1, 0
> ```
>
> 本移植直接从 400MHz 开始：
>
> ```
> lpddr4_set_rate: change freq to 400MHz 0, 1
> lpddr4_set_rate: change freq to 800MHz 1, 0
> ```
>
> ⚠️ **这只是假设，未证实。** 低速起步可能是 DRAM 训练（write leveling / gate
> training）需要的时间，但我们用的是 `rk3399-sdram-lpddr4-100.dtsi`，而上游
> `rk3399-rock-4c-plus-u-boot.dtsi` **用的是同一个文件** —— 所以选型本身没有可疑之处。
> 要定论得比对 Armbian 的 dtsi 源码，那棵树不在手上。
>
> **下一步**：拿到 Armbian 的 U-Boot 源码，比对它用的 `rk3399-sdram-*.dtsi`，看差异
> 到底在哪。**在比对之前不要改参数** —— 现在改就是猜。
>
> 完整记录见 [docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md)。

---

## 文档地图

按用途分，每个文件一个主题：

| 文件 | 内容 |
|---|---|
| [docs/hardware.md](docs/hardware.md) | 硬件事实、板型辨识、40-pin、版本差异、按键、介质 |
| [docs/device-tree.md](docs/device-tree.md) | 设备树策略、继承 dtsi ≠ 继承 board、U-Boot 板级 dtsi、dtc 坑 |
| [docs/build.md](docs/build.md) | 构建环境、目录结构、17 项校验、包集合、产物、可复现性 |
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

⚠️ **本移植的引导程序有随机 panic 的问题**（6 次启动 3 次崩），所以下面"启动"和
"eMMC 引导"两行的证据都注明了是由**哪一次**运行给出的。用 Armbian 的引导程序启动
稳定，用本移植的那份不稳定 —— 详见顶部状态节。

| 外设 | 状态 | 关键证据 |
|---|---|---|
| 启动（Armbian 引导程序） | ✅ 稳定 | microSD（USB 读卡器）引导 → `/boot.scr` → `Linux-6.12.94` kernel FIT + `radxa_rock-4b-plus` dtb 63877 B，crc32+sha1 通过 → `procd: - init -`。**6 次启动零 panic**（tty6/tty11 挂上 root，tty4/tty5 到 shell） |
| **启动（本移植引导程序）** | ⚠️ **不稳定** | 同一条链路跑通，但 6 次里 1 次挂上 root（tty8）、3 次 panic（tty8/tty10/tty12）、2 次日志早断。**根因在 DRAM 初始化**，见顶部状态节 |
| 身份 | ✅ | `model: Radxa ROCK 4B+`、`board_name: radxa,rock-4b-plus` |
| **以太网** | ✅ 1Gbps | `Link is Up - 1Gbps/Full - flow control rx/tx` → `br-lan: ... forwarding state` |
| **eMMC 32G** | ✅ 硬件 + **引导已验** | `mmc0: new HS400 Enhanced strobe MMC card` → `SLD32G 28.9 GiB`；Maskrom 写入整包后 **tty8 首次从 eMMC 挂上 root**（`VFS: Mounted root (ext4 filesystem) on device 179:2`，`mmc@fe330000.bootdev.part /boot.scr`） |
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

**本移植 U-Boot 的随机 panic 是唯一还没解决的问题**，而且它比别的都重要 —— 引导程序
不稳定意味着镜像不能算可交付。已定位到 DRAM 初始化这一层，但**在拿到 Armbian 的
U-Boot 源码比对之前不要改参数**，那只会是猜。详见
[docs/postmortem-dram-instability.md](docs/postmortem-dram-instability.md)。

**eMMC 安装**已通过 Maskrom 写入整包验证（tty8 挂上 root），`dd` 流程另见
[docs/flashing.md](docs/flashing.md)。

⚠️ eMMC 上现在是 OpenWrt 镜像（p1 16 MiB + p2 512 MiB，磁盘标识 `0x5452574f`）。
早先那套 Armbian 在之前的实验里已被覆盖过一次且没有备份。

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
- [x] Phase 5l：诊断随机 panic —— 12 次启动对照实验，根因缩小到 DRAM 初始化
- [ ] **Phase 5m（最高优先级）：修 DRAM 初始化** —— 6 次启动 3 次 panic，镜像因此
      不能算可交付。需先拿到 Armbian 的 U-Boot 源码比对，**不要凭猜测改参数**
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