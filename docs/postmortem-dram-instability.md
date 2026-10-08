# 本移植 U-Boot：能启动，但会随机 panic

**排查记录。** 2026-10-08，本文记录把"引导程序未验证"变成"验证出问题了"的全过程，
包含**两次失败的归因**。

**结论先说**：本移植的 U-Boot **能在真机上启动系统**，`rockchip,sdram-params` 修复
确认生效；但会随机内核 panic，而同样的系统用 Armbian 的 TPL 引导 **7 次零 panic**。

**当前状态：根因未定位。DRAM 初始化已被实验排除。** 别把本文任何一节当成结论 ——
包括这一节。

三次自我推翻，按顺序：

| # | 我一度说 | 实际 |
|---|---|---|
| 1 | 根因是 DRAM 初始化 | ❌ 参数、CONFIG、板级 dtsi 与 Armbian **逐字节相同**，驱动只差 3% |
| 2 | 50MHz vs 400MHz 是打印顺序的假象 | ❌ **撤回错了**。打印时刻控制器确实已在 400MHz，配置写入的真实频率就是不同 |
| 3 | 升频与训练的时序就是原因 | ❌ 做成补丁上机测了，**2/2 照崩，故障一字未变** |

**所以「DRAM 初始化」这条线到此为止。** 剩下的差异在引导程序别处。

## 🧪 当前进展：`&vdd_log` 实验，1 次成功（判据 6 次）

本移植的板级 dtsi 原先省略了 `&vdd_log { regulator-init-microvolt = <950000> }` ——
不是深思熟虑，是「不 include rock-pi-4 的 dtsi」那句推理覆盖了整个文件。
补上之后 **tty14 一次完整启动到 root shell，零 panic**。

**但真正有意思的不是这次成功，是相位值变了。** 本移植此前 6 次启动里有 3 次记到了
SDIO 相位，**全部是 269**（另外 3 次在探测 SDIO 之前就崩了，没留下数值）；
带 `vdd_log` 之后落在 **221–225** —— 和 Armbian 那 6 次的 220–223 同一区间。

⚠️ **这个值每次启动都不同**（实测 221 / 224 / 225 / 223），所以它是**电压轨的指示器**，
**不是某个构建的指纹**。能区分的是「269 还是 220 多」这两族，区分不了同一族里的个体。

⚠️ **1 次成功不是 6 次。**「设了就好了」和「碰巧这次好了」现在分不开。
完整数据、机制、反驳见文末「下一步」。

**只想知道现状**：见 [README.md](../README.md) 顶部的状态节。
**要理解当初那个缺陷怎么修的**：见 [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md)。
**要动手修**：见文末「下一步」。

---

## 三次自我推翻的详细位置

| 内容 | 位置 |
|---|---|
| 逐层比对排除参数/CONFIG/dtsi/驱动 | 「❌ 三个假设被逐一排除」 |
| 撤回错了那一次的更正 | 「我撤回了一次撤回」 |
| 补丁上机后证伪 | 「排除四：跑实验排除」 |

---

## 怎么做的

用 Maskrom 把整包镜像写进 eMMC：

```bash
sudo rkdeveloptool db rk3399_loader_v1.27.126.bin
sudo rkdeveloptool wl 0 os.img
```

这一条路之前记的是"只剩 Maskrom 写 SPI"，但**写 eMMC 同样可行，而且不碰 SPI** ——
SPI 上那份能用的 Armbian 引导程序完整保留了下来，正好成了对照组的来源。

⚠️ 注意 `wl 0` 写的是整包，LBA 0x40 的 rkimage 容器和 LBA 0x4000 的 `u-boot.itb`
都是镜像自带的，**所以引导 SPI 是本移植的，而不是 SPI 上那份**。

---

## 14 次启动的完整对照

这一节是从 `log/tty*.txt` 里逐条提取的，不是凭印象写的。
⚠️ tty8 一次抓取里有**两次**启动（第一次成功、第二次 panic）—— 把它们算成一次，
就会得出"从没有成功过"的错误结论。

所有时间戳和相位值都是从 `log/tty*.txt` 按 TPL banner 切分后逐条提取的，
切分脚本见 [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) 的陷阱 1 ——
**tty8 和 tty13 各含两次启动，panic 行数不等于启动次数。**

| 日志 | 引导程序 | 引导源 | SDIO 相位 | 结果 | 时刻 |
|---|---|---|---|---|---|
| tty2 #1 | Armbian | U 盘 | — | ✅ 挂上 root（squashfs） | 1.370 |
| tty3 #1 | Armbian | U 盘 | — | ✅ 挂上 root（squashfs） | 2.558 |
| tty4 #1 | Armbian | U 盘 | 220 | ✅ 挂上 root，到 shell | 2.610 |
| tty5 #1 | Armbian | U 盘 | 221 | ✅ 挂上 root，到 shell | 2.604 |
| tty6 #1 | Armbian | U 盘 | 223 | ✅ 挂上 root | 2.684 |
| tty7 #1 | **本移植** base | eMMC | — | ⚠️ 日志早断 | — |
| tty8 #1 | **本移植** base | eMMC | 269 | ✅ 挂上 root | 1.381 |
| tty8 #2 | **本移植** base | eMMC | — | ❌ **panic**（IABT） | 0.643 |
| tty9 #1 | **本移植** base | eMMC | 269 | ⚠️ 日志早断 | — |
| tty10 #1 | **本移植** base | eMMC | 269 | ❌ **panic** | 1.388 |
| tty11 #1 | Armbian | U 盘 | 222 | ✅ 挂上 root，到 shell | 2.731 |
| tty12 #1 | **本移植** base | eMMC | — | ❌ **panic**（PC 垃圾指针） | 0.540 |
| tty13 #1 | **本移植** +0103 | eMMC | 269 | ❌ **panic**（cpuidle 形态） | 1.366 |
| tty13 #2 | **本移植** +0103 | eMMC | — | ❌ **panic**（PC 垃圾指针） | 0.457 |
| **tty14 #1** | **本移植** +0103 +vdd_log | eMMC | **221** | ✅ **挂上 root，到 shell** | 1.355 |

