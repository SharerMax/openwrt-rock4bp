# 本移植 U-Boot：能启动，但会随机 panic

**排查记录。** 2026-10-08，本文记录一次把"引导程序未验证"变成"验证出问题了"的实验，
以及**一次失败的归因**。

**结论先说**：本移植的 U-Boot **能在真机上启动系统**，`rockchip,sdram-params` 修复
确认生效；但 6 次启动里 3 次内核 panic，而同样的系统用 Armbian 的 TPL 引导，6 次零 panic。

⚠️ **但"所以问题在 DRAM 初始化"这个推论站不住。** 那次对照实验有**两个**变量：
引导程序换了，**引导介质也换了**（Armbian 全是从 U 盘，本移植全是从 eMMC）。
拿到 v2022.07 源码逐层比对之后，DRAM 参数、DRAM 的 CONFIG、板级 dtsi **全部逐字节
相同**，93 KB 的驱动只差 3%。目前唯一找到的实质差异是 **LPDDR4 升频到 400MHz 的时机**
（v2025.10 把它挪到了配置写入之前）。

**当前状态：根因未定位。** 别把本文任何一节当成结论 —— 包括这一节。

**只想知道现状**：见 [README.md](../README.md) 顶部的状态节。
**要理解当初那个缺陷怎么修的**：见 [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md)。
**要动手修**：见文末「下一步」。

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

## 12 次启动的完整对照

这一节是从 `log/tty*.txt` 里逐条提取的，不是凭印象写的。
⚠️ tty8 一次抓取里有**两次**启动（第一次成功、第二次 panic）—— 把它们算成一次，
就会得出"从没有成功过"的错误结论。

| 日志 | 引导程序 | 引导源 | SDIO | rootfs | 结果 |
|---|---|---|---|---|---|
| tty2 | Armbian | U 盘 | 无卡 | — | 日志早断 |
| tty3 | Armbian | U 盘 | 无卡 | sda1 | 日志早断 |
| tty4 | Armbian | U 盘 | tuned 220 | sda1 | 到达 shell |
| tty5 | Armbian | U 盘 | tuned 221 | sda1 | 到达 shell |
| tty6 | Armbian | U 盘 | tuned 223 | sda1,sda2 | ✅ **挂上 root** |
| tty7 | **本移植** | eMMC | 无卡 | — | 日志早断 @1.24s |
| tty8 #1 | **本移植** | eMMC | tuned 269 | mmcblk0p2 | ✅ **挂上 root** |
| tty8 #2 | **本移植** | eMMC | 无卡 | — | ❌ **panic** @0.64s |
| tty9 | **本移植** | eMMC | tuned 269 | — | 日志早断 @1.40s |
| tty10 | **本移植** | eMMC | tuned 269 | — | ❌ **panic** @1.39s |
| tty11 | Armbian | U 盘 | tuned 222 | sda1,sda2 | ✅ **挂上 root** |
| tty12 | **本移植** | eMMC | 无卡 | — | ❌ **panic** @0.54s |

汇总：

| | 本移植 U-Boot | Armbian U-Boot |
|---|---|---|
| 启动次数 | 6 | 6 |
| 挂上 root | **1** | 2 |
| 到达 shell | 0 | 2 |
| **内核 panic** | **3** | **0** |
| 日志早断 | 2 | 2 |

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

**引导程序换了，引导介质也换了。** 12 次启动的实际分布是：

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

2026-10-08：eMMC 上重装了 Armbian，**从 SPI 里的 Armbian U-Boot 引导 eMMC 成功**
（`root=UUID=7043da66-…`，`ubootpart=d2a80aa7-01`，dmesg 无内存错误）。
所以"Armbian TPL + eMMC 引导"是通的 —— 但只跑了 1 次，**离 6 次的判据还差得远**。

⚠️ 这只是 1 次。要用它当对照，得重复到 6 次以上（见文末「下一步」）。

### 还没填的格子

| | 从 U 盘引导 | 从 eMMC 引导 |
|---|---|---|
| Armbian U-Boot | ✅ 6 次，0 panic | ⚠️ 1 次，通 |
| 本移植 U-Boot | ❌ 从未测过 | ❌ 6 次，3 panic |

左下角那一格要填上，得让本移植的引导程序去引导 U 盘 —— 而 boot ROM 不会跳过 SPI，
所以只能改介质侧的引导顺序，不能靠换 boot target。

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

### ⚠️ 顺带撤回："50MHz vs 400MHz 是训练频率不同" —— ❌ 是打印顺序的假象

本文早期版本把串口输出里的这个差异当成关键线索：

| | Armbian | 本移植 |
|---|---|---|
| 打印顺序 | `Channel 0: LPDDR4, 50MHz` **在前** | `lpddr4_set_rate: ... 400MHz` **在前** |
| Row 位数 | `Row=16/15` | `Row=16` |

