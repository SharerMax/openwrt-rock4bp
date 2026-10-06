# 设备树策略

本移植的核心决策，以及两个编译期/运行期踩过的坑。

**一句话：继承上游，不自行描述外设拓扑。**

---

## 为什么继承

第一版手写了约 900 行设备树，猜了 PMIC 类型、regulator 拓扑、codec 地址、RGMII 延时、
耳机检测 GPIO。**每一个猜测都是错的或不可用的** —— 板子能启动内核但没有可用电源轨、
没有以太网、没有 USB。

继承 `rk3399-op1.dtsi` + `rk3399-rock-pi-4.dtsi` 后，这些错误类别整体消失。

具体继承到的、经硬件验证的值见 [hardware.md](hardware.md#继承上游得到的经硬件验证的值)。

---

## ⚠️ 继承 dtsi ≠ 继承 board 文件

这是本次最贵的一个概念错误。

`rk3399-rock-pi-4.dtsi` 只放 4A/4B **共用**的外设管道；**板级 override 在
`rk3399-rock-pi-4b-plus.dts` 里**，而 `rk3399-base.dtsi` 把相关控制器设为
`status = "disabled"`。重写成 thin delta 时只抄了 model/compatible，**把 4 个 override
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

`/sys/kernel/debug/gpio` 里那行 `gpio-10 (|reset) out lo` 是**决定性证据**。没有它
大概率会继续在"固件型号不对"这类方向上瞎猜。

DTS 88 → 128 行（补 override）→ 130 行（删 gpio-keys）→ **当前 130 行 + `&spi1`**。

---

## 本移植必须自己写的两条

继承上游解决了外设拓扑，但有两个属性上游是错的或不存在的：

### 1. WiFi 供电时钟名：lpo → ext_clock

```dts
&sdio_pwrseq {
    clock-names = "ext_clock";   /* 上游 Radxa 写的是 "lpo" */
};
```

`mmc-pwrseq-simple` 驱动**只**查 `"ext_clock"`，且所有使用点都用 `!IS_ERR()` 守卫。
所以继承下来的 `"lpo"` 会让查找返回 `-ENODEV` → 被容忍 → `ERR_PTR` 留在原地 →
**32.768 kHz 时钟静默地从未使能**，没有任何报错。

那个时钟就是 rk808 index 1 → `clkout2`，RK808 PMIC 的 32.768 kHz 输出，由
`CLK32KOUT2_EN` 控制，**使能它发生在给卡上电之后、释放复位之前**。BCM43456 在没有
32 kHz 参考的情况下会接受 SDIO 固件上传，但 datapath 起不来。

关键一步是拿 Armbian 做对照：它在**同一块板**上用同一个 brcmfmac、**逐字节相同**的
固件/NVRAM/clm_blob 能正常工作，而 live device tree 在 WiFi 供电路径上只差这一个属性。
在此之前测的 6 组固件/NVRAM 组合全是在测错的变量。

完整记录见 [wifi.md](wifi.md)。

### 2. SPI Flash 节点（`&spi1` + `flash@0`）

本板贴了 4 MB SPI Flash，上游的板级 dts 没有这个节点，所以 SPI 在 OpenWrt 下完全不可见。

```dts
&spi1 {
    status = "okay";
    flash@0: flash@0 {
        compatible = "jedec,spi-nor";
        reg = <0>;
        spi-max-frequency = 10000000;   /* 与本移植 U-Boot 一致，上游 rock-pi-4b 用 108 MHz */
    };
};
```

⚠️ `spi-max-frequency` 用的是 **10 MHz**，和本移植 U-Boot 的配置对齐。

⚠️ 但**加了节点不等于能读对** —— 实测这块 SPI 在 Linux 下读回来的不是芯片内容，
`build.sh` 的 `dtb exposes the SPI flash` 校验项只检查节点存在，对那种情况完全无感。
详见 [boot-order.md](boot-order.md#linux-从这块-spi-读不到正确的内容)。

---

## 第一次上机失败的根因（单一连锁故障）

```
rk809 节点被放在根节点，且 &i2c0 从未使能（base.dtsi 默认 status="disabled"）
  → PMIC 不 probe → vcc3v3_sys 不存在
    → vcc_3v3 / vcc3v3_phy1 / vcc5v0_host 全部 deferred (-517)
      → gmac 拿不到 PHY regulator、usb2phy 建不起来、SDIO 无时钟、eMMC 无 PHY
        → rootfs 挂不上
```

注意芯片本身就猜错了 —— 是 **RK808**，不是 RK809。

---

## U-Boot 侧

> 这一节原先写着"首次上机 DRAM 初始化成功，说明这份 defconfig 可用"。**那句话是错的**：
> 当时起作用的 U-Boot 是 SPI 上原有的 Armbian 那份，不是本移植编出来的。

### 上游已有什么，缺什么

- mainline U-Boot 2025.10 **已有** `rock-4se-rk3399_defconfig`、
  `rock-4c-plus-rk3399_defconfig`
- **没有** `rock-4b-plus-rk3399_defconfig` → 需新增（基于 4SE，改 2 行 DT 引用）
- 4SE 的 defconfig 里已开：`CONFIG_PHY_REALTEK`、`CONFIG_RAM_ROCKCHIP_LPDDR4`、
  `CONFIG_PMIC_RK8XX`、`CONFIG_REGULATOR_RK8XX`、`CONFIG_MMC_SDHCI_{SDMA,ROCKCHIP}`、
  `CONFIG_NVME_PCI`、`CONFIG_SCSI_AHCI`、`CONFIG_VIDEO_ROCKCHIP_HDMI`、
  `CONFIG_DISPLAY_ROCKCHIP_HDMI`、`CONFIG_LED_GPIO` 及 SPI 相关项 —— 与本板需求高度吻合
- RK3399 走通用 `CONFIG_TARGET_ROCKPI4_RK3399` 板级代码，**不需要板级 C 驱动**
- `dts/upstream/src/arm64/Makefile` 用通配符扫描 `*/*.dts`，把 `.dts` 放进
  `dts/upstream/src/arm64/rockchip/` 就够了，**不需要改任何 Makefile**

### 其余仍然成立的部分

- **`UBOOT_TARGETS` 是硬编码白名单**：只加 `define U-Boot/...` 不够，必须在
  `package/boot/uboot-rockchip/Makefile` 的 `UBOOT_TARGETS` 里登记。这曾经是一个真正的
  阻塞点。
- U-Boot 默认 `BOOT_TARGETS "mmc1 mmc0 nvme scsi usb pxe dhcp spi"` —— **含 USB**。
  ⚠️ 区分两条路径：现在跑的 microSD 是**插在 USB 读卡器里**，内核见到 `sda`，走
  `boot.scr`；**板载 SD 卡槽（`mmc1`）至今未验证**。

### ⚠️ 缺一个板级 U-Boot dtsi

`arch/arm/dts/<board>-u-boot.dtsi` 是**必需的**，而这个文件**不存在也不会报错**。

`scripts/Makefile.lib` 按板名去找它，命中就用，找不到就往下退：

```make
u_boot_dtsi_options = $(strip $(wildcard <board>-u-boot.dtsi) \
                       $(wildcard $(CONFIG_SYS_SOC)-u-boot.dtsi) ...)
# We use the first match to be included
dtsi_include_list  = $(notdir $(firstword $(u_boot_dtsi_options)))
```

**这是优先级链、只取第一个命中，不是并集。** 本板原先没有板级文件，于是退到通用的
`rk3399-u-boot.dtsi` —— 它有 `binman` 节点和 `bootph-*` 标记，**就是没有
`rockchip,sdram-params`**。U-Boot 的每个 RK3399 板子都有这个文件（rock-pi-4a、
rock-pi-4c、rock-4c-plus、rock-4se、nanopc-t4），所以它们都能起。

缺了它的后果是**构建期完全静默**：`idbloader.img` 正常产出、大小正常，原有的 9 项校验
一条都不报警，直到那份引导程序被刷进 SPI 才暴露 —— 那时板子已经砖了。

**修法是两个 include**（`overlay/u-boot/rk3399-rock-4b-plus-u-boot.dtsi`）：

```
rk3399-u-boot.dtsi              binman 节点、bootph-* 标记
rk3399-sdram-lpddr4-100.dtsi    只有 &dmc { rockchip,sdram-params = <...> }
```

⚠️ **第一个 include 必须显式写出来。** 一旦有了板级文件，它就成了第一个命中，通用那份
被**顶掉**而不是叠加。少了这一句，构建会改挂在：

```
binman: Device tree './u-boot.dtb' does not have a 'binman' node
```

补这个文件时踩了两个坑：第一个是运行时变砖，第二个是构建期失败 —— 后者反而更容易发现。

**参数选 `lpddr4-100` 的依据**：本板是 **64 位双通道 LPDDR4 @3200Mb/s**（Radxa 官方
spec），而 mainline U-Boot 给每一块同规格 RK3399 用的都是这个文件。
没有走 `rk3399-rock-pi-4-u-boot.dtsi`，因为它还会顺带加上 `&sdhci` 时序覆盖和
`leds` 节点 —— eMMC 本来就能跑到 HS400，缺的只有 DRAM 参数。

---

## 编译期踩过的 dtc 坑

全部在编译期就暴露，没有一个带到板子上。定位方法：拿 `build_dir` 里已有的 dtc，以上游
`rk3399-rock-pi-4c-plus.dts` 做对照组，用
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

⚠️ **验证 DTS 时源文件必须放在 `dts/rockchip/` 目录下**，否则
`#include "rk3399-op1.dtsi"` 的相对路径解析不到，会误报语法错误。浪费过一轮。

---

## 相关文档

- [hardware.md](hardware.md) — 硬件事实与继承到的值
- [build.md](build.md) — 构建流程、manifest、17 项校验
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 缺 sdram-params 导致的变砖
- [wifi.md](wifi.md) — WiFi 的完整排查记录