⚠️ **`base` / `+0103` / `+vdd_log` 是三个不同的引导程序构建，不能当成同一个东西数。**
0103 改了 DRAM 序列，vdd_log 改了电压。

### 按构建分组

| | 本移植 base | 本移植 +0103 | 本移植 +0103 +vdd_log | Armbian |
|---|---|---|---|---|
| 启动次数 | 6 | 2 | **1** | 6 |
| 挂上 root | **1** | 0 | **1** | **6** |
| 到达 shell | 0 | 0 | **1** | 3 |
| **内核 panic** | **3** | **2** | **0** | **0** |
| 日志早断 | 2 | 0 | 0 | 0 |
| 记到 SDIO 相位 | 3/6 次，全是 269 | 1/2 次，269 | **每次 221–225** | 4/6 次，220–223 |

⚠️ **最后一列（`+vdd_log`）只有 1 次启动，它的 0 次 panic 不能和别的列比。**
6 次零 panic 和 1 次零 panic 之间没有任何可比性 —— 那正是本文开头那条教训。
把这一列并进 Armbian 那一列是错的。

### ⚠️ 别把「没调谐」读成「没崩」

相位那一列的 `—` 有两种完全不同的含义，日志本身区分不了：

| | 含义 |
|---|---|
| tty2 / tty3 | Armbian **没插 SD 卡**，没有 SDIO 可调谐，正常 |
| tty8#2 / tty12 / tty13#2 | 本移植**在调谐之前就 panic 了** |

⚠️ **而且调谐在前、panic 在后的也有两次** —— tty10（相位 269，panic @1.388）和
tty13#1（相位 269，panic @1.366）。所以「崩在 0.5 秒左右」这个印象是错的：
**崩溃时刻分布在 0.46～1.39 秒**，取决于崩的是哪条路径，不是固定时间。

⚠️ **"日志早断"不等于"卡住"。** tty7 和 tty9 的串口输出在 1.2～1.4 秒处停止，既没有
`VFS: Mounted root` 也没有 panic 行。板子当时 ping 不通、ARP 是 `INCOMPLETE`，但
**从截断的日志无法判断是卡在 `rootwait` 还是真的死了**。

⚠️ 这个区分在本次排查里栽过两次：早先从 tty7 的截断日志断言"板子死了"，实际那次
和 tty8 的第二次启动是同一种 panic。**"日志停了"和"系统停了"是两件事。**

---

## 对照实验：⚠️ **有两个**变量，不是一个

⚠️ **本文早期版本把这个实验写成"唯一变量是 TPL"。那是错的**，而且错在一个很容易
自我说服的地方 —— 因为它让结论更漂亮。

```
tty11  Armbian TPL 2022.07_armbian  → 引导 U 盘   → VFS: Mounted root (ext4) on device 8:2  → 进 shell
tty12  本移植 TPL 2025.10-OpenWrt   → 引导 eMMC  → 0.54 秒 panic
```

**引导程序换了，引导介质也换了。** 15 次启动的实际分布是：

| | 从 U 盘引导 | 从 eMMC 引导 |
|---|---|---|
| Armbian U-Boot | 6 次，0 panic | 0 次 |
| 本移植 U-Boot | 0 次 | 6 次，3 panic |

**两个维度和引导程序完全共变** —— 所以那次对照不能区分"是 TPL 的问题"还是
"是从 eMMC 引导的问题"。⚠️ "内核、设备树、rootfs 都排除了"这句成立（下面有证据），
但"剩下的差异就在 TPL 上"这句**没有证据支撑**。

两边的相同部分（这部分确实是硬的）：

| 项 | 值 | 两边是否一致 |
|---|---|---|
| 内核 | `Linux 6.12.94` | ✅ |
| dtb | `radxa_rock-4b-plus device tree blob`，**63877 字节** | ✅ |
| dtb 哈希 | crc32 `919fa3f9` + sha1 `b44f4d59…` | ✅ **逐字节相同** |
| kernel 哈希 | crc32 `55f4bcaa` + sha1 `05a99f8f…` | ✅ **逐字节相同** |
| rootfs | `PARTUUID=5452574f-02` | ✅ 同一个镜像 |
| DRAM | 4 GiB (total 3.9 GiB) | ✅ |

### 后来补上的一个格子

2026-10-08：eMMC 上重装了 Armbian，**从 SPI 里的 Armbian U-Boot 引导 eMMC 成功**，
连测 **6 次全部通过**：

```
6/6   boot_id 每次都变（新内核实例，不是假重启）
      root=UUID=7043da66-… ubootpart=d2a80aa7-01     ← 确认来自 eMMC
      MemTotal: 3945008 kB                            ← 每次一致
      dmesg bad (oops/panic/Internal error/BUG): 0      ← 每次都是 0
```

所以 **Armbian TPL + eMMC 引导 = 7 次零 panic**（含之前那次）。

