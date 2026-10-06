# OpenWrt 25.12.5 → Radxa ROCK (Pi) 4B Plus 移植

把 OpenWrt **25.12.5**（分支 `openwrt-25.12`，tag `v25.12.5`，commit
`f0a60eee2fe051741c643ea6118718aae1ef17fb`）移植到 **Radxa ROCK (Pi) 4B Plus**
（2022 年改名后叫 **ROCK 4B+**），硬件为**早期版本：有 4MB SPI Flash、32G 板载
eMMC，约 V1.6 / V1.72，非 V1.73 量产版**。

WiFi 排查有独立文档：[`docs/WIFI-INVESTIGATION.md`](docs/WIFI-INVESTIGATION.md)。
烧卡步骤见 [`FLASHING.md`](FLASHING.md)。

---

## 状态：系统可启动可用

分支 `radxa-rock-4b-plus`，基线 `v25.12.5`：

```
a1c0ac7353  firmware: add brcmfmac-firmware-43456-sdio for the AP6256
55a6a7f064  rockchip: radxa,rock-4b-plus: drop the guessed gpio-keys node
00d0cc9f48  rockchip: radxa,rock-4b-plus: restore WiFi/BT and fix device packages
ac700b2f8d  rockchip: do not track the .config backup file
4bab0883a3  rockchip: add Radxa ROCK (Pi) 4B+ support
```

未推送到任何上游 remote。设备树是**继承上游**的 130 行 delta，维护成本极低。

### 已验证可用

| 外设 | 状态 | 关键证据 |
|---|---|---|
| 启动 | ✅ | U 盘引导 → `procd: - init -` → `Please press Enter to activate this console.` |
| 身份 | ✅ | `model: Radxa ROCK 4B+`、`board_name: radxa,rock-4b-plus` |
| **以太网** | ✅ 1Gbps | `Link is Up - 1Gbps/Full - flow control rx/tx` → `br-lan: ... forwarding state` |
| **eMMC 32G** | ✅ | `mmc0: new HS400 Enhanced strobe MMC card` → `SLD32G 28.9 GiB` |
| **USB** | ✅ | 2×xHCI(SS) + 2×EHCI + 2×OHCI，U 盘识别为 `sda 7880800` |
| USB 引导 | ✅ | U-Boot 默认链含 `usb`，零配置 |
| **WiFi 硬件层** | ✅ | `mmc2: new ultra high speed SDR104 SDIO card`；`gpio-10 (reset) out hi` |
| **BT 硬件层** | ✅ | `ff180000.serial: ttyS0 at MMIO 0xff180000` |
| RK808 PMIC | ✅ | `rk808-regulator` + 2×`fan53555-regulator ... Detected` |
| RTC | ✅ | `rk808-rtc registered as rtc0` |
| rootfs/overlay | ✅ | squashfs / ext4 → f2fs overlay |
| CPU | ✅ | `SMP: Total of 6 processors activated` |

### 主动划出范围

| 项 | 性质 | 恢复成本 |
|---|---|---|
| **WiFi 固件运行** | 固件包已做好并验证进镜像，但**芯片不肯跑固件** | 见 `docs/WIFI-INVESTIGATION.md`。同类故障在其它 AP6256 板子上也有，Radxa 自己的 DTS 和驱动映射与我们完全一致 |
| **HDMI 视频** | 内核 `CONFIG_DRM` 全关 + OpenWrt **无 `kmod-drm-rockchip`** | 新建 1 个 kmod 包，可进上游 |
| **音频** | 缺 `kmod-sound-soc-es8316` + `kmod-sound-soc-rockchip` | 新建 2 个 kmod 包，工作量最大 |

三者都**不阻塞使用**：SSH/串口 + 1Gbps 网口已可用。

### 还剩一件事

**eMMC 安装**（`dd` 流程已核对，见 FLASHING.md 第 7 节）。镜像、内核、U-Boot 引导链
都已验证，只是安装流程没走通过。U-Boot 的 `BOOT_TARGETS` 里 `mmc0` 就是 eMMC 且排在
USB 之前，**不需要改任何环境变量**。

⚠️ 板载 eMMC 上现有一个分区 `p1`（内容未知，U-Boot 跳过它直接走了 USB）。`dd` 前必须
先只读地看清里面是什么。

---

## ⚠️ 板型辨识：我在这上面犯过错

- **ROCK (Pi) 4B Plus 与 ROCK 4B+ 是同一块板**。2022 年 Radxa 去掉了产品线名字里的
  "Pi"（旧 wiki 原文：*both ROCK Pi 4 and ROCK 4 refer the same product, the model
  number is what the users should pay attention*）。**但 ROCK 4B / 4A 是另一块板**
  （RK3399 + RK808 + 可拆卸 eMMC 模组），不要混淆。
