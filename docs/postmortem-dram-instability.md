# 本移植 U-Boot：能启动，但会随机 panic

**排查记录。** 2026-10-08，本文记录一次把"引导程序未验证"变成"验证出问题了"的实验，
以及把问题缩小到 DRAM 参数的证据链。

**结论先说**：本移植的 U-Boot **能在真机上启动系统**，`rockchip,sdram-params` 修复
确认生效；但 6 次启动里 3 次内核 panic，而**同样的系统用 Armbian 的 TPL 引导，6 次零
panic**。唯一变量是 TPL/SPL，所以问题在 DRAM 初始化这一层。

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

## 决定性对照：唯一变量是 TPL

```
tty11  Armbian TPL 2022.07_armbian  → 引导 U 盘   → VFS: Mounted root (ext4) on device 8:2  → 进 shell
tty12  本移植 TPL 2025.10-OpenWrt   → 引导 eMMC  → 0.54 秒 panic
```

两边完全相同的部分：

| 项 | 值 | 两边是否一致 |
|---|---|---|
| 内核 | `Linux 6.12.94` | ✅ |
| dtb | `radxa_rock-4b-plus device tree blob`，**63877 字节** | ✅ |
| dtb 哈希 | crc32 `919fa3f9` + sha1 `b44f4d59…` | ✅ **逐字节相同** |
| kernel 哈希 | crc32 `55f4bcaa` + sha1 `05a99f8f…` | ✅ **逐字节相同** |
| rootfs | `PARTUUID=5452574f-02` | ✅ 同一个镜像 |
| DRAM | 4 GiB (total 3.9 GiB) | ✅ |

不同的部分：**只有 TPL/SPL/U-Boot**。

所以内核、设备树、rootfs 都被排除。剩下的差异就在 DRAM 初始化上。

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

## 定位到 DRAM 参数

⚠️ **以下是假设，尚未证实。** 记在这里是因为它是下一步的方向，不是结论。

Armbian 的 TPL 输出：

```
Channel 0: LPDDR4, 50MHz
BW=32 Col=10 Bk=8 CS0 Row=16/15 CS=1 Die BW=16 Size=2048MB
Channel 1: LPDDR4, 50MHz
256B stride
lpddr4_set_rate: change freq to 400000000 mhz 0, 1
lpddr4_set_rate: change freq to 800000000 mhz 1, 0
```

本移植的 TPL 输出：

```
lpddr4_set_rate: change freq to 400MHz 0, 1
Channel 0: LPDDR4, 400MHz
BW=32 Col=10 Bk=8 CS0 Row=16 CS=1 Die BW=16 Size=2048MB
Channel 1: LPDDR4, 400MHz
256B stride
lpddr4_set_rate: change freq to 800MHz 1, 0
```

两处可见差异：

| | Armbian | 本移植 |
|---|---|---|
| 起始频率 | **50MHz** | 直接 400MHz |
| Row 位数 | `Row=16/15` | `Row=16` |

**起始频率**可能是关键：DRAM 训练（write leveling / gate training）通常需要从低速
起步给 PHY 和控制器留校准时间。直接跳到 400MHz 可能训练不充分，留下边界不稳的时序。

⚠️ **但这只是猜测，而且有一条反证**：本移植用的 `rk3399-sdram-lpddr4-100.dtsi`，
上游 `rk3399-rock-4c-plus-u-boot.dtsi` **用的是同一个文件**。mainline 认为它能同时
服务多块同规格的 RK3399 板子（包括 Radxa ROCK 4C+，同为 64 位双通道 LPDDR4）。

所以**更可能是别的差异** —— 比如某个训练参数、某个时序值、或者 TPL 版本本身
（2022.07 vs 2025.10 之间的 DRAM 代码变动）。

**要定论得比对 Armbian 的 dtsi 源码，那棵树不在手上。**

---

## 下一步

**在拿到 Armbian 的 U-Boot 源码之前不要改参数。** 现在改就是猜，而猜错的代价是又一块砖。

1. **拿到 Armbian 的 U-Boot 源码**（`u-boot-2022.07`，对应 banner 里的
   `2022.07_armbian-2022.07-Se092-P8f7f-Ha199-…`），看它的 `rk3399-sdram-*.dtsi`
   实际是哪个，以及和我们那份差在哪。
2. **同时比对 TPL 的 DRAM 代码**：2022.07 → 2025.10 之间 `drivers/ram/rockchip/`
   可能有实质变动，而 dtsi 只是参数。
3. 有了差异再改，改完**必须重新验证 6 次以上** —— 因为故障率是 3/6，一次成功说明不了
   任何问题。

⚠️ **不要因为 tty8 成功过一次就认为改好了。** 6 次里成功 1 次和成功 6 次是完全不同的
两件事。这正是本文开头那个教训的延续：一次成功的启动证明"能工作"，不证明"稳定"。

---

## 方法论补充

本次又踩了两个坑，都记进了
[postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) 的陷阱清单：

1. **一次抓取里可能有多次启动。** 最初统计 12 次启动时，脚本只看每份日志的最后一条
   结果，于是把 tty8 判成"panic" —— 而它的**第一次**启动是完整挂上 root 的。
   **统计前必须先按 banner 切分。**
2. **"日志停了"≠"系统停了"。** tty7/tty9 的日志在 1.2～1.4 秒处断掉，两次都被我
   描述成"卡住"，其中一次实际是 panic。这跟早先那次"从截断日志断定板子死了"是同一个
   错误，第三次了。

---

## 相关文档

- [README.md](../README.md) — 当前状态
- [boot-order.md](boot-order.md) — 启动顺序、镜像自带引导程序、SPI 读不对
- [device-tree.md](device-tree.md) — 板级 U-Boot dtsi 的两个 include 和 wildcard 优先级链
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 当初变砖的根因与修复
- [flashing.md](flashing.md) — Maskrom 操作步骤
