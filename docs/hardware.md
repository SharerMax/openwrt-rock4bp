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
| 按键 | **Maskrom** + Reset（无 recovery 键） |
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

## 板载按键：是 Maskrom，不是 recovery

板上按键是 **Maskrom 按键**，功能由 **boot ROM 在上电瞬间**采样决定 —— Linux 侧不存在
对应事件。**实测：按住按键没有任何 GPIO 电平变化。** 这与"按键由 boot ROM 采样"一致
—— 如果它同时被 Linux 当输入用，按下就该在 debugfs 里看到变化。Radxa 和主线的 board
文件都**没有** gpio-keys 节点，本移植的 DTS 里也刻意没有。

> 曾经猜了一个 `gpio4_B2` 的 gpio-keys 节点，实测无 GPIO 变化后已删除。

旧 wiki 记的是"三个按键 maskrom / reset / recovery，同时按住 maskrom + reset 进
maskrom"。而 Radxa **当前**文档对 4A+/4B+ 只提一个 Maskrom 按键，且操作是"按住 + 上电"。
**以官方文档为准。**

### 进 Maskrom 的步骤

```
① 若主板有 SPI Flash，需将 SPI Flash 对应引脚接 GND
② 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
③ 主板未供电前按住 Maskrom 按键
④ 使用电源适配器给主板供电
⑤ 主板供电后松开 Maskrom 按键
若主板电源绿灯常亮，说明成功进入 Maskrom 模式。
```

第 ① 步对这块板**必需** —— 本板贴了 SPI Flash，不短接的话 SPI 里的 U-Boot 会先接管。
成功后 PC 上会枚举出 Rockchip 的 maskrom USB 设备（旧 wiki 记为 `2207:330c`），
用 `rkdeveloptool` 或官方 `rk3399_loader` 刷写。

✅ **Maskrom 已在真机验证可用**（2026-10-06）：用官方 `rk3399_loader` 加 Armbian 的引导
程序，把起不来的板子救回了。

⚠️ **别把"短接 SPI"读成"绕过 SPI 的手段"。** 实测短接**不会**让 boot ROM 跳过 SPI：

| 现象 | 说明 |
|---|---|
| 短接后 `mtd0` 消失 | 短接对 Linux 确实生效 |
| 串口第一行仍是 `U-Boot TPL 2022.07_armbian` | **boot ROM 照样从 SPI 加载引导程序** |
| `Loading Environment from SPIFlash` 仍出现 | U-Boot proper 也照样读 SPI |

**SPI 在 boot ROM 里排第一，只要它能被读到就赢。** 短接只对进 maskrom 有用 —— 那正是
Radxa 写它的用途。

---

## 介质

**⚠️ 当前在用的是 microSD 卡插在 USB 读卡器里，不是板载 SD 卡槽。** 内核看到的是
`sda`（`AI Mass Storage`，3.7 GB），不是 `mmc1`。**板载 SD 卡槽这条路径至今未验证。**

**最早那块 SD 卡坏了，不要再用。** 第一次烧 SD 卡时出现 `I/O error ... sector 135842` 加
`SQUASHFS error -5`，rootfs 读不了；换 U 盘烧**同一镜像**一次启动成功 —— 是那张卡的
问题，不是镜像的问题。

上板前先用 `gzip -dc <image> | sha256sum` 回读校验，区分"写入不完整"与"卡损坏"。

---

## eMMC 当前状态（实测）

⚠️ 早期文档写过"`dd` 已完成并校验、整盘 sha256 一致（`5847c611…`）"。**现在 eMMC 上不是
那个布局** —— 后来 eMMC 被重装了。板上实测：

```
/proc/partitions
  179 0   30310400  mmcblk0        ← 28.9 GiB
  179 1   29982720  mmcblk0p1      ← 单个 29280 MiB 分区

mmcblk0  MBR 签名 55 aa 有效
mmcblk0p1 offset 1080 处: 53 ef    ← ext4 superblock magic
mmcblk0p1 前 4 MiB 里的字符串:
  /lib/firmware/regulatory.db-debian
  /usr/bin/which.debianutils
```

单个 28.6 GB ext4 + Debian 文件名 = **Armbian**，不是 OpenWrt 镜像的
`p1 16 MiB + p2 512 MiB`。当前运行系统是 OpenWrt 25.12.5，root 在 `/dev/root` 上
`type ext4` —— 跑的是 **SD 卡**，不是 eMMC。

> 那个 `5847c611…` 的 `dd` 校验结论本身没错，它说的是**当时**写对了字节。

**⚠️ 一条代价记录。** 原始那块 eMMC 上装着完整的 Armbian 26.11.0-trunk.62（内核 6.18.54、
hostname `rockpi-4b`、1.5 GB、含用户 `rock` 家目录），**被那次 `dd` 覆盖掉了且没有备份**。
现在这套是后来重装的，不是原来那套。

> 早期文档在这里也记错过：只看启动日志里没有分区名就下结论说"裸分区、内容未知"，
> 没真去读 —— 结果明明是完整可用的系统。

**eMMC 引导至今没有任何真机证据**，只验证到"字节写对了"为止。现在 SPI 上是 Armbian 的
U-Boot，它的 `BOOT_TARGETS` 里 `mmc0` 排在 USB 之前，所以原理上这条路是通的，只是
还没试。详见 [flashing.md](flashing.md)。

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