- 本板 = **OP1(RK3399-T) + RK808**，对应上游 `rk3399-rock-pi-4b-plus.dts` +
  `rk3399-rock-pi-4.dtsi`。**上游已有经硬件验证的设备树**，本移植直接继承。
- 我曾根据 U-Boot 打印的 `PMIC: RK808` / `Model: Radxa ROCK Pi 4B` 反推"这是 4B 不是
  4B+"，**属于循环论证**（Armbian 的 U-Boot 字符串是其自身配置，不能当作板型证据），
  结论错误。板型以用户实物确认为准。
- **板载按键不是 recovery 键，是 Maskrom 键**。我曾猜了一个 `gpio4_B2` 的 `gpio-keys`
  节点，实测按住无任何 GPIO 变化后已删除。

---

## 构建环境

| 项 | 值 |
|---|---|
| 构建机 | `hyv-ub24`，Ubuntu 24.04.5，10 核，10GB RAM |
| 源码树 | `/home/max/Code/openwrt` |
| 工具链 | gcc 14.3.0，binutils 2.44，musl |
| 内核 | 6.12.94（v25.12.5 pin 的版本，hash `e998a232b941…`） |
| U-Boot | mainline 2025.10 |
| 配置 | `rockchip/armv8` → `radxa_rock-4b-plus` |

### ⚠️ umask 必须设为 022

构建机的默认 umask 是 `0002`，而 `include/prereq-build.mk` 会硬性检查并拒绝非 022。
`scripts/build.sh` 里已经 `umask 022`。

### 依赖

按 `include/prereq-build.mk` + `include/u-boot.mk` 逐条核对安装，全部满足。

### remote 配置

gitee 镜像停更在 `8dff4c9a34`，已改为官方源：`origin` = github，`origin-git` =
git.openwrt.org，`gitee` 仅作参考。**不要用 curl 测远端可达性**（本机 Windows 没有
curl），用 `git ls-remote`。

### 磁盘是当前最大约束

构建机 58G，已用 35G，剩 21G。Debian 的 `firmware-nonfree` 源包 105MB 只是为了取一个
483KB 的文件，下载完立刻删掉。

---

## 目录结构

```
README.md                                          本文件
FLASHING.md                                        烧卡 / 烧 eMMC / 兜底方案
docs/WIFI-INVESTIGATION.md                         WiFi 排查完整记录
radxa_rock4bp_product_brief_Revision_1.1.pdf      Radxa 官方 Product Brief
overlay/                                           按 OpenWrt 源码树路径镜像
  target/linux/rockchip/image/armv8.mk             +20 行：radxa_rock-4b-plus
  package/boot/uboot-rockchip/Makefile             +8 行：U-Boot 变体 + UBOOT_TARGETS
  package/firmware/broadcom-nonfree/Makefile       新增：BCM43456 固件包
  u-boot/rock-4b-plus-rk3399_defconfig             U-Boot defconfig（基于 rock-4se）
  kernel/rk3399-rock-4b-plus.dts                   130 行 delta，继承上游两个 dtsi
scripts/
  build.sh                                         构建脚本（manifest + 构建后 9 项校验）
  regen-dts-patch.sh                               重新生成内核/U-Boot 补丁 + dtc 校验
  wifi-test.sh                                     AP6256 上电测试（每组合一次冷启动）
  deploy.sh                                        把 overlay 同步到远端源码树
log/  tty2.txt tty3.txt tty4.txt tty5.txt          四次上机的串口日志
```

`scripts/build.sh` 是**包集合清单的唯一可复现来源** —— `.config` 在 OpenWrt 里是
gitignore 的，只存在于构建机上，所以清单决定写进了脚本里。

远端同步采用覆盖法：`scp` 把 `overlay/` 下的文件按相对路径拷进远端源码树。因上游固定在
`v25.12.5`，本地保存完整副本不会有漂移问题。

---

## 硬件事实（已核实来源）

来源：Radxa 官方文档 `docs.radxa.com` → `rock4/rock4ab-se`，原始 markdown 取自
`github.com/Radxa-Docs/docs`。

| 项目 | 值 |
|---|---|
| SoC | Rockchip RK3399-T (OP1)，双 Cortex-A72 @ 2016MHz + 四 Cortex-A53 |
| PMIC | **RK808** @ i2c0 `0x1b`（节点在 `&i2c0` 内） |
| 内存 | LPDDR4 双通道，2GB 或 4GB（实物 4GB） |
| 存储 | 32GB 板载 eMMC（HS400）+ microSD + M.2 NVMe + 4MB SPI Flash（早期版贴装） |
| 以太网 | RTL8211F PHY 挂在 stmmac MAC 上，1Gbps 实测通过 |
| WiFi/BT | **AP6256**（BCM43456 SDIO + BCM4345C5 BT），sdio0 / uart0 |
| 音频 | ES8316 @ i2c1 `0x11`，i2s0，MCLK 来自 `SCLK_I2S_8CH_OUT` |
| HDMI | RK3399 dw-hdmi + VOP |
| 按键 | **Maskrom** + Reset（无 recovery 键） |
| 调试 | UART2，**1500000 8N1**，3.3V TTL，只需 GND/TX/RX，不接 VCC |

