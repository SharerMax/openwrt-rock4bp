# 适配说明

这个移植在 OpenWrt `v25.12.5` 之上加了什么、每一处为什么加、以及每一处的证据等级。

**先读这一段再读代码**：本移植的核心策略是**继承上游设备树**，而不是手写。早先版本手写过
约 900 行设备树，猜错了 PMIC 型号、稳压器拓扑、编解码器地址、RGMIM 延时和耳机 GPIO ——
**每一个都错或不存在**，结果是一块能进内核但没有供电、没有网口、没有 USB 的板子。现在只保留
**58 行实际代码**（文件共 227 行，其余是注释，说明每一行为什么在那儿）。

---

## 1. 改动清单

按「相对上游改了什么」组织。每条都标注证据等级。

| # | 改动 | 位置 | 为什么 | 证据 |
|---|---|---|---|---|
| 1 | 新增 `radxa_rock-4b-plus` 设备定义 | `target/linux/rockchip/image/armv8.mk` | 上游只有 `rock-4c-plus`，没有 4B+ | 真机引导 ✅ |
| 2 | 新增板级设备树（薄增量） | `target/linux/rockchip/patches-6.12/0001-*.patch` | 上游没有 4B+ 的 dts | 真机引导 ✅ |
| 3 | `&sdhci_pwrseq` 时钟属性 `lpo` → `ext_clock` | 同上 | 驱动只认 `ext_clock`，写成 `lpo` 时 32.768 kHz 从未使能，WiFi 静默失效 | 真机 WiFi ✅ |
| 4 | `&spi1` 启用 + `flash@0` | 同上 | 没有它内核看不见存引导程序的 SPI 闪存 | `/dev/mtd0` 出现 ✅ |
| 5 | 新增 BCM43456 固件包 | `package/firmware/broadcom-nonfree/Makefile` | 板上芯片是 AP6256=BCM43456，不是 RPi 3B 时代的 BCM4329 | 真机 WiFi ✅ |
| 6 | 去掉 `brcmfmac-firmware-4329-sdio` | `scripts/build.sh` manifest | 同上，多余固件 | 镜像 manifest ✅ |
| 7 | U-Boot defconfig 变体 | `package/boot/uboot-rockchip/Makefile` + `0101-*.patch` | 需要 SPI 引导、SPL 哈希校验、binman | 真机引导 ✅ |
| 8 | U-Boot 板级 dtsi（含 LPDDR4 DRAM 参数） | `0102-*.patch` | 上游 32 个 rk3399 dtsi 里**没有** `rk3399-rock-4b-plus` | 见下 §3 |
| 9 | `&vdd_log { regulator-init-microvolt = <950000>; }` | `0102-*.patch` | **本次移植唯一的功能性修复**，见下 §2 | 24 次零 panic ✅ |
| 10 | `CONFIG_ROCKCHIP_SPI_IMAGE=y` + 暂存 SPI 引导镜像 | `package/boot/uboot-rockchip/Makefile` | 产物早就存在，但没人打包、没人断言、没人用 | ⚠️ 构建断言 ✅，**上板未验** |
| 11 | 24 项构建后校验 | `scripts/build.sh` | 本移植两次交付过 exit 0 但缺东西的镜像 | 见 `docs/build.md` |

---

## 2. 唯一的功能性修复：`vdd_log`

**症状**：本移植的引导程序能启动板子，但随机 panic —— 6 次里 3 次，
落在 `rk3x_i2c_irq`，指针只差一个比特。

**原因**：`rk3399-rock-pi-4.dtsi` 里的 `&vdd_log` 节点只有 `regulator-min/max-microvolt`
（800–1400 mV），**没有 `regulator-init-microvolt`**。于是：

```
DT 里没有 regulator-init-microvolt
  → U-Boot 打印 "Cannot find regulator pwm init_voltage"，set_voltage 不被调用
  → 只有 rk_pwm_set_enable() 写 ctrl |= 0x3，period/duty 保持复位值
  → 内核 pwm_regulator_init_boot_on() 开头就 `if (pstate.enabled) return 0;`，早退
  → 占空比从头到尾没有任何东西写过
  → SDIO 相位 = 269 → 单比特损坏 → panic
```

**这是测量，不是推断。** 串口上在 U-Boot 提示符直接读寄存器：

```
=> md 0xff420020 4
ff420020: 0000019e 000004b7 0000025b 00000013
            cntr   period    duty     ctrl
```

`duty/period` = 603/1207 = **49.96%**，正是 950 mV 对应的占空比。**U-Boot 自己写的。**
修复前那一侧 `period`/`duty` 保持复位值。

**修复**：加一行属性。`950000` 是从上游选的 —— 上游 32 个 `rk3399-*-u-boot.dtsi` 里有
**11 个**设了这个属性，**11 个全部是 950000**，无一例外（rock-pi-4、Radxa 自家的
rock-4c-plus、rockpro64 等）。而上游**根本没有** `rk3399-rock-4b-plus-u-boot.dtsi`，
这正是本移植要写这个文件的原因。

⚠️ **值本身不是变量**：800 / 950 / 1100 mV 各测 6 次全部干净，30 次启动里 SDIO 相位随电压
线性变化（残差 ≤ 0.1）。**要紧的是占空比被写进去了。**

⚠️ **还差物理那一环**：这条轨在 4B+ 上实际接到哪里、未编程时输出什么电压，**从未测过**。
设备树不描述板子真实连线，`supply_map` 里也没有消费者。**但修复不需要知道它。**