⚠️ **这个证据比串口日志弱。** 没有 TTL 适配器接 UART2，看不到 TPL 自己的输出，
所以"6 次通过"的准确含义是"**内核每次都起来了**"，不是"TPL 每次都正确"。
对本问题够用 —— 我们关心的失败形态是 panic，而那必然表现为内核起不来。

### 还没填的格子

| | 从 U 盘引导 | 从 eMMC 引导 |
|---|---|---|
| Armbian U-Boot | ✅ 6 次，0 panic | ✅ **7 次，0 panic**（10-08 补齐） |
| 本移植 base | ❌ 从未测过 | ❌ 6 次，3 panic |
| 本移植 +0103 | ❌ 从未测过 | ❌ 2 次，2 panic |
| 本移植 +0103 +vdd_log | ❌ 从未测过 | 🧪 **1 次，0 panic**（未达判据） |

**左下角那一整列都走不通**，不是没做：要让本移植的引导程序去引导 U 盘，
而 boot ROM 不会跳过 SPI —— 板载 SD 卡槽 `mmc1` 是 boot ROM 的第三条链路，
所以只能靠插 U 盘让 SPI 和 SD 都不含可引导镜像，那会破坏现有的恢复路径。

⚠️ **两个媒体列现在都是 eMMC，所以变量确实只剩引导程序了** —— 这一点在 base 版
成立。⚠️ 但**行**之间不可比：base / +0103 / +vdd_log 是三个不同的引导程序构建
（改了 DRAM 序列、改了电压），把它们合并成"本移植 9 次 5 panic"会丢掉全部信息。
每行只能跟同行的其他列比。

---

## 症状：函数指针被指向垃圾地址

三次 panic 的形态一致 —— **PC 落到不是代码的地方**。

### tty12（证据最完整）

```
[    0.540119] Unable to handle kernel paging request at virtual address dfff800080099ee4
[    0.541440]   EC = 0x21: IABT (current EL), IL = 32 bits
[    0.542474]   FSC = 0x04: level 0 translation fault
[    0.542910] [dfff800080099ee4] address between user and kernel address ranges
[    0.545938] pc : 0xdfff800080099ee4
[    0.546259] lr : __wake_up_common+0x8c/0xe0
[    0.553416] Call trace:
[    0.553640]  0xdfff800080099ee4
[    0.553927]  __wake_up+0x6c/0x9c
[    0.554230]  rk3x_i2c_irq+0x198/0x3a0
```

**调用链本身完全正常**：`rk3x_i2c_irq` 是 I2C 中断处理，`__wake_up` 是唤醒等待队列，
都在做该做的事。崩在 `__wake_up_common` 调用的那一步 —— 而它要调用的目标
（`x4 = 0xdfff800080099ee4`）是一个**内核从未映射过的地址**，内核自己都说了
*"address between user and kernel address ranges"*。

**被调用的函数指针是坏的。**

### tty10

```
[    1.387803] Internal error: Oops - Undefined instruction: 0000000002000000 [#1] SMP
[    1.402407] Code: b9407e60 cb150035 11000400 b9007e60 (d5033ab7)
```

`pc : tick_nohz_stop_idle+0x38/0xb0` 有符号，看起来正常 —— 但 `Code:` 里那一条
`cb150035` 中，**`cb` 在 ARM64 里不是任何合法指令编码**。

PC 有符号是因为它落在 `.text` 里，但那个位置的**内容已经不是代码了**。

### tty8

```
[    0.642658] Unable to handle kernel paging request at virtual address ffff8000819ebb40
[    0.643980]   EC = 0x20: IABT (lower EL), IL = 32 bits
[    0.647976] CPU: 4 UID: 0 PID: 74 Comm: kworker/4:5 Not tainted 6.12.94 #0
[    0.649004] Workqueue: events_freezable mmc_rescan
[    0.650086] pc : ffff8000819ebb40
[    0.650390] x16: 00000032b5503510
```

PC 又是一个不像代码的地址。`x16 = 0x3250 3510` 里面的字节看着像 ASCII
（`"2"`、`"µ"`、`"0x10"`）—— **寄存器里出现了字符串**，典型的内存被写坏。

### 三次对照

| 日志 | 异常 | 位置 | 上下文 |
|---|---|---|---|
| tty8 | `IABT (lower EL)` 取指失败 | `ffff8000819ebb40` | `mmc_rescan` 工作线程 |
| tty10 | `Undefined instruction` | `tick_nohz_stop_idle+0x38` | idle 路径，`swapper/0` |
| tty12 | `IABT (current EL)` + level 0 fault | `dfff800080099ee4` | I2C 中断 → `__wake_up` |

**三个完全不同的位置，三个完全不同的调用链，同一种失败方式。**

⚠️ 确定的软件 bug 每次都会在同一处崩。**故障点随机漂移**是硬件类故障的特征 ——
内存被写坏或读坏，指针被污染，然后在下一个用到坏指针的地方炸掉。

---

## ❌ 三个假设被逐一排除（2026-10-08）

⚠️ **本文早期版本写着"根因已定位到 DRAM 参数"。那是错的。** 拿到 v2022.07 源码
（经代理从 `raw.githubusercontent.com/u-boot/u-boot/v2022.07` 取到）逐层比对之后，
三个假设全部不成立。

### 排除一：DRAM 参数不一样 —— ❌ 逐字节相同