### 40-pin 排针注意事项

`GPIO3_C0` 是 **1.8V**，其余是 **3.0V**。用排针时注意电压。

`rk3399-base.dtsi` 的 pinctrl 组与 Product Brief 的 40-pin 表**完全吻合**
（`spi1`=GPIO1_B0/A7/B1/B2、`spi2`=GPIO2_B3/B2/B1/B4、`uart2c`=GPIO4_C4/C3、
`uart4`=GPIO1_B0/A7、`pwm0/1`=GPIO4_C2/C6、`i2s1_2ch_bus`=GPIO4_A3..A7），所以排针功能
不用自己写 pinctrl，直接 `&spi1` / `&uart2c` 引用即可 —— **但彼此复用引脚，一次只能
开一组**（SPI1 ↔ UART4、SPI2 ↔ I2C6）。

### 硬件版本变更

V1.73 起 SPI Flash **不贴装**；2021 年主线补丁里 Radxa 官方原话是 *"dev boards have SPI
flash soldered, but as per manufacturer response, this won't be the case for mass
production boards"*。串口日志里的 `SF: Detected XT25F32B ... total 4 MiB` 印证本板是
早期版。**影响**：U-Boot 保留 SPI 引导和环境变量支持。

Radxa 文档另有一条：4A/4B/4SE 用**可拆卸 eMMC Module**，**4A+/4B+ 是板载 eMMC**，
所以 4B+ 刷机走 maskrom over USB 而不是模组读卡器。

---

## 设备树策略（本次移植的核心决策）

**继承上游，不自行描述外设拓扑。**

第一版我手写了约 900 行设备树，猜了 PMIC 类型、regulator 拓扑、codec 地址、RGMII 延时、
耳机检测 GPIO。**每一个猜测都是错的或不可用的**，结果板子能启动内核但没有可用电源轨、
没有以太网、没有 USB。

继承 `rk3399-op1.dtsi` + `rk3399-rock-pi-4.dtsi` 后，这些错误类别整体消失。

从上游继承并依赖的、经硬件验证的事实：

- PMIC 是 **RK808** @ i2c0 `0x1b`，且节点嵌在 `&i2c0` 内
- 以太网 PHY 供电是 `vcc3v3_lan`，RGMII `tx_delay 0x28` / `rx_delay 0x11`
- ES8316 @ i2c1 `0x11`，MCLK 取自 `SCLK_I2S_8CH_OUT`，挂在 i2s0
- 耳机检测是 gpio1_A0，codec 中断是 gpio1_A1
- 状态 LED（蓝色）是 gpio3_PD5

### ⚠️ 继承 dtsi ≠ 继承 board 文件

这是本次最贵的一个概念错误。

`rk3399-rock-pi-4.dtsi` 只放 4A/4B **共用**的外设管道；**板级 override 在
`rk3399-rock-pi-4b-plus.dts` 里**，而 `rk3399-base.dtsi` 把相关控制器设为
`status = "disabled"`。我重写成 thin delta 时只抄了 model/compatible，**把 4 个 override
全丢了**：

```dts
&sdio0  { status = "okay"; brcmf: wifi@1 {...} }   /* WiFi */
&uart0  { status = "okay"; bluetooth {...} }       /* 蓝牙 */
&sound  { hp-det-gpio = <&gpio1 RK_PA0 ...>; }     /* 耳机检测 */
&es8316 { pinctrl-0 = <&hp_detect &hp_int>; ... }  /* codec 中断/检测引脚 */
```

后果链：

```
我漏掉了 &sdio0 { status = "okay" }
  → sdio0 保持 disabled
    → MMC 控制器不探测
      → sdio_pwrseq 不运行，复位脚 gpio0_B2 停在低电平
        → WiFi 芯片一直处于复位、不上电
          → dmesg 只有 brcmfmac 模块注册，没有任何芯片 probe
```

`/sys/kernel/debug/gpio` 里那行 `gpio-10 (|reset) out lo` 是**决定性证据**。没有它我
大概率会继续在"固件型号不对"这类方向上瞎猜。

DTS 88 → 128 行（补 override）→ 130 行（删 gpio-keys）。

### 第一次上机失败的根因（单一连锁故障）

```
rk809 节点被放在根节点，且 &i2c0 从未使能（base.dtsi 默认 status="disabled"）
  → PMIC 不 probe → vcc3v3_sys 不存在
    → vcc_3v3 / vcc3v3_phy1 / vcc5v0_host 全部 deferred (-517)
      → gmac 拿不到 PHY regulator、usb2phy 建不起来、SDIO 无时钟、eMMC 无 PHY
        → rootfs 挂不上
```

