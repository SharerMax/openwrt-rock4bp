# 硬件参考

Radxa ROCK 4B+ 的硬件事实、板型辨识、排针、版本差异、板载按键与介质。

事实来源：Radxa 官方文档 `docs.radxa.com` → `rock4/rock4ab-se`（原始 markdown 取自
`github.com/Radxa-Docs/docs`）、同目录的 `radxa-rock4b-plus-product-brief.pdf`，
以及板上的实测。

**凡标"实测"的都来自真机，未标的一律以官方文档为准。**

---

## 板型辨识

- **ROCK (Pi) 4B Plus 与 ROCK 4B+ 是同一块板。** 2022 年 Radxa 去掉了产品线名字里的
  "Pi"（旧 wiki 原文：*both ROCK Pi 4 and ROCK 4 refer the same product, the model
  number is what the users should pay attention*）。**但 ROCK 4B / 4A 是另一块板**
  （RK3399 + RK808 + 可拆卸 eMMC 模组），不要混淆。
- 本板 = **OP1(RK3399-T) + RK808**，对应上游 `rk3399-rock-pi-4b-plus.dts` +
  `rk3399-rock-pi-4.dtsi`。**上游已有经硬件验证的设备树**，本移植直接继承。
- Radxa 文档另有一条：4A/4B/4SE 用**可拆卸 eMMC Module**，**4A+/4B+ 是板载 eMMC**，
  所以 4B+ 刷机走 maskrom over USB 而不是模组读卡器。

### ⚠️ 不要用 U-Boot 的字符串反推板型

我曾根据 U-Boot 打印的 `PMIC: RK808` / `Model: Radxa ROCK Pi 4B` 反推"这是 4B 不是
4B+"，**属于循环论证** —— Armbian 的 U-Boot 字符串是其自身配置，不能当作板型证据。
**板型以实物确认为准。**

---

## 硬件事实