| | sha256 |
|---|---|
| v2022.07 `arch/arm/dts/rk3399-sdram-lpddr4-100.dtsi` | `2874c640f5d9007aacdc02effbd949955a410ba5585998f2c6b23d43108c02df` |
| v2025.10 同一个文件 | `2874c640f5d9007aacdc02effbd949955a410ba5585998f2c6b23d43108c02df` |

`cmp` 确认逐字节相同。**Armbian 2022.07 和我们 2025.10 喂给 TPL 的是同一份参数。**

### 排除二：DRAM 相关的 CONFIG 不一样 —— ❌ 相同

两边都是 `CONFIG_RAM_ROCKCHIP_LPDDR4=y`（2022.07 里叫 `CONFIG_RAM_RK3399_LPDDR4`，
同一个 Kconfig 选项改过名）、`CONFIG_NR_DRAM_BANKS=1`。defconfig 的其余差异是
SPI/PCI/USB/HDMI，与 DRAM 无关。

### 排除三：板级 U-Boot dtsi 不一样 —— ❌ 相同

Armbian 用 `BOOTCONFIG="rock-pi-4-rk3399_defconfig"`，它的板级 dtsi 是
`rk3399-rock-pi-4-u-boot.dtsi`（经 rock-4se 链继承），内容就是：

```c
#include "rk3399-u-boot.dtsi"
#include "rk3399-sdram-lpddr4-100.dtsi"
```

和我们的 `rk3399-rock-4b-plus-u-boot.dtsi` **完全一致**。我们没 include 的
`&sdhci` 时序覆盖和 `leds` 节点不影响 DRAM。

### ⚠️⚠️ 我撤回了一次撤回 —— 频率差异是真的，不是打印假象

**本文的第二个版本说过"50MHz vs 400MHz 只是打印顺序的假象，两边训练频率相同"。
那句话是错的，已撤回。**

当时的推理是：`sdram_print_ddr_info()` 打印 `params->base.ddr_freq`，而 v2025.10 把
它改成 400 的赋值在打印之前，v2022.07 压根不改 —— 所以同一个状态打印出不同数字。

**这个推理漏了一步：`sdram_print_ddr_info()` 在通道循环里，而循环之前那次
`lpddr4_set_rate(dram, params, 0)` 已经把控制器真的切到 400MHz 了。**

```
v2022.07:  训练 → [打印 "50MHz"，此时 DRAM 确实在低频] → 配置写入 → 升频
v2025.10:  训练 → 升频到 400MHz → [打印 "400MHz"，此时 DRAM 确实在 400MHz] → 配置写入
```

**打印值如实反映了当时的状态** —— 配置写入时的实际频率，两边确实不同。
原来的观察是对的，那次撤回是错的。

⚠️ **这个更正花了两轮，而它的起因是我没去核实一个数。** 现在核实了：

dtsi 里 `base.ddr_freq` 位于扁平 u32 数组的**下标 34**（`sdram_cap_info` 11 个 +
`sdram_msch_timings` 6 个，每通道 17 个，两通道 34）。三个独立锚点确认：

| 校验 | 值 |
|---|---|
| 结构体推算总长 `34 + 5 + 332 + 200 + 959` | **1530**，与 dtsi 的 u32 总数**完全吻合** |
| 下标 36 `num_channels` | 2，与 `.inc` 一致 |
| 下标 38 `odt` | 1，与 `.inc` 一致 |
| **下标 34 `ddr_freq`** | **80** |

⚠️ **而 80 这个值推翻了我更早的一个说法。** 我曾说"Armbian 的 50MHz 就是 dtsi 的值"，
但**整个 dtsi 数组里根本没有 50 这个数**，而 `sdram_print_ddr_info()` 两版实现完全相同
（都只 `printdec(base->ddr_freq)`），2022.07 也从不对该字段赋值。

**所以 Armbian 的参数与我们不同**，尽管 `rk3399-sdram-lpddr4-100.dtsi` 逐字节相同
—— 它的 banner 是 `2022.07_armbian-2022.07-Se092-…`，**Armbian 打过补丁**，
那些补丁不在我们手上。⚠️ 这条线到此为止：我们只能把顺序改回 mainline v2022.07 的样子，
**改不成 Armbian 的确切行为**。

### 排除四：跑实验排除 —— ❌ 不是 DRAM 初始化（2026-10-08）

上面那个唯一剩下的差异做成了补丁并上机测了。结果：**2 次启动，2 次 panic，没修好。**

补丁：`0103-ram-rockchip-rk3399-lpddr4-configure-before-training.patch`

串口输出确认补丁生效 —— `50MHz` 出现在 `lpddr4_set_rate` **之前**（补丁前是 400MHz 在前）：

```
Channel 0: LPDDR4, 50MHz          ← 补丁前这里打印 400MHz，且在 set_rate 之后
BW=32 Col=10 Bk=8 CS0 Row=16 CS=1 Die BW=16 Size=2048MB
256B stride
lpddr4_set_rate: change freq to 400MHz 0, 1
lpddr4_set_rate: change freq to 800MHz 1, 0
```

⚠️ **故障一点没变。** tty13 第二次启动与 tty12 **完全同源**：

| | tty12 | tty13 #2 |
|---|---|---|
| ESR | `0000000086000004` | `0000000086000004` |
| PC | `0xdfff800080099ee4` | `0xdfff800080099ee4` |
| lr | `__wake_up_common+0x8c/0xe0` | `__wake_up_common+0x8c/0xe0` |
| x4 | `dfff800080099ee4` | `dfff800080099ee4` |
| 调用者 | `rk3x_i2c_irq+0x198/0x3a0` | `rk3x_i2c_irq+0x198/0x3a0` |
| `Code:` | `????????` | `????????` |