注意芯片本身就猜错了 —— 是 **RK808**，不是 RK809。

### 编译期踩过的 dtc 坑

全部在编译期就暴露，没有一个带到板子上。定位方法：拿 `build_dir` 里已有的 dtc，以上游
`rk3399-rock-4c-plus.dts` 做对照组，用
`cpp -nostdinc -I include -I arch/arm64/boot/dts -undef -D__DTS__` + `dtc` 逐个逼近。

| 现象 | 根因 |
|---|---|
| cpp 输出只有 355 行、`es8316`/`gpio-keys` 整段消失 | 文件头 `/*` 块注释**漏了收尾 `*/`**，把第 2–520 行整段吞掉 |
| `<LED_COLOR_GREEN>` 语法错误 | 宏名是 `LED_COLOR_ID_GREEN`，漏了 `_ID` |
| `<&es8316-codec>` 语法错误 | dtc 不接受 `&` 引用里的连字符 → 用下划线 label `es8316_codec:` 前置 |
| `&pcie_phy` "Properties must precede subnodes" | `status` 写在了子节点 `pcie {}` 之后 |
| `&{/ { }}` 根节点覆盖语法错误 | dtc 不支持这种根节点覆盖写法 → 直接写进已有的 `/ { }` |
| 突然出现无关的语法错误 | 注释里写了 `$(cat ...)`，被 cpp 当成宏展开吃掉 |
| `Label or path gpio_keys not found` | 引用了不存在的 label —— 上游 4A/4B 根本没有 `gpio-keys` 节点 |

**一个方法论教训**：验证 DTS 时源文件必须放在 `dts/rockchip/` 目录下，否则
`#include "rk3399-op1.dtsi"` 的相对路径解析不到，会误报语法错误。我因此浪费了一轮。

---

## U-Boot 侧（比预想简单）

- mainline U-Boot 2025.10 **已有** `rock-4se-rk3399_defconfig`、`rock-4c-plus-rk3399_defconfig`
- **没有** `rock-4b-plus-rk3399_defconfig` → 需新增（基于 4SE，改 2 行 DT 引用）
- 4SE 的 defconfig 里已开：`CONFIG_PHY_REALTEK`、`CONFIG_RAM_ROCKCHIP_LPDDR4`、
  `CONFIG_PMIC_RK8XX`、`CONFIG_REGULATOR_RK8XX`、`CONFIG_MMC_SDHCI_{SDMA,ROCKCHIP}`、
  `CONFIG_NVME_PCI`、`CONFIG_SCSI_AHCI`、`CONFIG_VIDEO_ROCKCHIP_HDMI`、
  `CONFIG_DISPLAY_ROCKCHIP_HDMI`、`CONFIG_LED_GPIO` 及 SPI 相关项 —— 与本板需求高度吻合。
  **首次上机 DRAM 初始化成功**（LPDDR4 双通道 2048MB×2），说明这份 defconfig 可用。
- RK3399 走通用 `CONFIG_TARGET_ROCKPI4_RK3399` 板级代码，**不需要板级 C 驱动**。
- `dts/upstream/src/arm64/Makefile` 用通配符扫描 `*/*.dts`，所以把 `.dts` 放进
  `dts/upstream/src/arm64/rockchip/` 就够了，**不需要改任何 Makefile**。
- **`UBOOT_TARGETS` 是硬编码白名单**：只加 `define U-Boot/...` 不够，必须在
  `package/boot/uboot-rockchip/Makefile` 的 `UBOOT_TARGETS` 里登记。这曾经是一个真正的
  阻塞点。
- U-Boot 默认 `BOOT_TARGETS "mmc1 mmc0 nvme scsi usb pxe dhcp spi"` —— **含 USB**，
  所以 SD 卡失败后自动往后尝试，U 盘引导零配置成功。
- 本板从 SPI 读环境变量，报 `bad CRC, using default environment`（CRC 坏了所以用默认值，
  **不影响启动**）。日志里的 `Model: Radxa ROCK Pi 4B` 是 **Armbian U-Boot 自己的字符串**，
  不是板型证据。

---

## 构建配置与 manifest

### `scripts/build.sh` 的顺序是硬性的

```
1. manifest 修正（禁用 4329-sdio）
2. make defconfig      ← 改 DEVICE_PACKAGES 后必需
3. make -j10
4. 构建后 9 项校验     ← 不是装饰
```

### 三个必踩的坑

**① `scripts/config` 是构建目录，不是 helper 脚本。** 新版 OpenWrt 把它变成了
`scripts/config/` 目录，`./scripts/config --disable` 报"是一个目录"。而
`scripts/kconfig.pl` 是做 config diff 的，也没有 `--disable`。要改 `.config` 就按 kconfig
格式直接改，再让 `make defconfig` 归一化。