完整证据链、被撤回的三个假说、以及那次预测表本身的缺陷，见
[postmortem-dram-instability.md](postmortem-dram-instability.md)。

---

## 3. 设备树为什么是「薄增量」

板级 dts 继承两个上游文件，`实际代码 58 行`：

- `rk3399-op1.dtsi` —— OP1 (RK3399-T) 工作点，含 A72 到 2016 MHz
- `rk3399-rock-pi-4.dtsi` —— 整个 4A/4B 家族：RK808 PMIC、稳压器、gmac RGMIM 时序、
  ES8316 音频、LED、存储、USB、40-pin pinctrl

⚠️ **`#include "rk3399-rock-pi-4.dtsi"` 不等于 `#include "rk3399-rock-pi-4b-plus.dts"`。**
dtsi 只有 4A/4B 共享的管道；板级文件带着下面四个 override，而 `rk3399-base.dtsi` 把相应的
控制器出厂设为 `disabled`。丢掉它们正是第一次启动 WiFi 死掉的原因：sdio0 保持 disabled、
电源时序没跑、复位脚 `gpio0_B2` 停在低电平。

继承自上游、**不是自己调的**这些值：

| 项 | 值 |
|---|---|
| PMIC | **RK808** @ i2c0 `0x1b`，节点嵌在 `&i2c0` 内 |
| 以太网 PHY 供电 | `vcc3v3_lan`，RGMII `tx_delay 0x28` / `rx_delay 0x11` |
| ES8316 | @ i2c1 `0x11`，MCLK 取自 `SCLK_I2S_8CH_OUT`，挂在 i2s0 |
| 耳机检测 / codec 中断 | `gpio1_A0` / `gpio1_A1` |
| 状态 LED（蓝色） | `gpio3_PD5` |

⚠️ **`scripts/Makefile.lib` 对 `<board>-u-boot.dtsi` 只取第一个 `$(wildcard)` 匹配项**，
所以新建一个板级文件会**顶掉**通配的那个而不是叠加，任何东西都不会警告。因此
`rk3399-rock-4b-plus-u-boot.dtsi` 必须**自己重新 include `rk3399-u-boot.dtsi`** ——
`binman` 节点的有无就是这么被检查住的。

---

## 4. 不在范围内的，以及第三类状态

**主动划出范围**（需要新建 kmod 包，不阻塞使用）：

| 项 | 原因 |
|---|---|
| HDMI 视频 | 内核 `CONFIG_DRM` 全关 + OpenWrt 无 `kmod-drm-rockchip` |
| 音频 | 缺 `kmod-sound-soc-es8316` + `kmod-sound-soc-rockchip` |

**⚠️ 第三类：无法测试** —— 接口在硬件上存在，但没有介质可以插进去走一遍。
既不是「已验证」也不是「坏了」：

| 项 | 为什么测不了 |
|---|---|
| 板载 microSD 卡槽 | 槽里没卡。USB 读卡器走的是另一条路（`sda`），已验证 |
| M.2 NVMe | **没插盘**。每次启动的 `PCIe link training gen1 timeout!` 是空插槽的预期行为，和空 microSD 槽的 `-110` 同类 |

⚠️ **别把这两条记成「不可用」** —— 没有证据，有的只是没插介质。

---

## 5. 这个移植**没有**做的事

写清楚比事后被发现好：

- **上游未推送。** `docs/hardware.md` 记了所有可上游化的部分，但一条 PR 都没提，
  理由是门槛是**复现**而不是稳定性：`vdd_log` 那条轨在别人板子上是否同样未编程，
  没有办法验证，所以说不清那一行属性是否**必需** —— 而本移植已经证明**换成任何显式值都能过**。
- **`flash-spi.sh --write` 从没在硬件上跑过。** payload 就绪且断言通过，但 spinor loader
  版本未定（Radxa 发 `v1.15.114`，文档说 v1.72 以后的板要 `v1.20.126`，而这块板的版本
  没查明）。⚠️ **后果：SPI 上没有可引导镜像，唯一恢复路径是 Maskrom。**
- **板载 SD 卡槽和 NVMe 从未引导/挂载过。**
- **SPI 能不能被 Linux 正确读取，仍然是错的。** 读得动但读到的是错的内容，
  稳定且错误。完整证据见 `docs/boot-order.md`。

---

## 6. 本仓库的脚本

`scripts/` 里除构建外都是**检查**，不是工具。它们的存在理由是本移植反复栽在
「构建成功 ≠ 镜像正确」上：

| 脚本 | 作用 |
|---|---|
| `sync-overlay.sh` | 比对 `overlay/` 与树；补丁源与补丁 payload 逐一核对 |
| `check-patch-sources.sh` | 同上后半段，独立可跑 |
| `extract-patch-file.sh` + `-selftest.sh` | 从多文件补丁里取单个文件；17 例负控制 |
| `regen-dts-patch.sh` | 重新生成两个 DTS 补丁，带 `dtc` 校验 |
| `check-bootloader-on-media.sh` | **把引导程序从板子的 eMMC 读回来**与构建比对 |
| `build.sh` | manifest + 构建 + 24 项校验 |
| `deploy.sh` | 把整盘镜像写进 U 盘 / SD / eMMC |
| `flash-spi.sh` | Maskrom 写 SPI（⚠️ `--write` 未上机） |
| `check-reboot-matrix.sh` + `-selftest.sh` | 板上重启 N 次并逐次判定 |

全部脚本用 `sh`/`bash` 解析，不依赖本机任何绝对路径：树的位置由 `OPENWRT_DIR`、
当前目录或同级 `../openwrt` 解析（见 `scripts/port-env.sh`）。