**⇒ DRAM 初始化被排除。** 现在两边 DRAM 序列一致（50MHz → 配置 → 升频 400/800 →
训练），故障照旧。**差异在引导程序的别处。**

⚠️ **补丁保留而不是回退** —— 理由和当初写它时不同。留着它，两边 DRAM 序列就一致，
后续对比只剩一个变量；回退会把 400MHz 顺序那个差异重新放回来。
⚠️ 这是偏离上游的改动，**下一个实验若不需要它就删掉**。

### ⚠️ tty13 第一次启动：一个新形态

```
Unable to handle kernel read from unreadable memory at virtual address 0000000000000000
Unable to handle kernel write to read-only memory at virtual address 0000000000000060
  ESR = 0x0000000096000044      EC = 0x25: DABT (current EL)
  FSC = 0x04: level 0 translation fault
pc : el1h_64_irq+0x18/0x6c
lr : cpuidle_enter_state+0xa4/0x320
Call trace: el1h_64_irq ← cpuidle_enter ← do_idle ← cpu_startup_entry
            ← __cpu_disable ← __secondary_switched
Code: a90217e4 a9031fe6 a90427e8 a9052fea
Kernel panic - not syncing: Attempted to kill the idle task!
```

**读 0x0、写 0x60** —— 空指针加偏移，idle 上下文里、由次核下线路径触发。
寄存器里还有 `x17: 65663a6d726f6674`，小端读是 ASCII `"tform:fe"`，
以及 `x5: 00ffffffffffffff`。**寄存器里出现文本**，与 tty8 的 `x16` 同类。

⚠️ 时间点不同（1.37s / 0.46s）、调用路径不同，但**坏指针是同一个值**。

---

## 排除五：另外三条我怀疑过、然后自己查掉的机制

写下来是因为它们看起来都很合理，而且我都差点就当成结论了：

| 怀疑 | 为什么不成立 |
|---|---|
| IO 参数按错误的频率挑选（`lpddr4_get_io_settings()` 用 `base.ddr_freq` 选驱动强度，若在赋值之后调用就会按 400 选） | 全部 7 个调用点在第 361～2101 行，**都在第 2969 行赋值之前** |
| 运行期 DDR 时钟不同（`clk_set_rate(&priv->ddr_clk, params->base.ddr_freq * MHz)`） | 该行在 `rk3399_dmc_init()` 里，2025.10 用 `phase_sdram_init()` 门控，**U-Boot proper 根本不调用它**；`clk_set_rate` 也在 `sdram_init()` 之前执行，用的是 dtsi 值 |
| DRAM 驱动代码在 2022.07→2025.10 之间被大改 | 93 KB 的文件里只差 **+64/−48 行**（3%） |
| `cs0_high16bit_row` 被 v2025.10 新增的 `sdram_detect_high_row()` 同步，改变了内存映射（这就是 `Row=16/15` vs `Row=16`） | 该字段在 RK3399 路径里**只用于 `sdram_print_ddr_info()` 打印**，别处不读；`set_memory_map()` 用的是 `cap_info.ddrconfig` 推 row，不看它 |

---

## 找到的唯一实质差异：LPDDR4 升频的时机

v2025.10 在 `sdram_init()` 里新增：

```c
+#if defined(CONFIG_RAM_ROCKCHIP_LPDDR4)
+	/* LPDDR4 needs to be trained at 400MHz */
+	lpddr4_set_rate(dram, params, 0);
+	params->base.ddr_freq = dfs_cfgs_lpddr4[0].base.ddr_freq / MHz;
+#endif
```

同时 `lpddr4_set_rate()` 从"内部循环 ctl 0/1"改成"外部传入 `ctl_fn`"。于是：

| | v2022.07（Armbian） | v2025.10（本移植） |
|---|---|---|
| 1. rank 探测 + `data_training_first()` | @ dtsi 频率 | @ dtsi 频率（**相同**） |
| 2. 切 ctl0 到 400MHz + **训练** | — | ✅ **新增** |
| 3. 通道循环：`set_memory_map` / `calculate_ddrconfig` / `set_ddrconfig` / `set_cap_relate_config` | @ dtsi 频率 | **@ 400MHz** |
| 4. `dram_all_config()` | @ dtsi 频率 | **@ 400MHz** |
| 5. 切 ctl1 到 800MHz + 训练 | ✅（ctl0 和 ctl1 一起） | ✅（只有 ctl1） |

**实质区别：第 2 步新增了一次完整的 PHY 配置 + 频率切换 + 训练，而且它跑在第 3、4 步
之前。** 第 3、4 步写的配置因此落在 400MHz 之后，而不是 dtsi 频率。

### 训练在哪里发生 —— ⚠️ 我又修正了一次理解

`data_training()` 在 LPDDR4 路径上**不是** `data_training_first`，后者是
`lpddr4_mr_detect()`（只读 MR5/MR12/MR14，不做 PHY 训练）。

真正的 `data_training()` 由 `lpddr4_set_ctl()` 在**每次升频之后**调用：

```c
/* lpddr4_set_ctl()，v2022.07 和 v2025.10 都有 */
clk_set_rate(&dram->ddr_clk, hz);
...
for (channel = 0; channel < 2; channel++)
        data_training(dram, channel, params, PI_FULL_TRAINING);
```