**② 改 `DEVICE_PACKAGES` 后必须 `make defconfig`。** 不跑的话构建只打一行
`WARNING: your configuration is out of sync`，然后**照旧把旧包集合打进镜像**。我差点把
`kmod-r8169` 之类的又带进去。

**③ 重生成补丁时"pristine"基线必须真的干净。** 上轮构建后内核树的
`dts/rockchip/Makefile` 里已经有我们那行了，直接拿来做基线会让补丁**把同一行加两次**，
dtb 目标重复会直接编译失败。`scripts/regen-dts-patch.sh` 现在会先剥掉残留行并断言它确实
不存在。

### 构建后校验（9 项）

前几次"看起来成功"都是因为没查最终产物 —— 构建返回 0 但镜像里缺东西。现在
`scripts/build.sh` 结尾强制检查并写进日志：

```
=== post-build verification ===
  OK/FAILED  43456 firmware apk built
  OK/FAILED  43456 firmware in image manifest
  OK/FAILED  brcmfmac driver in image manifest
  OK/FAILED  absent from manifest: brcmfmac-firmware-4329-sdio
  OK/FAILED  absent from manifest: kmod-r8169
  OK/FAILED  absent from manifest: cypress-firmware-4356-sdio
  OK/FAILED  absent from manifest: brcmfmac-nvram-4356-sdio
  OK/FAILED  dtb is the current 63779-byte build
  OK/FAILED  kernel patch applied without rejects
```

**教训**：输出不说谎，但得知道该看什么，而且要**强制**自己去看。

### 新建 OpenWrt 包时两个必踩的坑

**`Build/Compile` 必须显式定义。** 默认实现会 `cd` 进 `$(PKG_BUILD_DIR)`，而无源包没有这个
目录，构建失败且没有任何有用信息。

**`include $(INCLUDE_DIR)/package.mk` 绝对不能漏。** 漏了的话包**从未被注册**：
不生成 Kconfig 符号，于是 `DEVICE_PACKAGES` 写进去的 `CONFIG_DEFAULT_<pkg>=y` 找不到
对应符号、永远不被提升成能构建的 `CONFIG_PACKAGE_<pkg>=y`；同时 `package.mk` 定义的
`compile:` 目标不存在，报 `No rule to make target 'compile'`。

**这个 bug 的表征极具误导性** —— 它表现为"包没被选中"，而真正的问题是"包没被注册"。
我为此绕了大量弯路，甚至得出一个**错误结论**："这棵树对非 kmod 包不会自动提升"，还用一个
同样在坏状态下跑的对照实验去"证实"它。那个结论完全是 bug 导致的假象。

更早我还用过三个**没先验证对照组**的"证据"：`.packageinfo` 里没有我们的包（它根本不列
这类包，`kmod-brcmfmac` 也是 0）、拿未选中的 `cypress-firmware` 当"能工作的对照组"、
在 `.config-package.in` 里找 Kconfig 符号（不在那儿）。

### BCM43456 固件包

`package/firmware/broadcom-nonfree/` —— 见 `docs/WIFI-INVESTIGATION.md` §5 的许可分析。
要点：

- 固件 blob 是 **non-free**，linux-firmware 和所有 OpenWrt 包都不含
- **vendored 而非下载**，来源是 `RPi-Distro/firmware-nonfree` 分支 `trixie`
  （commit `3bab0f823f5b53150b76aab77093adef6655b920`）的
  `debian/added-firmware/brcm/`。选它是因为它是非自由 blob 的 Debian 源包，
  **许可随文件一起走**
- 换掉之前的 `armbian/firmware` 是必须的：那仓库 README 明写"再分发限于
  non-commercial / usage-only"，等于来源禁止我们做的事
- **适用的是 Synaptics 协议，不是 Broadcom SLA。** RPi 的 `debian/copyright` 对
  这批文件有单独条目：
  ```
  Files: debian/added-firmware/*/*43456*
  Copyright: Synaptics
  License: Synaptics
  ```
  Broadcom SLA 管的是 linux-firmware 里 `brcm/brcmfmac*.bin` **一般情况**，
  43456 的 blob 不在其内 —— 所以早先版本附错了许可文本
- Synaptics 协议（DRIVER END USER LICENSE AGREEMENT, BINARY DISTRIBUTION）
  授权条款是"以目标码形式复制和分发，**仅用于 Synaptics 芯片**"，三个条件都满足：
  逐字节安装（`Build/Verify` 编译期断言 sha256）、不改不派生、唯一消费者就是
  驱动本板 BCM43456 的 `brcmfmac`
- 协议还有一条容易被忽略的义务，对再分发镜像的人适用：
  > the Software may be subject to export control laws
- 全文装到 `/usr/share/licenses/broadcom/LICENSE.Synaptics`
  （7218 字节，`bb50f974…`，由 `scripts/extract-synaptics-license.py` 从同一 commit
  的 `debian/copyright` 提取）