| 项目 | 值 |
|---|---|
| SoC | Rockchip RK3399-T (OP1)，双 Cortex-A72 @ 2016MHz + 四 Cortex-A53 |
| PMIC | **RK808** @ i2c0 `0x1b`（节点在 `&i2c0` 内） |
| 内存 | LPDDR4 双通道，2GB 或 4GB（实物 4GB） |
| 存储 | 32GB 板载 eMMC（HS400）+ microSD + M.2 NVMe + 4MB SPI Flash（早期版贴装） |
| 以太网 | RTL8211F PHY 挂在 stmmac MAC 上，1Gbps 实测通过 |
| WiFi/BT | **AP6256**（BCM43456 SDIO + BCM4345C5 BT），sdio0 / uart0 |
| 音频 | ES8316 @ i2c1 `0x11`，i2s0，MCLK 来自 `SCLK_I2S_8CH_OUT` |
| HDMI | RK3399 dw-hdmi + VOP（**本移植未启用**，见[范围](#hdmi--音频内核里根本没编译)） |
| 按键 | **Maskrom** + Reset + **Recovery**，三颗（2026-10-10 目视确认）。⚠️ Maskrom/Recovery 任一键 + 上电即进 maskrom，**不必短接 SPI** —— 但由 **U-Boot proper** 而非 ROM 触发 |
| 调试 | UART2，**1500000 8N1**，3.3V TTL，只需 GND/TX/RX，不接 VCC |
| 状态 LED | 蓝色，gpio3_PD5 |

### 继承上游得到的、经硬件验证的值

本移植的设备树是 thin delta，以下全部来自上游 `rk3399-op1.dtsi` +
`rk3399-rock-pi-4.dtsi`，**不是自己调的**：

- PMIC 是 **RK808** @ i2c0 `0x1b`，且节点嵌在 `&i2c0` 内
- 以太网 PHY 供电是 `vcc3v3_lan`，RGMII `tx_delay 0x28` / `rx_delay 0x11`
- ES8316 @ i2c1 `0x11`，MCLK 取自 `SCLK_I2S_8CH_OUT`，挂在 i2s0
- 耳机检测是 gpio1_A0，codec 中断是 gpio1_A1
- 状态 LED（蓝色）是 gpio3_PD5

---

## 40-pin 排针注意事项

`GPIO3_C0` 是 **1.8V**，其余是 **3.0V**。用排针时注意电压。

`rk3399-base.dtsi` 的 pinctrl 组与 Product Brief 的 40-pin 表**完全吻合**
（`spi1`=GPIO1_B0/A7/B1/B2、`spi2`=GPIO2_B3/B2/B1/B4、`uart2c`=GPIO4_C4/C3、
`uart4`=GPIO1_B0/A7、`pwm0/1`=GPIO4_C2/C6、`i2s1_2ch_bus`=GPIO4_A3..A7），所以排针功能
不用自己写 pinctrl，直接 `&spi1` / `&uart2c` 引用即可 —— **但彼此复用引脚，一次只能
开一组**（SPI1 ↔ UART4、SPI2 ↔ I2C6）。

---

## 硬件版本变更

**V1.73 起 SPI Flash 不贴装**；2021 年主线补丁里 Radxa 官方原话是 *"dev boards have SPI
flash soldered, but as per manufacturer response, this won't be the case for mass
production boards"*。串口日志里的 `SF: Detected XT25F32B ... total 4 MiB` 印证本板是
早期版（约 V1.6 / V1.72）。

**影响**：U-Boot 保留 SPI 引导和环境变量支持。

⚠️ 这个差异不只是"有没有 SPI"的问题 —— 早期版 SPI 上那份能用的引导程序会**挡在
最前面**，直接影响能否验证本移植的引导程序。见 [boot-order.md](boot-order.md)。

---

## 板载按键：Maskrom、Reset、Recovery

板上有**三颗**按键：**Maskrom**、**Reset**、**Recovery**（2026-10-10 目视确认）。

⚠️ **本文此前长期写成"只有 Maskrom + Reset，没有 recovery 键"，是错的。** 依据是旧 wiki
恰好记了三颗、而 Radxa 当前文档只提一颗，于是当时选了"以官方文档为准"把旧记录否掉了 ——
**两处都没看过实物，就二选一**。Recovery 键是有的。

| 按键 | 谁在采样 | Linux 侧 | 进 maskrom |
|---|---|---|---|
| **Maskrom** | boot ROM，**上电瞬间**采样 | 无输入（实测按住无任何 GPIO 变化） | ✅ **不用短接 SPI**（已验证） |
| **Reset** | 引导程序（复位整个 SoC） | 无输入 | ❌ 不适用 |
| **Recovery** | boot ROM，**上电瞬间**采样 | 无输入 | ✅ **不用短接 SPI**（已验证） |

Maskrom / Recovery 两颗键按住 + 上电即进 maskrom，**Linux 侧不存在对应输入**（实测按住
没有任何 GPIO 电平变化）。Radxa 和主线的 board 文件都**没有** gpio-keys 节点，本移植的
DTS 里也刻意没有。

> 曾经猜了一个 `gpio4_B2` 的 gpio-keys 节点，实测无 GPIO 变化后已删除。

### ⭐ Recovery 键也能进 maskrom —— **不必再短接 SPI**

⚠️ **2026-10-10 实测推翻了"进 maskrom 必须短接 SPI"这条。**

| 组合 | 是否枚举出 maskrom 设备 |
|---|---|
| 只按 **Recovery** | ✅ **能**（未短接 SPI） |
| 只按 **Maskrom** | ✅ **能**（未短接 SPI） |
| Recovery + Maskrom 同时按 | ✅ 能 |

⚠️ **重复多次，每次都出现** —— 不是一次侥幸。

**Recovery 键之前根本没人知道它在，因为文档先把它否掉了。** 这就是本仓库反复吃亏的那类
错误：两个书面来源不一致时选了其中一个，而不是看一眼实物。

### 机制：是 **U-Boot proper** 进的 maskrom，不是 boot ROM

⚠️ **2026-10-11 `log/tty19.txt` 把机制测出来了，而且和当时的推测相反。**

```
 40: Model: Radxa ROCK 4B+                        <- U-Boot proper 已经完整跑起来
 41: download key pressed, entering download mode...resetting ...
 42: DDR Version 1.27 20211018                    <- boot ROM 重新从零初始化 DRAM
 44: soft reset
109: Boot1 Release Time: Jun  2 2020 15:02:17, version: 1.26   <- ROM 自己的标识
115: UsbBoot ...74128                            <- ROM 的 USB download 路径
```

**因果顺序是：ROM → TPL → SPL → U-Boot proper → U-Boot proper 发现按键 → 复位 → ROM 的
USB download 路径。** 那行 `download key pressed` 出现在 `Model:` 和 `Loading Environment
from MMC` **之后**，所以它出自 **U-Boot proper**，不是 ROM、也不是 SPL。

⚠️ **因此"ROM 在上电时采样 recovery 脚、抢在 SPI 之前进 USB download"这个解释是错的**，
而且是被这份日志否掉的 —— ROM 要是真在采样，U-Boot proper 就不会先跑起来。
`UsbBoot` 那行来自 ROM，但它是**被 U-Boot proper 用一次 soft reset 请过来的**。

**这条在 24 份抓取里只出现在 `tty19`，只出现一次**（`download key` 全库检索），其余 23 份
一次都没有。所以它确实由这次按键引起，不是每次开机都打。

**一次干净的对照也在同一份日志里**：第 118 行起是第二次启动（按 TPL 横幅切分 = 2 次启动，
不能数 panic 行数），`Reset cause: unknown reset`（就是上面那次 soft reset），这一轮**没有**
按键行，正常 autoboot 进了 Linux，`mmcblk0p2` 挂上 root。**整份零 panic。**

### ⚠️ 两条路**不等价** —— 这条比机制本身更要紧

| | 按键（Recovery / Maskrom） | 短接 SPI CLK 引脚 |
|---|---|---|
| 谁进 maskrom | **U-Boot proper 复位后**，ROM 才进 | **ROM 自己**直接进 |
| 需要引导程序能跑吗 | ⚠️ **需要** | 不需要 |
| 本板实测 | ✅ | ✅（2026-10-06 救过砖） |

⚠️ **按键这条路要先有一个能跑起来的 U-Boot proper。** 这正是救砖场景里最不成立的前提 ——
**引导程序坏掉时按键能不能救回来，没有测过，不要假定能。**

**短接引脚那一步因此必须保留为兜底，它不是"多余的旧做法"。** 之前把它写成"可以省掉的、
可能短错的步骤"是错的：那一步买到的是**不依赖引导程序**。

（按键仍然更方便，值得作为首选；但**兜底顺序不能因为按键好用就丢掉短接**。）

### 进 Maskrom 的步骤

**首选：按住板上的键（2026-10-10 实测，重复多次）**

```
① 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
② 主板未供电前按住 Maskrom 或 Recovery 按键
③ 使用电源适配器给主板供电
④ 主板供电后松开按键
若主板电源绿灯常亮，说明成功进入 Maskrom 模式。
```

成功后 PC 上会枚举出 Rockchip 的 maskrom USB 设备（旧 wiki 记为 `2207:330c`），
用 `rkdeveloptool` 或官方 `rk3399_loader` 刷写。

⚠️ **前提：这条路要有一个能跑起来的 U-Boot proper**（见上面「两条路不等价」）。
引导程序跑不起来时它**能不能救回来，没测过**。

**兜底：Radxa 官方五步流程（2026-10-06 真机救回过一块起不来的板子）**

```
① 若主板有 SPI Flash，需将 SPI Flash 对应引脚接 GND
② 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
③ 主板未供电前按住 Maskrom 按键
④ 使用电源适配器给主板供电
⑤ 主板供电后松开 Maskrom 按键
```

⚠️ **第 ① 步不是多余的，它买的是"不依赖引导程序"。** 由 ROM 直接进 maskrom，所以
**引导程序坏掉时只有这条路已知可用**。⚠️ 官方流程只写了按 Maskrom 键；**Recovery 键 +
短接的组合没有测过**，不确定是否等价。

⚠️ 后面 `db` / `wl` **选错 loader** 仍然会静默写到另一块介质 —— 两条路都一样，这是另一个坑。

✅ **两条进 maskrom 的路径都在真机验证过**（2026-10-06 官方五步含短接，救回过砖；
2026-10-10/11 按键直进，重复多次，`log/tty19.txt` 有完整串口记录）。

⚠️ **别把"短接 SPI"读成"绕过 SPI 的手段"。** 实测短接**不会**让 boot ROM 跳过 SPI：

| 现象 | 说明 |
|---|---|
| 短接后 `mtd0` 消失 | 短接对 Linux 确实生效 |
| 串口第一行仍是 `U-Boot TPL 2022.07_armbian` | **boot ROM 照样从 SPI 加载引导程序** |
| `Loading Environment from SPIFlash` 仍出现 | U-Boot proper 也照样读 SPI |

**SPI 在 boot ROM 里排第一，只要它能被读到就赢。**

⚠️ **2026-10-11：为什么按了键还能枚举出 maskrom，已经测出来了 —— 但答案和"SPI 排第一"
的关系比想象的绕。** 按键那条路**根本不是 ROM 在上电时选的**：ROM 正常把引导程序跑起来，
**U-Boot proper 自己发现按键、自己复位**，ROM 才在复位后进 USB download 路径
（`download key pressed` → `UsbBoot`，见上面「机制」一节和 `log/tty19.txt`）。

所以"按键优先级高于 SPI"和"SPI 排第一所以按键没用"**两个说法都不对**：按键根本没有参与
ROM 的介质选择，它作用在 U-Boot proper 这一层。

⚠️ **而这份日志反过来削弱了一条老推论。** `Trying to boot from BOOTROM` /
`Returning to boot ROM...` 这两行**在这次完全成功的启动里也出现了**，位置一模一样
（第 9–10 行和第 126–127 行，后面都跟着 SPL 并一路进到 Linux）。⚠️ **它们出现在正常
成功路径上，所以不能拿来证明"SPI 上没有可引导镜像"。** 见 [boot-order.md](boot-order.md)。
⚠️ SPI 上现在究竟有没有可引导镜像，**这份日志没有回答**，仍然是未测。

---

## 介质

**⚠️ 当前在用的是 microSD 卡插在 USB 读卡器里，不是板载 SD 卡槽。** 内核看到的是
`sda`（`AI Mass Storage`，3.7 GB），不是 `mmc1`。**板载 SD 卡槽这条路径至今未验证。**

**最早那块 SD 卡坏了，不要再用。** 第一次烧 SD 卡时出现 `I/O error ... sector 135842` 加
`SQUASHFS error -5`，rootfs 读不了；换 U 盘烧**同一镜像**一次启动成功 —— 是那张卡的
问题，不是镜像的问题。

上板前先用 `gzip -dc <image> | sha256sum` 回读校验，区分"写入不完整"与"卡损坏"。

---

## eMMC 状态的变迁（实测）

⚠️ **这一节改过两次，都记下来** —— "记录当时为真的结论、之后不复查"是本仓库反复
吃亏的地方，而 eMMC 布局恰好是变化最频繁的一项。

### 一度被描述成"裸分区，内容未知"——**那是错的**

当时的结论来自启动日志里没有分区名，**而没有实际去读**。只读挂载一看，其实是完整的
Armbian 26.11.0-trunk.62（内核 6.18.54、hostname `rockpi-4b`、1.5 GB、含用户 `rock`
家目录）。

### 被 `dd` 覆盖过一次，没有备份

那次写 OpenWrt 镜像时是在明确告知后选择直接覆盖的，**代价是那套 Armbian 和
`/home/rock` 永久消失**。后来重装过一次，实测布局是单个 29280 MiB 的 ext4：

```
179 1  29982720  mmcblk0p1
mmcblk0p1 offset 1080 处: 53 ef          ← ext4 superblock magic
mmcblk0p1 前 4 MiB 里的字符串:
  /lib/firmware/regulatory.db-debian
  /usr/bin/which.debianutils
```

### 2026-10-08：又装回 Armbian

⚠️ **10-06 那次 Maskrom 写进去的 OpenWrt 镜像已经不在盘上了。** 现在是重装的
Armbian 26.11.0-trunk.62（来自 `armbian/build`，内核 6.18.54，hostname `rockpi-4b`）：

```
mmcblk0   28.9G
└─mmcblk0p1  28.6G  ext4  /        ← 单个分区，不是 OpenWrt 的 p1/p2 布局
/proc/cmdline: root=UUID=7043da66-b456-4a16-99c4-d7610de391c0
               ubootpart=d2a80aa7-01
```

**引导路径：SPI 里的 Armbian U-Boot → eMMC**（`ubootpart` 指向 eMMC 分区）。
dmesg 只有 3 条已知无害报错（PCIe `-110`、uart DMA、sound deferred probe），
无内存错误。板子可达 `192.168.3.8`，`root`，无密码（eMMC 上是本移植的 OpenWrt，
不是 Armbian）。

这是补上「Armbian TPL + eMMC 引导」那格对照的第一份数据 —— **只 1 次**，
而判据是 6 次。

### ⚠️ 这一节改过四次，每次状态都不同

写任何"eMMC 上是什么"之前，先只读地读一遍
(`lsblk` / `/proc/partitions` / `/proc/cmdline`)，不要相信文档里任何一行。
写入方式见 [flashing.md](flashing.md)。

---

## HDMI / 音频：内核里根本没编译

`target/linux/rockchip/armv8/config-6.12` 里**没有任何 DRM / SND / FB 配置项**，构建出来
的 `.config` 里 `^(CONFIG_SND|CONFIG_DRM|CONFIG_FRAMEBUFFER)` 匹配 **0 行**。设备树节点
在枚举（所以日志里能看到 `/hdmi@ff940000` 的 dependency cycle），但**没有任何驱动存在**。

OpenWrt 的 rockchip 目标是照路由器设计的 —— 路由器不需要显示和声音。

即使打开内核开关，OpenWrt 25.12.5 也没有对应的 kmod 包：

| 需求 | 内核配置 | OpenWrt 包 | 现状 |
|---|---|---|---|
| HDMI 视频 | `DRM`, `DRM_ROCKCHIP`, `DW_HDMI_ROCKCHIP` | `kmod-drm-rockchip` | **无此包**（video.mk 只有 amdgpu/i915/imx/radeon…） |
| HDMI 音频 | `SND_HDA_INTEL`, `SND_HDA_CODEC_HDMI`, `SND_HDA_CORE` | `kmod-sound-hda-core`, `kmod-sound-hda-codec-hdmi` | 包齐全，只是配置没开 |
| 模拟音频 | `SND_SOC_ROCKCHIP_I2S`, `SND_SOC_ES8316`, `SND_SOC_SIMPLE_CARD` | `kmod-sound-soc-es8316`, `kmod-sound-soc-rockchip` | **两个都没有** |

RK3399 的 HDMI 由 `dw-hdmi-rockchip.ko` + `rockchipdrm.ko` 提供，`dw-hdmi.ko` 只被打进
`kmod-drm-imx-hdmi`（给 i.MX 用的），不通用。

**恢复成本**：HDMI 需新建 1 个 kmod 包，音频需新建 2 个。两者都**不阻塞使用** ——
SSH/串口 + 1Gbps 网口 + WiFi 均已可用。

---

## 无害的残留提示

```
Cannot parse config file '/etc/fw_env.config': No such file or directory
Failed to find NVMEM device
```

`uboot-envtools` 想写 SPI 环境变量但缺配置文件（`/etc/fw_env.config` 不存在）。
**不影响启动。**

⚠️ 早先文档写"U-Boot 报的 `bad CRC` 就是它" —— **这个归因没有验证过，已撤回**。
`bad CRC, using default environment` 从项目最开始就有，早于 SPI 节点、也早于短接 SPI，
所以它不是缺配置文件造成的。更可能的原因是这块 SPI 在 Linux/U-Boot 下读不到正确内容，
但**这只是推测，没有证据，不下结论**。

---

## 相关文档

- [boot-order.md](boot-order.md) — SPI → eMMC → SD，以及 SPI 读不对这件事
- [flashing.md](flashing.md) — 烧卡、首次启动、eMMC 安装、Maskrom
- [device-tree.md](device-tree.md) — 设备树策略与 U-Boot 板级 dtsi