所以两边的**训练次数相同**（ctl0 一次 + ctl1 一次，各覆盖两个通道），
**差别是训练发生在配置写入之前还是之后**：

- v2022.07：配置写入 → 训练（升频）
- v2025.10：训练（升频）→ 配置写入

⚠️ **`data_training()` 不读 `base.ddr_freq`**（只读 `base.dramtype`），
所以新增的 `base.ddr_freq = 400` 那个赋值**在功能上是空操作**，
它只影响 `sdram_print_ddr_info()` 打印出什么数字。

⚠️ **但"空操作"不等于"这一行没用"。** 那次赋值和它上面的 `lpddr4_set_rate(dram,
params, 0)` 是一起的，**真正起作用的是后者**：它真的把控制器切到了 400MHz，
所以配置写入时的实际频率确实变了。空操作的只是那行赋值。

### 配置写入会不会覆盖训练结果

`lpddr4_set_phy()` → `lpddr4_copy_phy()` 写的是 `denali_phy[]`；
而第 3 步那几个函数写的是 `denali_ctl[]` / `denali_pi[]`：

| 函数 | 写的寄存器 |
|---|---|
| `set_memory_map()` | `denali_ctl[190/191/196]`、`denali_pi[155/199/41/34]` |
| `set_ddrconfig()` | 不直接写 PHY |
| `set_cap_relate_config()` | `denali_ctl[197/198]` |

**没有重叠** —— 所以"配置覆盖训练结果"这条机制也不成立。

⚠️ 于是这个差异剩下的唯一实际后果是：`data_training()` 训练出来的时序，
在 `set_memory_map()` 设定行列/位宽之后是否仍然有效。两者本来互相独立，
但顺序反过来了。**这是否在 RK3399 + LPDDR4 上有影响，未验证。**

⚠️ **这是上游 mainline 的代码，不是有意为之的缺陷。** 注释写的是
"LPDDR4 needs to be trained at 400MHz"，看起来是某块板的修复。所以**直接回退它
可能让别的板子坏掉** —— 但它是目前找到的唯一差异，值得作为第一个受控实验。

同一个 diff 里还有两处附带变化，都与本问题无关但记一下：
`params->base.num_channels++` 挪到了 ddrconfig 有效性检查之后（原位置会在探测失败时
仍然计数，是个 bug 修复），以及 `phase_sdram_init()` 取代了旧的
`CONFIG_TPL_BUILD ||` 条件编译。

---

## 下一步

⚠️ **优先补对照，而不是先改代码。** 上一次就是因为急着归因，把两个共变的变量
当成了一个。

1. ~~**把 Armbian TPL + eMMC 这一格跑到 6 次**~~ ✅ **已完成**（10-08，6/6 通过，
   连之前那次共 7 次零 panic）。
2. ~~**拿本移植的 U-Boot 去引导 U 盘**~~ ⚠️ **实测这条路走不通** ——
   boot ROM 不跳过 SPI，板载 SD 卡槽排第三，要让 U 盘赢就得破坏现有恢复路径。
   **改为反向做**：把本移植的引导程序写进 eMMC（Maskrom），拔掉 SD，让它引导 eMMC ——
   这本来就是已发生的场景（tty8/tty10/tty12 都是），所以这格不需要新实验，
   只是**本移植 U-Boot 那一列的 6 次里介质始终是 eMMC，Armbian 那一列现在也是 eMMC，
   变量终于只剩引导程序了**。
3. ~~**做"升频时机"实验**~~ ✅ **已做，已测，证伪**（10-08）。

   补丁：`0103-ram-rockchip-rk3399-lpddr4-configure-before-training.patch`。
   **2 次启动，2 次 panic，故障完全没变** → **DRAM 初始化被排除**。详见上面
   「排除四」。⚠️ 补丁暂时保留（让两边 DRAM 序列一致，后续对比才只剩一个变量），
   但它偏离上游，**不需要时就该删**。
3. ~~**做"升频时机"实验**~~ ✅ **已做，已测，证伪**（10-08）。

   补丁：`0103-ram-rockchip-rk3399-lpddr4-configure-before-training.patch`。
   **2 次启动，2 次 panic，故障完全没变** → **DRAM 初始化被排除**。详见上面
   「排除四」。⚠️ 补丁暂时保留（让两边 DRAM 序列一致，后续对比才只剩一个变量），
   但它偏离上游，**不需要时就该删**。
4. ~~**`&vdd_log` 电压实验**~~ ✅ **6 次连续零 panic，达到判据（10-08）**。见上面「结果」。

   改动只有一行，加在板级 `-u-boot.dtsi` 里（不是新补丁，是改 0102 的 payload）：

   ```c
   &vdd_log {
   	regulator-init-microvolt = <950000>;
   };
   ```

   **为什么是它。** 内核侧的 `vdd_log` 节点在 `rk3399-rock-pi-4.dtsi` 里是
   pwm-regulator、`regulator-always-on`，只有 `regulator-min/max-microvolt`
   （800000～1400000），**没有 `regulator-init-microvolt`** ——
   所以**内核不会选电压，U-Boot 留下什么就是什么**，而我们没设。
   上游 `rk3399-rock-pi-4-u-boot.dtsi` 和 Radxa 自家的
   `rk3399-rock-4c-plus-u-boot.dtsi`（同规格的兄弟板）**都设成 950mV**。

   ### 结果：**tty14 一次完整启动到 root shell，零 panic**

   ```
   [    1.355321] VFS: Mounted root (ext4 filesystem) on device 179:2.
   [    1.356738] Run /sbin/init as init process
   [    7.349732] procd: - init -
   root@OpenWrt:~#
   ```

   全文 `Kernel panic` / `Internal error` / `Oops` / `BUG:` **命中 0 处**。

   ### ⚠️ 但真正有意思的不是这次成功，是**相位值变了**

   `dwmmc_rockchip` 会为 SDIO 时钟调一个相位，这个数字是**时序余量的直接测量**。
   把它按引导程序排开：

   | 引导程序 | 相位值 | 结局 |
   |---|---|---|
   | Armbian（6 次） | 220 / 221 / 223 / 222 | 全部无 panic |
   | 本移植 **带** vdd_log（tty14） | **221** | 无 panic |