- blob 本身在 `.gitignore` 里（构建只需它在磁盘上，git 历史实际上是永久的）
- 不想分发就从 `DEVICE_PACKAGES` 删掉该包，`kmod-brcmfmac` 会用手工拷进去的文件

### 包集合修正记录

我曾把 `friendlyarm_nanopc-t4` 的包列表抄过来（连 `kmod-brcmfmac` 都漏了）：

```makefile
DEVICE_PACKAGES := kmod-r8169 brcmfmac-nvram-4356-sdio cypress-firmware-4356-sdio
```

| 包 | 问题 |
|---|---|
| `kmod-r8169` | 本板网口是 **RTL8211F PHY 挂在 stmmac MAC 上**（硬件实测确认），没有 Realtek MAC |
| `cypress-firmware-4356-sdio` | CYW4356 的固件，芯片不对 |
| `brcmfmac-nvram-4356-sdio` | 同上 |
| `brcmfmac-firmware-4329-sdio` | BCM4329 固件（RPi 3B 时代），手工 `.config` 遗留，无设备定义引用 |

**`brcmfmac-firmware-usb` 去不掉，不是疏漏**：`package/kernel/mac80211/broadcom.mk`
声明 `+BRCMFMAC_USB:kmod-usb-core +BRCMFMAC_USB:brcmfmac-firmware-usb`，而 mac80211
backports 配置里 `CPTCFG_BRCMFMAC_USB=y`，所以**任何**用 `kmod-brcmfmac` 的设备都会带上
它。强去掉只能改 backports 的 Kconfig，为 500KB 不相关固件不值得，也不适合上游。

---

## 上机验证（四次）

| 次 | 镜像 | 结果 |
|---|---|---|
| 1 | — | U-Boot/内核跑通，rootfs 读不了（手写 DTS，PMIC 未探测） |
| 2 | `6386de59` | SD 卡 I/O 错误 + 供电链修复 → 系统完整启动（WiFi/BT 仍死） |
| 3 | `06b61b20` | 补 4 个板级 override → WiFi/BT 硬件层打通 |
| 4 | `9932b3da` | 删 gpio-keys + 包集合修正 → 全部符合预期 |
| 5 | `50092eba` | 加 43456 固件包 → 固件上传成功，芯片不启动 |

第四次的关键验证点：

```
 gpio-138 (|Recovery)                    ← 消失了，证明 gpio-keys 节点已删
 gpio-10  (|reset     ) out hi           ← WiFi 芯片出复位
[    0.326067] dwmmc_rockchip fe310000.mmc: allocated mmc-pwrseq
[    0.813709] mmc2: new ultra high speed SDR104 SDIO card at address 0001
[    0.252633] ff180000.serial: ttyS0 at MMIO 0xff180000      ← BT 的 uart0
  Data Size:  63779 Bytes                ← dtb 与构建产物一致
```

`/sys/kernel/debug/gpio` 里列出的 GPIO 从 11 个降到 10 个，正好是删掉的那个。

---

## WiFi

完整记录见 **[`docs/WIFI-INVESTIGATION.md`](docs/WIFI-INVESTIGATION.md)**，含证据、测试
矩阵、方法论陷阱和固件来源分析。

一句话现状：**硬件层完全打通，固件上传成功，但芯片不肯运行固件**。

`HT Avail timeout` 意味着 `SBSDIO_FUNC1_CHIPCLKCSR` 的就绪位一直不置位，而这个位只有
**运行中的固件**能置。同一故障在 Orange Pi 5 Pro 和 PineBook Pro（都是 AP6256）上有
报告；Radxa 自己的 DTS 和驱动映射与我们完全一致。

### 测试时踩的方法论陷阱

1. **`dmesg -C` 在这个构建上不生效** —— 缓存没清，于是 reload 式测试会输出**陈旧但格式
   正确**的内容，看起来像有效结果。比没有输出更糟。
2. **attach 失败后 `rmmod` + `modprobe` 根本不触发新 probe** —— 芯片半死，dmesg 一行
   新日志都没有。
3. **`reboot` 不重置 WiFi 外设** —— 只重置 SoC。PineBook Pro 用户的原话：*"It remains
   inaccessible with a reboot ... Only a complete shutdown followed by a new boot gives
   me a 80% chance."* 只有 `poweroff` + 拔电 + 等待 + 上电 是真复位。
4. **热状态结果不能和冷状态比较** —— 组合 2 的 `phy0` 是热状态，组合 3 的
   `HT Avail timeout` 是冷状态，两者不可比。

`scripts/wifi-test.sh` 把这四条都编码进去了：不清 dmesg、staging 和 check 跨一次真实
断电、显式给出结论而不是让人读日志。

### 固件来源与版本