**两边的训练频率是同一个值。** `sdram_print_ddr_info()` 打印的是
`params->base.ddr_freq`，而 v2025.10 新增的那行把 `base.ddr_freq` 改成 400 的位置
**在打印之前**、v2022.07 里它压根不改这个字段 —— 所以同一个运行时状态，
两边打印出不同的数字。**这是赋值相对于 `printf` 的位置差异，不是频率差异。**

（`Row=16/15` vs `Row=16` 那一行倒是真的，但它属于容量探测结果，且 dtsi 相同，
所以也解释不了差异。）

### 排除四、五、六：另外三条我怀疑过、然后自己查掉的机制

写下来是因为它们看起来都很合理，而且我都差点就当成结论了：

| 怀疑 | 为什么不成立 |
|---|---|
| IO 参数按错误的频率挑选（`lpddr4_get_io_settings()` 用 `base.ddr_freq` 选驱动强度，若在赋值之后调用就会按 400 选） | 全部 7 个调用点在第 361～2101 行，**都在第 2969 行赋值之前** |
| 运行期 DDR 时钟不同（`clk_set_rate(&priv->ddr_clk, params->base.ddr_freq * MHz)`） | 该行在 `rk3399_dmc_init()` 里，2025.10 用 `phase_sdram_init()` 门控，**U-Boot proper 根本不调用它**；`clk_set_rate` 也在 `sdram_init()` 之前执行，用的是 dtsi 值 |
| DRAM 驱动代码在 2022.07→2025.10 之间被大改 | 93 KB 的文件里只差 **+64/−48 行**（3%） |

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
| 2. 切 ctl0 到 400MHz | — | ✅ **新增** |
| 3. 通道循环：`set_memory_map` / `calculate_ddrconfig` / `set_ddrconfig` / `set_cap_relate_config` | @ dtsi 频率 | **@ 400MHz** |
| 4. `dram_all_config()` | @ dtsi 频率 | **@ 400MHz** |
| 5. 切 ctl1 到 800MHz | ✅（ctl0 和 ctl1 一起） | ✅（只有 ctl1） |

**实质区别：3、4 两步的配置写入，从 dtsi 频率下改成了 400MHz 下进行。**
训练本身（`data_training_first`）两边都在同一步、同一个频率。

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

1. **把 Armbian TPL + eMMC 这一格跑到 6 次**（现在只有 1 次）。这是最便宜的一步 ——
   就是重启。**需要先征得同意**，因为它是目前唯一的可用对照组。
2. **拿本移植的 U-Boot 去引导 U 盘**，填上左下角那一格。同样只能靠改介质侧。
3. **做上面那个"升频时机"实验**：把第 2 步挪回配置之后，重建，跑 6 次。
   ⚠️ 这是改动上游代码，必须做成可回退的补丁，并且
   `check-patch-sources.sh` 要跟着更新。
4. **拿到 Armbian 真正的 `u-boot.itb` / `idbloader.img`**。想做的语义级设备树比对
   （而不是比参数）需要它们，而 `recovery/spi-working-armbian.bin` **不能用** ——
   那份 dump 里 FDT magic 出现 **0 次**，根本不是真实的 U-Boot 数据（见
   [boot-order.md](boot-order.md)）。

⚠️ **不要因为 tty8 成功过一次就认为改好了。** 6 次里成功 1 次和成功 6 次是完全不同的
两件事。这正是本文开头那个教训的延续：一次成功的启动证明"能工作"，不证明"稳定"。

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
4. **⚠️ 不要把打印顺序当成状态差异。** 串口里 `50MHz` 在前、`400MHz` 在前，看起来
   像是"Armbian 低速起步、我们直接高速"。实际上两边的训练频率相同，差别只是
   `base.ddr_freq` 赋值相对于 `printf` 的位置。**差异要回到代码里查，不能只看输出
   的排列。**
5. **⚠️ 负控制要挑真文件。** 写了个扫 FDT magic 的脚本去比设备树，它对**所有**文件
   都报"没找到" —— 包括刚构建出来的、必然含 FDT 的 `u-boot.dtb`。原因是我拿
   `boot_cpuid_phys != 0` 当有效性判据，而 `dtc` 对板级 DTB 就是写 0。
   一个"全部通过"的检查器和坏掉的检查器在输出上长得一样。
6. **"看起来合理"要靠查调用路径排除，不能靠读代码片段。** 我一度怀疑
   `clk_set_rate(ddr_clk, base.ddr_freq)` 会让运行期 DDR 跑到 400MHz。查了调用方才发现
   `rk3399_dmc_init()` 被 `phase_sdram_init()` 门控，**U-Boot proper 根本不调用它**。
   同理 `lpddr4_get_io_settings()` 的 7 个调用点全在新增赋值之前。
   **每条"应该会"的机制，都要给出调用点行号才算排除。**

---

## 相关文档

- [README.md](../README.md) — 当前状态
- [boot-order.md](boot-order.md) — 启动顺序、镜像自带引导程序、SPI 读不对
- [device-tree.md](device-tree.md) — 板级 U-Boot dtsi 的两个 include 和 wildcard 优先级链
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 当初变砖的根因与修复
- [flashing.md](flashing.md) — Maskrom 操作步骤