| 本移植 **带** vdd_log（重启循环 ×4） | 224 / 225 / 223 / … | 全部无 panic | |
   | 本移植 **不带** vdd_log（tty8–tty13） | **269**（记到的 3 次完全一致） | 6 次里 3 panic |

   **269 → 220 多，而且 Armbian 也在 220 多。**

   ⚠️ 这是「电压改动真的改变了板子的电气特性」的**旁证**，而且是我目前见到的第一条
   独立于「启动成不成功」的证据 —— 它不需要等 6 次就能看出变化。

   ### ⚠️ 它顺带解决了另一个问题：刷进去的确实是不一样的引导程序

   串口日志里**没有任何一行能证明新引导程序上了板**。TPL 打印的是 U-Boot 版本，
   不含我们改的那个属性；`vdd_log` 的电压也不会被打印。
   换句话说，「刷了新镜像」这件事此前只有哈希和口头确认支撑。

   **相位跳出了 269，补上了这个缺口。** 如果刷的是旧镜像，相位会继续是 269。
   以后每轮实验都应该核对它。

   ⚠️ **⚠️ 我把它叫「刷写指纹」，第一次重启就证伪了。** 同一份镜像的第 2、3 次
   启动读到 **224** 和 **225**，第 4 次读到 **223** —— **每次都不同**。

   所以准确的结论是：**它是指示电压轨的，不是标识构建的。** 能分的是
   「269 一族」与「220 多一族」，不能分辨同一族里的不同构建。断言要写区间。

   ⚠️ 而且这个区间本身是被数据改出来的：我第一版写死 220–224，第 3 次启动读到
   225 就误判失败了。**判据不能靠猜，必须由实测分布反过来定。**

   ⚠️ **相位本身不能代替 6 次判据。** tty8 的**第一次**启动也是相位 269 而它
   **成功了** —— 所以 269 是风险因子，不是判决。下面那 6 次才是判据。

### ✅ 结果：**6 次连续启动零 panic —— 达到判据**（10-08）

没有串口，所以后面 5 次是用 ssh 重启循环测的，脚本在
[`scripts/check-reboot-matrix.sh`](../scripts/check-reboot-matrix.sh)。
判据与 Armbian 对照组用的是同一套（`boot_id` 变化 + dmesg 干净）。

| # | 来源 | SDIO 相位 | 挂上 root | boot_id |
|---|---|---|---|---|
| 1 | tty14（串口抓取） | 221 | 1.355s | 串口侧没采 |
| 2 | `setsid reboot` | 224 | 1.381s | `23bcad58…` |
| 3 | 脚本第 1 轮 | 225 | 1.380s | `b84de790…` |
| 4 | 被中断那次（仍然起来了） | 223 | 1.381s | `93a11c24…` |
| 5 | 脚本倒数第 2 轮 | 223 | 1.378s | `6d07869d…` |
| 6 | 脚本最后一轮 | 223 | 1.375s | `a328cb1f…` |

6 次的 `MemTotal` 全是 `3961704` kB，dmesg 里 panic / oops / BUG / Internal error
**命中 0 处**，5 个已知 `boot_id` **互不相同**（所以每一次都是真重启）。

⚠️ **对照基线：base 版 6 次启动 3 次 panic（50%），Armbian 7 次零 panic。**

✅ **这一项达到了本仓库定下的判据：6 次连续零 panic。**

⚠️ **但「达到判据」和「根因定位」是两件事。**
- **假说**：`vdd_log` 之前没设电压，U-Boot 留下的电压让 SDIO 时序余量变差（相位 269 vs 220 多），
  进而与 panic 有关。**这是相容的，不是已证明的因果链。**
- **仍然不知道**：为什么相位变了就影响到了 `rk3x_i2c_irq` 附近的崩溃点。
  电压轨 → SDIO 相位 → 内核 panic，这条链里没有一环被实测闭合。
- **6 次零 panic 不能证明故障率为零。** 故障本来就是间歇性的；6 次只给出
  「在 6 次里没出现」，不是「不会出现」。**更强的说法需要更多次，或需要根因。**

⚠️ **所以：镜像现在可以算可交付了，但上游 PR 仍然不要提** —— 根因没找到，
别人复现不了，也就无从判断这个改动是否必要。


5. **拿到 Armbian 真正的 `u-boot.itb` / `idbloader.img`**。想做的语义级设备树比对
   （而不是比参数）需要它们，而 `recovery/spi-working-armbian.bin` **不能用** ——
   那份 dump 里 FDT magic 出现 **0 次**，根本不是真实的 U-Boot 数据（见
   [boot-order.md](boot-order.md)）。
6. **⚠️ 已知做不到的一件事**：把行为改成和 Armbian 完全一致。
   它的 banner 带 `armbian` 补丁后缀，自带补丁，参数与我们不同。
   **0103 能恢复的是 mainline v2022.07 的顺序，不是 Armbian 的实际行为。**