| 来源 | 大小 | sha256 | 内部版本 |
|---|---|---|---|
| Armbian `brcm/brcmfmac43456-sdio.bin` | 482927 | `3167956a…` | 7.45.96.0 |
| **RPi `brcmfmac43456-sdio.bin`（本包采用）** | 495898 | `ddf83f21…` | 7.84.17.1 |
| `brcmfmac43455-sdio.bin` | 483181 | `5ecb7355…` | 7.45.69.0 |

三者都自报 build tag `43455c5-roml/43455_sdio` —— **这个 tag 不能用来区分**，Broadcom 的
构建系统对 43456 也用它。**内部版本号才是判据。**

测试期间用的 openSUSE 个人镜像事后核对过，`.bin` / `.txt` / `.clm_blob` 三个文件
sha256 与 RPi 官方仓库**逐字节相同** —— 是 sha256 证明了那个镜像可信，不是它的域名。

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

---

## recovery / Maskrom 按键

板上按键是 **Maskrom 按键**，功能由 **boot ROM 在上电瞬间**采样决定 —— Linux 侧不存在
对应事件。Radxa 官方文档 `low-level-dev/maskrom` 的步骤：

```
① 若主板有 SPI Flash，需将 SPI Flash 对应引脚接 GND
② 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
③ 主板未供电前按住 Maskrom 按键
④ 使用电源适配器给主板供电
⑤ 主板供电后松开 Maskrom 按键
若主板电源绿灯常亮，说明成功进入 Maskrom 模式。
```

第 ① 步对这块板**必需** —— 本板贴了 SPI Flash，不短接的话 SPI 的 U-Boot 会先接管。
好消息是只有进 maskrom 才需要短接，正常 SPI 引导和 `dd` 路线完全不受影响。

实测硬件事实：**按住按键没有任何 GPIO 电平变化**。这与"按键由 boot ROM 在上电瞬间采样"
一致 —— 如果它同时被 Linux 当输入用，按下就该在 debugfs 里看到变化。Radxa 和主线的
board 文件都**没有** gpio-keys 节点。

旧 wiki 记的是"三个按键 maskrom / reset / recovery，同时按住 maskrom + reset 进
maskrom"。Radxa **当前**文档对 4A+/4B+ 只提一个 Maskrom 按键，操作是"按住 + 上电"。
**以官方文档为准。**

---

## eMMC 安装：布局已核对

sysupgrade 镜像是 **DOS/MBR**，磁盘标识 `0x5452574f`：

| 分区 | 扇区 | 大小 | 内容 |
|---|---|---|---|
| p1 | 65536–98303（可启动） | 16 MiB | kernel FIT |
| p2 | 131072–1179647 | 512 MiB | rootfs |

U-Boot FIT 头 `d00dfeed` 在 **8 MiB** 偏移。镜像里**不含** TPL/SPL/idbloader ——
SPI 上已有 U-Boot，够了。

U-Boot 的 `BOOT_TARGETS` 是 `"mmc1 mmc0 nvme scsi usb pxe dhcp spi"`，`mmc0` =
`fe330000` = eMMC，排在 USB 之前。**写完直接插电就能起，不用改 U-Boot 环境变量。**

⚠️ 从 U 盘启动时**不要用 `sysupgrade`** —— root 在 `/dev/sda2`，它会把 U 盘当升级目标。
走手工 `dd`。⚠️ 不要写 `mmcblk0boot0` / `boot1` / `rpmb`。

⚠️ **eMMC 上已经有东西了**：日志里只有裸分区 `mmcblk0: p1`（没有大小也没有名字），
U-Boot 跳过它直接走了 USB。`dd` 会覆盖 MBR 和 p1/p2，**不可逆**。先只读地看清：

```sh
fdisk -l /dev/mmcblk0
blkid /dev/mmcblk0p1
mkdir -p /mnt/emmc && mount -o ro /dev/mmcblk0p1 /mnt/emmc && ls -la /mnt/emmc
```

---

## 介质问题

**那块 SD 卡坏了，不要再用。** 第一次烧 SD 卡时出现 `I/O error ... sector 135842` 加
`SQUASHFS error -5`，rootfs 读不了；换 U 盘烧**同一镜像**一次启动成功 —— 是那张卡的
问题，不是镜像的问题。上板前先用 `gzip -dc <image> | sha256sum` 回读校验区分"写入不完整"
与"卡损坏"。

---

## 两个无害的残留提示

```
Cannot parse config file '/etc/fw_env.config': No such file or directory
Failed to find NVMEM device
```

`uboot-envtools` 想写 SPI 环境变量但缺配置文件（早期版有 SPI Flash，U-Boot 报的 `bad
CRC` 就是它）。**不影响启动**。

---

## 构建产物

当前构建 `a1c0ac7353`，`REAL_EXIT_CODE=0`：

```
image-rk3399-rock-4b-plus.dtb              63779 字节
rock-4b-plus-rk3399-u-boot-rockchip.bin    9644032 字节
Image（解压后整盘镜像）                   603979776 字节 = 576 MiB
```