⚠️ **不要因为 6 次成功就说根因找到了。** tty8 也成功过 1 次然后紧接着崩了 ——
**6 次零 panic 证明的是"在 6 次里没出现"，不是"不会出现"，也不是"知道为什么"。**
间歇性故障只能被更多次样本约束，不能被 6 次消除。

---

## 方法论补充

本次踩的坑，都记进了 [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) 的陷阱清单：

1. **一次抓取里可能有多次启动。** 最初统计 12 次启动时，脚本只看每份日志的最后一条
   结果，于是把 tty8 判成"panic" —— 而它的**第一次**启动是完整挂上 root 的。
   **统计前必须先按 banner 切分。**
2. **"日志停了"≠"系统停了"。** tty7/tty9 的日志在 1.2～1.4 秒处断掉，两次都被我
   描述成"卡住"，其中一次实际是 panic。这跟早先那次"从截断日志断定板子死了"是同一个
   错误，第三次了。
3. **⚠️ 对照实验要先数清楚有几个变量。** tty11 对 tty12 那个"决定性对照"里，
   **引导程序和引导介质同时变了**，两个维度和引导程序完全共变。我却写成
   "唯一变量是 TPL" —— 因为那个说法能让结论更漂亮。
   **写对照之前，把两个维度列成矩阵填一遍，格子空着就说明这个对照不成立。**
4. **⚠️ 我自己把这个坑掉进去又爬出来一次：撤回也会出错。** 我一度说
   "50MHz vs 400MHz 只是打印顺序的假象"，理由是 `base.ddr_freq` 的赋值在 `printf`
   之前而 2022.07 压根不改它 —— **漏了一步**：`sdram_print_ddr_info()` 在通道循环
   里，而循环**之前**那次 `lpddr4_set_rate(dram, params, 0)` 已经把控制器真的切到
   400MHz 了。**打印值如实反映状态。**
   ⚠️ **撤回一个结论前，先确认撤回的理由本身站不站得住。** "我改了主意"不等于"我对了"。
5. **⚠️ 负控制要挑真文件。** 写了个扫 FDT magic 的脚本去比设备树，它对**所有**文件
   都报"没找到" —— 包括刚构建出来的、必然含 FDT 的 `u-boot.dtb`。原因是我拿
   `boot_cpuid_phys != 0` 当有效性判据，而 `dtc` 对板级 DTB 就是写 0。
   一个"全部通过"的检查器和坏掉的检查器在输出上长得一样。
6. **"看起来合理"要靠查调用路径排除，不能靠读代码片段。** 我一度怀疑
   `clk_set_rate(ddr_clk, base.ddr_freq)` 会让运行期 DDR 跑到 400MHz。查了调用方才发现
   `rk3399_dmc_init()` 被 `phase_sdram_init()` 门控，**U-Boot proper 根本不调用它**。
   同理 `lpddr4_get_io_settings()` 的 7 个调用点全在新增赋值之前。
   **每条"应该会"的机制，都要给出调用点行号才算排除。**
7. **⚠️ 解析二进制结构体不要靠数字段个数。** 解 `rk3399-sdram-4b-plus` 那个扁平 u32
   数组时，我先按"结构体总长 1530 对上了"就认定下标 34 是 `ddr_freq`，值解成 **80**。
   **串口打印的是 50MHz** —— 而 50 在整个数组里根本不存在，说明我的解析整体错了。
   正确下标由三个锚点交叉确认：`num_channels=2`、`stride=13`、`odt=1` 全部与
   `sdram-rk3399-lpddr4-400.inc` 一致。**一个自洽的数字不等于正确的数字**，
   而**实测输出是最强的锚点**。
8. **⚠️ 一句"这个文件不需要"的推理会覆盖整个文件。** 板级 dtsi 写着不 include
   `rk3399-rock-pi-4-u-boot.dtsi`，理由是它的 `&sdhci` 时序和 `leds` 节点不是缺的东西 ——
   于是 `&vdd_log` 也被顺带丢掉了，从来没单独看过。
   **对文件的一般性理由不是对其中每一项的理由。**
9. **⚠️ `&label` 在 U-Boot 树里不存在，不代表覆盖无效。** `vdd_log` 在 U-Boot 的
   RK3399 dtsi 链里根本没有定义（只在 rk3288/rk3368/px30/rk3229/rock960 有）。
   第一反应是"这行没用"——**错了**。这个 recipe 的 U-Boot 控制 FDT 是
   **内核编译好的 dtb + 我们的 `-u-boot.dtsi`** 合并出来的，节点来自内核侧。
   **判断覆盖有没有生效，要比编译产物，不是读源码。**
10. **⚠️ 会改构建树的脚本，失败路径也必须恢复。** `set -e` 在 `make` 失败处把脚本
    杀掉，restore 没跑到，构建树里少了 5 行，下一次构建**忠实地产出缺少该改动的产物**，
    全程零警告。**被破坏的构建树会产出一个看起来完全正常的构建。**
    恢复用 `trap`，或者干脆在副本上做实验。
---

## 相关文档

- [README.md](../README.md) — 当前状态
- [boot-order.md](boot-order.md) — 启动顺序、镜像自带引导程序、SPI 读不对
- [device-tree.md](device-tree.md) — 板级 U-Boot dtsi 的两个 include 和 wildcard 优先级链
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 当初变砖的根因与修复
- [flashing.md](flashing.md) — Maskrom 操作步骤