dtb 演进：`63273`（缺 4 个 override）→ `63956`（补上 WiFi/BT/音频）→ `63779`（删 gpio-keys）。

镜像 sha256：

```
8dbbd2e4c948931ff91ae23bcfa0746c72f9dfbc4d768dd75404d64f75d50fca  squashfs-sysupgrade.img.gz
e64004a0d5cb353a1046ab3d84e33aee7e344d696c3a42437137fd9ecf564e78  ext4-sysupgrade.img.gz
```

历史 sha256（变了就是不同镜像）：`6386de591b5f…`（WiFi 修复前）、`06b61b20dceb…`
（WiFi 硬件层打通）、`9932b3dad4d2…`（删 gpio-keys）、`50092eba850c…` / `07d22b762c20…`
（换 RPi 固件源与 Synaptics 许可前的最后一版）。

manifest 实测内容：

```
brcmfmac-firmware-43456-sdio - 7.84.17.1-r2    ← 本移植新增
brcmfmac-firmware-usb        - 20260221-r1       ← 上游条件依赖，去不掉
kmod-brcmfmac                - 6.12.94.6.18.26-r1
kmod-brcmutil                - 6.12.94.6.18.26-r1
```

确认已消失的错包：`brcmfmac-firmware-4329-sdio`、`kmod-r8169`、`cypress-firmware-4356-sdio`、
`brcmfmac-nvram-4356-sdio`。

**镜像层面实证**：解开 squashfs 逐字节核对过三个 blob 都在 `/lib/firmware/brcm/`、哈希与
Makefile 钉死的值一致、`LICENSE.Synaptics`（7218 字节，`bb50f974…`）在
`/usr/share/licenses/broadcom/`，且首行确实是 Synaptics 协议而非 Broadcom SLA。

DTB 反解语义核对：

```
model       = "Radxa ROCK 4B+"
compatible  = "radxa,rock-4b-plus", "radxa,rockpi4b-plus", "radxa,rockpi4", "rockchip,rk3399"
pmic@1b     rockchip,rk808          ✓
es8316      everest,es8316         ✓
gmac        tx_delay 0x28 / rx_delay 0x11
sdio0       status = "okay" + brcmf child ✓
uart0       status = "okay" + bluetooth child ✓
gpio-keys   不存在 ✓（按设计删除）
```

---

## 原风险项：全部已消解

这份清单写在第一次上机之前。事后逐条核对，**没有一项是真的风险** —— 因为它们全部源于
"自己手写外设描述"，而手写部分已被"继承上游"取代：

| 原风险项 | 实际情况 |
|---|---|
| U-Boot DRAM 拓扑无公开 DTS 可抄 | **不成立**。U-Boot 直接复用内核主线 DTS，无板级 C 驱动 |
| ES8316 需重新调 I2S/耳麦检测 | **不需要调**。继承上游后全是经硬件验证的值 |
| RTL8211F RGMII 延时需实测微调 | **不需要**。`tx_delay 0x28` / `rx_delay 0x11` 直接可用，1Gbps 实测通过 |
| AP6256 固件与 BT LPO 时钟需核对 | BT 的 LPO 时钟 `&rk808 1` 继承上游正确；固件问题见 WiFi 文档 |
| RK809 电压选择 GPIO | **芯片型号本身就猜错了** —— 是 RK808 |

**教训**：这份清单本身是个信号 —— 列得出这么多"高风险项"，说明方法有问题。正确的做法是
去继承经硬件验证的描述，而不是自己写然后逐项担心。

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
- [ ] Phase 5c：WiFi **固件运行** —— 芯片不肯启动，见 `docs/WIFI-INVESTIGATION.md`
- [x] Phase 5d：recovery/Maskrom 按键定性，猜的 gpio-keys 已删
- [ ] Phase 5e：HDMI 视频（需新建 `kmod-drm-rockchip`）
- [ ] Phase 5f：音频（需新建两个 kmod 包）
- [ ] Phase 6：eMMC 安装验证
- [ ] Phase 7：上游 PR（Linux 主线 DTS + OpenWrt 设备支持，DTS 已符合上游风格）

---

## 给下次的提醒

1. **Armbian 下这块板的 WiFi 到底能不能用？** 这是 WiFi 方向**唯一**能区分"软件"和
   "硬件"的信息，我问过三次都没得到答复。镜像文件还在的话，可以挂载读
   `/lib/firmware/brcm/` 和它的 DTB 做逐项比对。
2. **测试 WiFi 必须冷启动**：`poweroff` + 拔电 + 等 10 秒 + 上电。`reboot` 和 reset 键
   都不算。
3. **别信没验证过对照组的"证据"**。我在这次排查里用过 `.packageinfo`、未选中的
   `cypress-firmware`、`dmesg -C` 后的缓存内容，三个都不是有效信号。
4. **构建后看校验块**，不要只看 `REAL_EXIT_CODE`。
