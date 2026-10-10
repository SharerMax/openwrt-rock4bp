# 启动顺序、SPI 引导，以及那块读不对的 SPI Flash

这块板的三件事必须放在一起看，否则每件单独看都会得出错误结论：

1. **SPI → eMMC → SD 的启动顺序**，决定了任何"绕过 SPI"的手段都无效。
2. **镜像自带引导程序**，所以 SPI 不是必需的 —— 但正因为它在最前面，它挡路。
3. **Linux 读不到这块 SPI 的正确内容**，所以不能从运行中的系统备份或写入它。

> ⚠️ **2026-10-09：第 4 条，关于 Maskrom 写 SPI 的机制。**
>
> 本文长期写着「Maskrom `wl` 只写 eMMC，不碰 SPI」。**观察是对的，机制是错的** ——
> 而错的机制会让人以为这条路是封死的。新增的一节：
> [SPI 现在可以写了](#spi-现在可以写了-2026-10-09)。

> ⚠️ **2026-10-10：SPI 一直可见，10-08 记的「不被探测」整段作废。**
>
> 同一镜像上实测：`rockchip-spi` 已绑定、`/dev/mtd0` 存在（4 MiB / `spi1.0`）、无 deferred
> probe、连续三次读 md5 全同。冷启动（`POR`）与热启动**结果一致**。
>
> ⚠️ **但「读出来的数据是错的」这条仍然成立**，而且现在有本移植镜像上的实测
> （整片数据均匀分布、0 个 rkimage/FIT magic）。**别把 SPI 当恢复路径** ——
> 一个稳定返回错误数据的 `/dev/mtd0` 比没有更危险。

排查过程（含几条走错的岔路）记在
[postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md)。本文只讲这三条结论和它们的后果。

---

## 启动顺序

RK3399 的 boot ROM 按 **SPI → eMMC → SD** 找引导程序。

**只要 SPI 上有可读的引导程序，它就赢。** 后面是什么完全不看。

⚠️ 因此：

- ❌ **短接 SPI 引脚让 boot ROM 跳过 SPI** —— 实测无效
- ❌ **卡上放一份好的引导程序** —— SPI 成功就不再看卡上那份
- ✅ 只有 **Maskrom** 能改 SPI 上的引导程序（已验证）

### ⚠️ 2026-10-10：按板上的键能进 maskrom，**不必短接 SPI**

⚠️ **本文长期把"短接 SPI 引脚"写成进 maskrom 的必需步骤，那条不再成立。**

实测（重复多次，每次都成功）：

| 组合 | 是否枚举出 maskrom 设备 |
|---|---|
| 只按 **Recovery** 键，**不短接 SPI** | ✅ **能** |
| 只按 **Maskrom** 键，**不短接 SPI** | ✅ **能** |
| Recovery + Maskrom 同时按 | ✅ 能 |

⚠️ **Recovery 键是本仓库先否掉、2026-10-10 才发现存在的。** 此前文档写"板上只有 Maskrom
+ Reset，没有 recovery 键"，依据是两个书面来源互相矛盾时选了官方那个，**没人看实物**。

**但"按键优先级高于 SPI"这个解释是错的 —— 而且 2026-10-11 测出了真正的原因。**
`log/tty19.txt` 里按键那次是 **U-Boot proper 自己发现按键、自己复位**，ROM 才在复位后
进 USB download 路径。⚠️ **按键压根没有参与 ROM 的介质选择**，它作用在 U-Boot proper
那一层。上面"只要 SPI 上有可读的引导程序，它就赢"因此**没有被推翻，也没有被按键影响**。

⚠️ **2026-10-10 当时写的是"两件事同时发生、机制未测"，这个说法现在作废** ——
不是同时发生，是有先后：先完整启动到 U-Boot proper，再由它复位进 maskrom。

**实际影响：进 maskrom 少一个要短接 40-pin SPI CLK（23/25）的步骤。**

⚠️ **2026-10-11 补上机制之后，这条「实际影响」要收窄。** `log/tty19.txt` 显示按键这条路
**不是 ROM 在上电时选的**：ROM 正常把引导程序跑到 U-Boot proper，**U-Boot proper 自己发现
按键、自己复位**，ROM 才在复位后进 USB download 路径

```
download key pressed, entering download mode...resetting ...
...
Boot1 Release Time: ... version: 1.26
UsbBoot ...74128
```

所以**按键这条路需要一个能跑起来的 U-Boot proper**；而短接 SPI 引脚是由 ROM 直接进，
不依赖引导程序。⚠️ **引导程序坏掉时按键能不能救回来没有测过** —— 那正是救砖场景，
所以**短接那一步必须保留为兜底**，不是可以删掉的旧做法。两条路**不等价**。

这**不改变** SPI→eMMC→SD 的引导顺序，也不改变 `wl` 选错 loader 会静默写到另一块介质这件事。
按键与板级事实见 [hardware.md](hardware.md#板载按键maskromresetrecovery)。

---

## 镜像自带引导程序

sysupgrade 镜像是 DOS/MBR，分区布局：

| 分区 | 扇区 | 大小 | 内容 |
|---|---|---|---|
| p1 | 65536–98303（可启动） | 16 MiB | FAT32 里的 kernel FIT |
| p2 | 131072–1179647 | 512 MiB | rootfs |

**引导程序的位置是 LBA 0x40，不是 LBA 0。**

| 位置 | 内容 | 实测字节头 |
|---|---|---|
| LBA 0x40（字节 0x8000） | rkimage 容器（TPL+SPL） | `3b 8c dc fc be 9f 9d 51` |
| LBA 0x4000（字节 0x800000） | U-Boot 本体的 FIT | `d0 0d fe ed` |

这是 OpenWrt rockchip 镜像机制本来就有的行为 —— `target/linux/rockchip/image/Makefile`
用 `gen_image_generic.sh ... 32768` 留 32 MiB，然后
`dd if=$(UBOOT_DEVICE_NAME)-u-boot-rockchip.bin of=$@ seek=64`。

> ⚠️ **这个事实被文档写反过两次方向。** 早期说"镜像里不含 TPL/SPL/idbloader"，
> 查证后发现**确实有**。两次都是"没查就写"。
>
> ⚠️ 查这一段时容易踩的坑：**只看偏移 0 会误判成"镜像里根本没有引导程序"**。
> 偏移 0 只有 MBR 和零。

### 它已经被执行过了 —— 但会随机 panic

⚠️ **本节原先写着"它从未被执行过"，那是 2026-10-06 的状态，已过时。**

2026-10-06 用 Maskrom 把整包写进 eMMC（`rkdeveloptool wl 0 <镜像>`），**镜像自带的那份
在真机上执行了** —— 但这个结论当时是靠"它跑起来了"推出来的，而它成立的**前提是 SPI
上有东西可引导**。⚠️ 那个前提后来不成立了，见下面「SPI 上已经没有什么可引导的了」。

结果分两半：

| | 结论 |
|---|---|
| ✅ `rockchip,sdram-params` 修复**生效** | TPL 打出完整 LPDDR4 训练过程，两通道各 2048MB |
| ❌ 但**会随机 panic** | base 版 6 次启动 3 次内核 panic，三次都是"函数指针被指向垃圾地址"。⚠️ 更新的 `+vdd_log` 构建判据是 6 次连续零 panic，目前 1 次 |

⚠️ **那个"决定性对照"有两个共变变量** —— 引导程序换了，**引导介质也换了**
（Armbian 全是从 U 盘，本移植全是从 eMMC），两个维度完全共变，**不能**据此断定
是 TPL 的问题。

而且逐层比对 v2022.07（Armbian）之后：**DRAM 参数逐字节相同、DRAM 的 CONFIG 相同、
板级 dtsi 相同**，93 KB 的驱动只差 3%。

⚠️ 写这一段时能说的是「**DRAM 初始化不是原因**」—— 这是排除法给的结论，站得住。
**根因本身当时未定位。** ⚠️ 10-09 曾推断「`vdd_log` 被停在 0% 占空比」，
**同日被实测推翻并撤回**（见上面那张表里的 800mV 行）。完整证据链见
[postmortem-dram-instability.md](postmortem-dram-instability.md)。

⚠️ **原来的推断方向反了。** 早先推断"这份引导程序只对不贴 SPI 的量产板有意义，而
那类板恰好是唯一没被验证过的组合"—— 现在它验证过了，结论是**能启动但会崩**。
所以问题不是"能不能引导"，而是"DRAM 参数是否有缺陷"。

---

## ⚠️ SPI 上已经没有什么可引导的了

⚠️ **这一节纠正的是我自己写下的一个断言。** 我在 AGENTS.md 里写"SPI 上仍然存着能用的
Armbian 引导程序，那是恢复路径，Maskrom `wl` 不碰它"—— **没查就写了。**

答案一直写在日志里（`log/tty14.txt` 前 12 行）：

```
U-Boot TPL 2025.10-OpenWrt-r33051-f5dae5ece4 (Jun 29 2026 - 12:59:20)
Channel 0: LPDDR4, 50MHz
...
Trying to boot from BOOTROM
Returning to boot ROM...
```

`Trying to boot from BOOTROM` 是 SPL 在**下一级没找到可引导镜像**时才打印的，
后面紧跟 `Returning to boot ROM...`，意思是这一级放弃、交回 ROM 走下一条链路 —— eMMC。

⚠️ **2026-10-11：这两行不能证明"ROM 落到了 eMMC"，因为它们出现在一次完全成功的启动里。**
`log/tty19.txt` 第 9–10 行和第 126–127 行各有一次，位置一模一样，后面都跟着 SPL，一路
进到 Linux 并挂上 root（该日志零 panic）。⚠️ **所以这两行是正常路径的一部分，不能当作
"SPI 上没有可引导镜像"的证据。** 本文当时是拿它推 SPI 为空的，那一推**不成立**。

⚠️ **SPI 上现在究竟有没有可引导镜像，仍然未测。** 别把"这两行出现了"重新当成"SPI 是空的"。

⚠️ **机制补充（10-09）**：我这一节原先把原因写成「Maskrom `wl` 只写 eMMC，不碰 SPI」。
**那句的观察是对的，机制是错的**：`wl` 并不选择介质，**是 loader 选择的** ——
换成 `rk3399_loader_spinor_*` 就写 SPI。详见下面「SPI 现在可以写了」一节。
**SPI 上现在是空的**这个结论不受影响 —— 但注意⚠️ 上面 10-11 那条：这句话现在的依据
只有"没找到别的证据"，不再是那两行日志。

⚠️ **后果：当前唯一的恢复路径是 Maskrom。** 没有 TTL 适配器时，SPI 上有没有东西都不影响
TPL/SPL 的可见性，所以之前没人留意它能否引导 —— 但它一旦被写成"备用恢复路径"，
就会在真需要的时候失效。

⚠️ **结论的来源是 ROM 的输出，不是我们的推断。** 整节只有一处依赖推断
（"启动顺序是 SPI 优先"），而那一条已被实测固定。

---

## ✅ 2026-10-10：SPI 一直可见，10-08 记的「不被探测」是错的

⚠️ **本节整段结论作废。** 10-08 记的「OpenWrt 6.12.94 上复现不出 `/dev/mtd*`」**不成立**：
同一天（10-10）在**同一个镜像**上，SPI 正常绑定、`/dev/mtd0` 存在、读稳定。
设备树从来是对的，驱动从来是能工作的。

先说清楚为什么会有 10-08 那次记录，再给出现在的实测 —— 保留前者是因为
**同一台板子、同一份镜像、同一个 BL31 会给出两种相反的观测**，这件事本身还没解释。

### 10-08 那次到底是什么状态

那一组日志（`log/tty14` … `log/tty17`）确实记录了：

```
[18.409961] amba ff6d0000.dma-controller: deferred probe pending: (reason unknown)
[18.410677] amba ff6e0000.dma-controller: deferred probe pending: (reason unknown)
[18.411357] platform ff1d0000.spi:         deferred probe pending: (reason unknown)
```

机制是清楚且正确的：`spi-rockchip.c` 请求 TX DMA 通道，provider 是上游
`rk3399-base.dtsi` 里 `dmas` 指向的 `&dmac_peri`（PL330，`arm,pl330`）；
两个 PL330 自己先因为 amba 层读不到 `PERIPH_ID` 而挂起，SPI 就在它们下游，
而这条路径**不打任何日志**，所以只剩 deferred probe 超时后的 `(reason unknown)`。

⚠️ **这部分机制描述仍然有效**，它解释了 10-08 那三行**是怎么产生的**。
**作废的是「SPI 在 OpenWrt 上不可用」这个结论，不是这段机制。**

### 10-10 实测：SPI 完全正常

三次启动，其中一次是真冷启动（`Reset cause: POR`），另两次 `RST`：

| 日志 | Reset cause | PL330 | deferred | `/dev/mtd0` |
|---|---|---|---|---|
| `log/cold1` | **POR** | ✅ 加载 | 无 | ✅ |
| `log/warm1` | RST | ✅ 加载 | 无 | ✅ |
| `log/warm2` | RST | ✅ 加载 | 无 | （日志截断，未跑到 `ls /dev/`） |

板上实测（`root@192.168.3.8`，身份已正向核对）：

```
/sys/bus/platform/devices/ff1d0000.spi/driver -> .../drivers/rockchip-spi   ← 已绑定
/proc/mtd:  mtd0: 00400000 00001000 "spi1.0"
/sys/class/mtd/mtd0/:  type=nor  size=4194304  erasesize=4096
dmesg | grep -i deferred      → 无
```

### ⚠️ 我提的一个假设，实验当天就被否掉了

10-08 那批日志里 PL330 全部挂起，而更早的日志（tty2–tty13、tty18）里同一个镜像
**全部正常加载**。BL31、U-Boot、内核三者都逐字节相同，所以「静态配置导致」解释不了。

我提的假设是：mainline TF-A 不配置 DMAC 的 SGRF 安全位（已核对 TF-A
`plat/rockchip/rk3399/drivers/secure/secure.c`，`secure_sgrf_init()` 只写
`SGRF_SOC_CON(5)(6)(7)`，没有 DMAC），因此 `PERIPH_ID` 从非安全世界读回 0；
而 SGRF 的值**跨热复位保留**，所以跑过 Armbian（rkbin BL31 会写这些位）之后
热启动就正常，冷启动则挂起。

**判别设计**：冷启动应 DEFER、热启动应 PL330-OK。

**实测结果：冷启动（POR）和两次热启动全部 PL330-OK。预测在第一次实验就被否掉。**

⚠️ 所以**「冷/热」这个变量与它无关**，「跨复位保留的状态」这个解释作废。
RK3399 + mainline TF-A 上 PL330 读不到 `PERIPH_ID` 的问题在社区是已知的
（linux-arm-kernel 2023-04 与 Armbian build#9285），**但那不是这里的机制** ——
因为这里同一份 TF-A 下它大部分时候是好的。

⚠️ **未结清**：同一镜像、同一 TF-A 下，`tty14`–`tty17` 挂起而其它日志正常。
本节记不下这个差别来自哪里，需要比对那几次的构建差异才能定论。
**不要再把它记成「SPI 不可用」** —— 那是 10-08 的一次观测，不是结论。

### 因此：不需要「去掉 `dmas`」这个改动

10-08 曾经建议在 `&spi1` 里 `/delete-property/ dmas; dma-names;` 退回 PIO 以绕过
静默挂起。**现在不需要** —— SPI 本来就能工作，而且它用的是 DMA（PL330 已加载）。

⚠️ **但即使 SPI 可见，它读出来的数据仍然是错的**，见下一节。
**这是唯一还没解决的问题，也是唯一还有现实意义的问题。**

---

## ⚠️ Linux 从这块 SPI 读不到正确的内容

**不是"读不稳定"，是读到的根本不是芯片内容。**

给内核补上 `&spi1` + `flash@0` 节点之后（见 [device-tree.md](device-tree.md)），
`/dev/mtd0` 出现了，几何信息也对：

```
/proc/mtd            mtd0: 00400000 00001000 "spi1.0"
/sys/class/mtd/mtd0  type=nor   flags=0xc00   bad_blocks=0
rockchip-spi 驱动已绑定，spi1.0 存在
```

**两次独立读取（块大小 64 KiB 和 4 KiB 各一次）字节完全相同** ——
按"读是否稳定"的标准，这是满分通过。

**但内容是错的：**

```
整个 4 MiB 里：rkimage magic  无
              FIT magic(d00dfeed) 无
              U-Boot TPL / SPL / 2022 / 20  全部无
```

而这块芯片上明明有能跑的引导程序 —— SPL 明确 `Trying to boot from SPI`，U-Boot proper
起来了，还从 SPI 读了环境变量（`bad CRC`）。

用 Armbian 镜像里那份引导程序做参照（它确定是 rkimage，`0x8000` 处有 magic），和 dump
逐段比对：

```
0x8000 / 0x9000 / 0x12000 / 0x20000 各 256 字节   全部 NOT FOUND
dump contains 3b8cdcfcbe9f9d51 : no
dump contains d00dfeed         : no
```

**JEDEC ID 这类短事务读对了**（所以 4 MiB / 4 KiB 的几何信息合理），
**批量数据读全是错的**。

### ✅ 2026-10-10 复测：OpenWrt 6.12.94 上同样读不对，且错法更清楚

⚠️ **本节结论此前只有 Armbian 6.18 的证据**（见下文两节），而 OpenWrt 侧当时连
`/dev/mtd0` 都复现不出来，所以一直没机会测。现在 SPI 确认可用（见上一节），
在**本移植自己的镜像**上重测，结论不变，且多出一条更直接的判据。

**读稳定 —— 完全稳定：**

```
三次独立读 /dev/mtd0（全片 4 MiB）：
  read1: 9346c99ff025fe0d9d814842d97cebbd
  read2: 9346c99ff025fe0d9d814842d97cebbd
  read3: 9346c99ff025fe0d9d814842d97cebbd
块大小 65536 与 4096 各一次，md5 相同
```

**内容 —— 仍然不对，而且错法有明确特征：**

```
strings -n 12   -> 149 条   ← 有真实 U-Boot 符号（rk3399_spi_set_clk、efi_free_pool、
                              write_sparse_image、NXP i.MX8M Boot Image…）
rkimage 3b8cdcfcbe9f9d51 -> 0 处
FIT     d00dfeed         -> 0 处
U-Boot 版本串（20xx）     -> 0 条
```

⚠️ **最有说服力的一条：整片 4 MiB 的数据分布。** 真实的 bootloader + 已擦除的空白区，
应该是「头部集中有数据、后部全 `0xFF`」。实测按 512 KiB 分块统计**非 `0xFF` 字节数**：

```
0x000000   151138
0x080000    35109
0x100000    45016
0x180000    52445
0x200000    55948
0x280000    55194
0x300000    60675
0x380000    54755      ← 末尾仍有 5 万多非 FF 字节
```

**从头到尾一个量级，均匀分布。** 末尾那块本该是擦除后的空白区，却和头部一样「满」。

⚠️ 这解释了 10-08 那次 Armbian 观测的「两次读 md5 不同」：读到的根本不是芯片内容，
所以「稳不稳定」这个问题问错了对象 —— **10-10 的三次 md5 完全相同，但错得同样完全相同。**

与 eMMC 对照（eMMC 已知正确）：

```
eMMC 0x8000 引导程序区  vs  SPI 0x8000 区   ->  首字节即不同
md5: eMMC 39f061e3…  /  SPI 56ee49b3…
```

### 为什么这比"读不稳"更危险

因为它**能通过任何"读是否稳定"的检查**。一个确定性失败返回每次都一样的错误数据，于是：

- 三次 `md5sum` 相同 → "读稳定，通过"
- 两种块大小结果相同 → "与块大小无关，通过"
- `bad_blocks=0`、`type=nor` → "芯片认出来了，通过"

**一个能在垃圾上通过的检查不是检查。**

### 三个后果

1. **没法从 Linux 做可信备份。** 备份下来的不是芯片内容，当备份比没有更糟。
2. **不能从 Linux 写入引导程序。** 写完读不回来验证 —— 那是对唯一会造成不可逆变砖的
   介质做盲写。
3. 板载上也没有写入工具：`flashcp` / `flash_erase` / `mtd write` 都不在，只有
   `/sbin/mtd`。

**要改 SPI 上的引导程序，只有 Maskrom 这一条路。**

⚠️ **2026-10-10 强调：以上全部与「SPI 是否可见」无关。** SPI 现在是可见的、
`/dev/mtd0` 是可读的 —— 而正因为它可读且**读得稳**，才更容易被误当成备份路径。
第 1 条现在有本移植镜像上的实测支撑（见上一节的三次 md5 与数据分布）。
**一个稳定返回错误数据的 `/dev/mtd0` 比没有更危险**：它能通过任何稳定性检查。

### 2026-10-07 复盘：不是"读错"，是**读到了别的东西**

用 eMMC 做了参照物之后，这条才讲得通。全部**真机实测**，无写入、无擦除。

**参照物**：`/dev/mmcblk0` 前 4 MiB 可读，里面有同一份 Armbian 引导程序的
**eMMC 变体**：

```
rkimage magic 3b8cdcfcbe9f9d51 @ 0x8000     ← eMMC 的 LBA 0x40
FIT magic     d00dfeed         @ 0x17020
U-Boot TPL / U-Boot SPL        @ 0x12b6e / 0x2bd3b
```

同一块板、同一份 Armbian、只读、确认有效。

SPI dump 与它逐块对比（**只用非全零/全 `0xFF` 的块**，否则全零块会假匹配）：

```
非全零块交叉匹配（4 KiB，>=3000/4096 相同）：  0 对
SPI 里能搜到 eMMC 引导程序的 64 字节片段：      0 处（探了 39 处）
```

**SPI dump 里一个字节的 eMMC 引导程序都找不到。**

### ⚠️ 2026-10-08 补测：Armbian 内核也读不对，而且 dump 里没有 FDT

用**另一套内核**（Armbian 26.11.0 / Linux 6.18.54，SPI 可见为 `mtd0`，4096 KiB）复测：

```
同一块 64 KiB 连读两次：
  读1: 106b3534fbadf7612b2cf65ea2acb48c
  读2: b85c3f4fbb9caac7c148924a680f2f92      ==> 两次不同
strings -n 12 /dev/mtd0 | wc -l  ==> 0
```

**两次读结果不同**，而且**一条 ≥12 字符的字符串都没有**。所以：

1. ⚠️ **这不是 OpenWrt 内核的问题。** 两套完全不同的内核（6.12 与 6.18）都读不对，
   指向 SPI 读路径本身 —— pinctrl、时钟、驱动模型的某处。
2. ⚠️ **`recovery/spi-working-armbian.bin` 不能当参考物**（⚠️ **该文件已于 10-09 删除** ——
   一份已证明是垃圾的数据，留着比删掉更危险）。扫遍整份 4 MiB，
   **FDT magic（`d0 0d fe ed`）出现 0 次** —— 一份正常的 U-Boot 至少带 3 个 DTB。
   之前用它当"Armbian 引导程序的样子"是靠不住的。
3. ⚠️ **仍然缺的那份 ground truth**：SPI 上真实的 `idbloader` + `u-boot.itb`。
   U-Boot 的 `sf read` 是唯一已知的可靠读法，而进 U-Boot 命令行需要实物 TTL
   适配器接 UART2（1500000 8N1）。

| | SPI dump | eMMC 前 4 MiB |
|---|---|---|
| 可打印字符串（≥16 字符） | **109** | 238 |
| ≥12 字符字符串 | 147 | 341 |
| `U-Boot` 版本 banner | **0 处** | 3 处 |

**一份正确读回来的 U-Boot 必然带上自己的版本 banner** —— 串口第一行
`U-Boot TPL 2022.07_armbian` 就是从这块芯片读出来打在屏幕上的。整个 dump 里
连一个 `U-Boot` 字样都搜不到。

### 那 147 条"真实的 U-Boot 字符串"是什么？

**不是"部分读对"，是 DRAM 残留。**

证据是形状。RK3399 的 U-Boot FIT 里绝大多数字节是 `0x00`：

```
真实 rk3399 idbloader-spi.img   ff=1.4%   00=65.2%
SPI dump                       ff=87.8%  00=10.3%
```

位置和大小也对得上：

```
dump 0x00000000..0x00001000   全 0x00
dump 0x00002000..0x0001d000   全 0x00（108 KiB 连续零）
dump 0x000f3600               "…_set_clk\0rk3399_spi_set_clk\0dev_get_priv\0"
```

**U-Boot 从 SPI 起来后，把 108 KiB 零和自己的字符串表留在 DRAM 里；
Linux 的 SPI 读路径读不中芯片，把这些 DRAM 内容交了出来。** 字符串位置
"合理"，正因为它们**就来自 U-Boot 镜像**，而不是来自芯片的正确地址。

> ⚠️ 这纠正了早期的一个判断方向。"部分正确"曾被当作线索去查地址偏移。
> 实际是"部分正确的内容 + 完全错误的来源"，两者不能混谈。
> 曾按"读偏移"找到 7 个 64 字节命中点，看着像常数偏移；实测偏移是
> `0x8000/0xb000/0x12000/0x15000/0x1a000/0x1d000/0x20000` —— 不一致，
> 纯属偶然，**已作废**。

### 顺手排除的方向（都实测，不是推理）

| 方向 | 实测结果 |
|---|---|
| pinctrl 被抢 | **排除**。`pinmux-pins`：pin 39-42 = `ff1d0000.spi`，function `spi1-rx/tx/clk/cs0` |
| 频率不对 | **排除**（作为主因）。`spi-max-frequency` = `0x00989680` = 10 MHz，确已生效；10 与 108 MHz 都错且错法相同 |
| 分块大小 / DMA 路径 | **排除**。整片 md5 在 `bs=16/64/256/4096/65536` 下**完全相同** = `9346c99f…`；`mtd0` 与 `mtdblock0` 也相同。`bs=16` 走 PIO、`bs>=32` 走 VLD DMA，两条路径一致 |
| 字节级错位（采样沿错） | **排除**。与 eMMC 参照做 −8..+8 bit 位移相关，最好仅 6.5%（随机基线 0.4%）；半字节交换、位反转同为 5.1%。没有"错半位" |
| `&spi1` 总线选错 | **排除**。live DT `spi@ff1d0000` = 上游 `spi1`，`status=okay`，`reg=0xff1d0000/0x1000` |
| 驱动选错 | **排除**。`/sys/bus/spi/drivers/` 下只有 `rk8xx-spi`（6.12 里 rockchip SPI 新名）+ `spi-nor` + `spidev`，绑定正常 |

> ⚠️ **`od` 在这块板上不存在。** 早期用 `od -An -tx4` 读设备树二进制属性，全部输出为空 ——
> 看着像"`spi-max-frequency` 没写"，其实只是工具缺失；改用 `hexdump` 才读到值。
> **空输出不是证据。**

### 那为什么 U-Boot 读得对、Linux 读不对？

U-Boot 读得对（能起、能读 env），Linux 读不对 —— 而**硬件、pinctrl、时钟、
芯片都是同一个**。差别只能在 Linux 侧的读路径上。

⚠️ **具体卡在哪一步，未确认。** 上表六项已实测排除，仍未定位。
按本仓库规范明确标注为"未确认"，不编一个听起来合理的原因。

下一步能做的：

1. 用 **U-Boot 自己的 `sf read`** dump 同一片 SPI，作为字节级 ground truth。
   ⚠️ **这条 10-10 解除了阻塞：串口通了**（`COM4` @ 1500000 baud），
   进得了 U-Boot 命令行，所以上面这套在 U-Boot 侧逐条跑是可行的。
   目前参照物都是别的构建，比对只能到"0 处命中"这个粒度 ——
   **自读一次就能把它变成字节级 ground truth。**
2. 在 U-Boot 里逐项对照 `sf` 的时钟/模式与 Linux 侧，缩小差异范围。
3. `armbian-install` 可从 Armbian 侧写 SPI（见 [flashing.md](flashing.md)），
   但**这是写入操作，本次排查明确不做**。

### 仍然没查清的

`&spi1` 与 `spi-max-frequency` 已从"未确认"转为**已实测排除**（见上表）。
真正未确认的是：Linux 读路径与 U-Boot 读路径的具体差异点。

---

## SPI 现在可以写了（2026-10-09）

### ❌ 旧结论：Maskrom 写不了 SPI —— 观察对，机制错

本文前面（以及 `recovery-README.md`）一直写着「Maskrom `wl` 只写 eMMC，**不碰 SPI**」，
并据此推出「要改 SPI 上的引导程序，只有 Maskrom 这一条路」——同时又说这条路走不通。
**这两句不能同时成立，而它们并存了很久。**

准确的说法是：

> **`rkdeveloptool wl` 不选择介质。loader 选择。**

`rkdeveloptool db <loader>` 把一个 Rockchip loader 推给 SoC，**由 loader 决定后续命令
面对哪块存储**。所以同一个 `wl 0 <image>`：

| loader | `wl` 写到 |
|---|---|
| `rk3399_loader_v1.27.126.bin` | **eMMC** ← 本仓库一直用的是这个 |
| `rk3399_loader_spinor_*.bin` | **SPI NOR** |

⚠️ **这里有个不设防就一定会踩的坑：用错 loader 时 `wl` 会报"成功"。**
它确实成功写完了 —— 只是写到了另一块介质。没有任何错误、没有任何警告。
所以脚本 [`scripts/flash-spi.sh`](../scripts/flash-spi.sh) 会对 loader 名字做检查，
名字里没有 `spinor` 就拒绝执行。

### 为什么之前没试出来

因为**镜像本身是对的，缺的是 loader 和 payload**。本移植的 U-Boot defconfig 里
`CONFIG_ROCKCHIP_SPI_IMAGE=y`，U-Boot 构建**一直**在产出 `u-boot-rockchip-spi.bin`
（2212864 字节）—— 文件就在构建目录里，只是：

1. 从没被打包给 `rkdeveloptool`（`Build/InstallDev` 只装 `u-boot-rockchip.bin`）；
2. 从没被任何校验项看过；
3. 没人知道它和 eMMC 那个**不是同一个东西**。

### 两种容器不能互换

同一次 U-Boot 构建产出两个形状，**混用会停在 SPL 之后**（看起来像引导程序坏了，
而不是像文件选错了）：

| | `u-boot-rockchip.bin`（eMMC/SD） | `u-boot-rockchip-spi.bin`（SPI NOR） |
|---|---|---|
| 一级容器 | `rksd`，TPL+SPL 连续排列 | `rkspi`，**每 4 KiB 页只用前 2 KiB**，后 2 KiB 补零 |
| 大小 | `idbloader` 192512 B | `idbloader` 385024 B（正好 2 倍） |
| U-Boot 本体位置 | 字节 `0x800000`（LBA `0x4000`） | `CONFIG_SYS_SPI_U_BOOT_OFFS` = `0xE0000` |

`rkspi` 的 2 KiB/2 KiB 间隔是 **boot ROM 要求的**；U-Boot 源码
（`tools/rkspi.c`）自己都写着 *"Its rationale is unknown"*，但照样这么生成。

**已实测**（构建产物比对，不是推理）：

```
u-boot-rockchip-spi.bin 的前 0x5e000 字节，拆掉 2K/2K 间隔后
  == idbloader.img          逐字节相同          ← 证明是同一次构建的 rkspi 变体
0xe0000 处是 FIT 头 d00dfeed                    ← 与 CONFIG_SYS_SPI_U_BOOT_OFFS 一致
整个 2212864 字节的镜像里含 rockchip,sdram-params  ← 带着这次 DRAM 修复
```

> 这正是 [`scripts/assert-spi-boot-image.py`](../scripts/assert-spi-boot-image.py)
> 断言的东西。**它有负控制**：喂 eMMC 那个容器进去必须失败，
> 喂一个错的 `--u-boot-offset` 也必须失败。两者都实测过会失败。

### 怎么验证：写前确认介质，写后读回比对

这两步是分开的，因为它们各堵一个洞。

**① 写前 —— `rkdeveloptool cs 9` 确认介质**

`rkdeveloptool` 自己记着当前是哪块存储，并且能切：

```
rkdeveloptool cs [1=EMMC, 2=SD, 9=SPINOR]
```

源码里（`main.cpp` `change_storage`）先 `RKU_ChangeStorage()` 再
`RKU_ReadStorage()` **读回来核对**，切换没生效就报
`Storage 9 is not available`。**这一步把"我现在对着哪块介质"从假设变成事实。**

⚠️ 它还顺带给了一条**备用的路**：如果 spinor loader 版本选错，
可以推普通 eMMC loader 再 `cs 9`。**去 SPI 有两条路**，所以 loader 猜错不是死局。

**② 写后 —— `rkdeveloptool rl` 读回来逐字节比对**

`wl` 返回 0 **不是**证据。读回走的是 ROM loader，不是 Linux，
所以**不受本文上面那个"Linux 读不对这块 SPI"的问题影响** ——
`rl` 是这块芯片第一次能当 ground truth 的读法。

⚠️ 只比**payload 那段**（`stat -c%s` 个字节），不带后面 0xFF 填充：
擦除态的单元也读出 0xFF，比它既抓不到任何东西，又让比对结果取决于芯片上电方式。

> ⚠️ 这同时意味着 **Linux 侧"读不对 SPI"这件事至今仍未定位**，
> 而 `rl` 现在给出了绕开它的办法。两者不必一起解决。

### ⚠️ 没有在硬件上做过

**上面全部来自构建产物、defconfig、U-Boot 源码和 binman 的 map 文件。
本移植一次 SPI 写入都没执行过。**

- 未验证：`--write` 路径本身、loader 版本、SPL 实际从 `0xE0000` 取到 U-Boot。
- ⚠️ **loader 版本没定。** Radxa 为 ROCK Pi 4 发的是 `v1.15.114`，并说明 **v1.72
  之后的板（他们点名 ROCK 4C+）需要 `v1.20.126`**。本板是**早期 V1.73 带 4 MB NOR**，
  属于哪一类**没有按版本号确认过**。脚本不猜，`--loader` 是必填参数。
- 失败不致命：SPI 现在**本来就没有可引导的东西**（见上面那节），
  Maskrom 始终可用，eMMC 上的整包也是独立写的。
- ⚠️ **但反过来要注意**：一旦 SPI 上**有了**可引导的东西，SPI 排第一，
  所以半写的引导程序会在 eMMC 之前就把板子拦住。**读回不一致时不要断电。**

### 怎么用

```bash
scripts/flash-spi.sh --check                    # 只读：验镜像，不碰设备
scripts/flash-spi.sh --plan                     # 再打印将要执行的命令
scripts/flash-spi.sh --write --loader <spinor-loader>   # 真写，要手输 YES
```

⭐ **进 maskrom 不必短接 SPI CLK（40-pin 23/25）** —— 2026-10-10 实测按住板上的 Maskrom
或 Recovery 键即可，重复多次；`log/tty19.txt` 有完整串口记录。

⚠️ **但短接那一步必须保留为兜底，理由在 2026-10-11 变清楚了：按键是由 U-Boot proper
触发的，短接是由 ROM 触发的。** 引导程序跑不起来时**按键能不能救回来没有测过**。
详见本文开头「2026-10-10：按板上的键能进 maskrom」那一节。

---

## ⚠️ `Card did not respond to voltage select! : -110` —— 每次启动都出现，**无害**

这行在**每一份**串口抓取里都有，而且是 `log_err`，看着像故障。**它不是。**

**是哪个设备：`mmc@fe320000`，也就是板载 microSD 卡槽，当前是空的。**

```
MMC:   mmc@fe310000: 2, mmc@fe330000: 0      ← 初始化时的列表
...
Scanning bootdev 'mmc@fe320000.bootdev':
Card did not respond to voltage select! : -110     ← 就在它后面
Scanning bootdev 'mmc@fe330000.bootdev':
  1  script       ready   mmc   1  mmc@fe330000.bootdev.part /boot.scr   ← 真正引导它的
```

三个控制器的身份（`rk3399-rock-pi-4.dtsi` 与板级 dtsi）：

| 地址 | 别名 | 是什么 | 状态 |
|---|---|---|---|
| `fe310000` | `sdio0` | **WiFi 芯片**（`brcmf: wifi@1`，`mmc2 = &sdio0`） | ✅ 起来了，相位 231 |
| `fe320000` | `sdmmc` | **板载 microSD 卡槽**（有 `sdmmc_cd` 卡检测脚，`mmc1 = &sdmmc`） | ⚠️ **空的** |
| `fe330000` | — | **eMMC**（`mmc0`，HS400） | ✅ 从它引导 |

**源码路径**（`drivers/mmc/mmc.c:2968`）：`sd_send_op_cond()` 超时返回 `-ETIMEDOUT`
（就是 `-110`），于是再试 MMC 的 `mmc_send_op_cond()`，也失败 → 打印这行并返回
`-EOPNOTSUPP`。**槽里没卡就是这条路径**，不是出错。

⚠️ **一次启动里它出现三次**（`efi_mgr` 扫描两次 + `fe320000` 扫描一次），因为每次
重新枚举 bootdev 都会重新探测一遍。**次数不是异常指标。**

⚠️ **同一段里另外两句也是同一回事**，一并记下，免得下次重新怀疑：

| 行 | 含义 |
|---|---|
| `Cannot persist EFI variables without system partition` | 本镜像是 ext4 + DOS/MBR，没有 EFI 系统分区 |
| `Loading Boot0000 'mmc 0' failed` / `EFI boot manager: Cannot load any image` / `Boot failed (err=-14)` | EFI 引导尝试失败，**然后正常回落到 `script` bootdev**，`/boot.scr` 照常找到 |

⚠️ **反过来看，这行其实是一条有用信息**：它说明**板载 SD 卡槽这条路至今没被 U-Boot
走过** —— 和 [hardware.md](hardware.md) 里「板载 SD 卡槽这条路径至今未验证」是同一件事。

⚠️ **未实测**：插一张卡进去这行会不会消失。**能验证它的只有插卡那次**，
所以这里只把它记成「空槽的正常路径」，没写成「已验证插卡后消失」。

---

## 当前状态

| | 状态 |
|---|---|
| Maskrom 恢复流程 | ✅ **已在真机验证**（官方 `rk3399_loader`） |
| **Maskrom 写 eMMC 整包** | ✅ **已验证**（`rkdeveloptool wl 0 <镜像>`）。⚠️ **不碰 SPI 是因为用的是 eMMC loader**，不是工具的限制 —— 见[上面那节](#spi-现在可以写了-2026-10-09) |
| ⚠️ **Maskrom 写 SPI** | ⚠️ **未上机**。payload 已就绪并通过断言（`u-boot-rockchip-spi.bin`），loader 必须换 spinor 的 |
| ⚠️ SPI 上是否还有可引导镜像 | ❌ **没有** —— `Trying to boot from BOOTROM` 说明 ROM 在 SPI 上没找到东西 |
| ⚠️ **当前唯一恢复路径** | **只有 Maskrom** —— 不是因为 SPI 写不了（[SPI 现在可以写了](#spi-现在可以写了-2026-10-09)），而是因为 **SPI 上现在是空的** |
| 本移植的 U-Boot 是否跑过 | ✅ 跑过，而且现在 **24 次连续启动零 panic**（四个构建，各 6 次） |
| `rockchip,sdram-params` 修复 | ✅ **确认生效**（TPL 打出两通道各 2048MB） |
| OpenWrt 从 eMMC 启动 | ✅ 已验证（rootfs 挂载 + 到 shell） |
| 从运行中系统读写 SPI | ❌ **现在连 `/dev/mtd*` 都没有**（见上面那一节） |
| Linux 读不对 SPI 的确切原因 | ❌ 未确认，且**现在多了一层：SPI 根本不被探测** |
| 上游 PR | ❌ **仍然不要提** —— ⚠️ **10-09 把差距拉大了而不是缩小**：原来最像样的那条假说（「轨停在 0%」）被自己的实验否掉了，剩下的是一条更窄、仍未证实的（「占空比从来没被写过」）。加上物理负载未知，**没有这些，任何人都无法复现，也就无法判断那个电压到底必不必要** |

### ⚠️ 本移植的 U-Boot 的稳定性问题已经过了判据

| 构建 | 启动次数 | panic | 备注 |
|---|---|---|---|
| base | 6 | **3** | 50% |
| +0103 | 2 | **2** | 0103 修不好任何东西，**已删除** |
| +0103 +vdd_log | 6 | **0** | 达到判据 |
| +vdd_log（删掉 0103） | 6 | **0** | **见 postmortem** |
| +vdd_log @ **800mV** | 6 | **0** | ❌ **预测「会崩」是错的**（10-09 23:07）。占空比 0% 也是好的 |
| +vdd_log @ **1100mV** | 6 | **0** | ✅ 相位继续升到 232–234（10-10）。**判别器命中** |
| Armbian U-Boot | 6 | 0 | 对照组 |

⚠️ **相位现在是一条量出来的直线**：0% → 211.5、25% → 222.2、50% → 232.5，
**残差 ≤ 0.1 phase / 30 次启动**（10-10）。**这条轨确实在移动 SDIO 的时序余量。**
⚠️ **而 269 不在这条线上** —— 反推需 1620 mV，超出上限 220 mV，**修复前的状态不是
这条轨上的任何电压**。

✅ **10-10 之后根因已定位并实测确认**（U-Boot 提示符读 PWM2：`period=1207`
`duty=603` = 49.96%，正是配置的占空比 → **U-Boot 自己写的**；而缺属性时 U-Boot 会打印
`Cannot find regulator pwm init_voltage`，**这行只出现在 269 的抓取里**）。
⚠️ **但「达到判据」与「根因找到」仍然是两件事，且两者可以分别成立** ——
判据是稳定性判据，根因是机制判据。
唯一确定下来的是故障形态：**三处全部只差一个比特**（两处内核正文、一处函数指针）。
机制那条 —— 「轨停在 0% 占空比」—— **被自己的判别实验否掉了**（专门构建 0%，
6/6 干净）。剩下的「占空比从来没被写过」**只是相容，未经证实**，
而且 SDIO 相位**跟着写入的值单调走**（0% → 210–213，25% → 215–226），
这一点恰恰与「只要写过就行」不相容。

⚠️ **因果链没有闭合**：没有任何一环把这条轨连到 `rk3x_i2c_irq` 附近的崩溃点，
设备树也没描述这条轨的物理负载。

⚠️ **而且故障本来是间歇性的**：24 次只说明「在 24 次里没出现」，不是失败率为 0。

### ⚠️ 一个被我自己的断言判死的干净启动

第一次跑删除 0103 后的矩阵时，6 轮里第 6 轮报了 FAIL：

```
phase=215  MemTotal=3961704 kB  boot_id=89f84ba7-…
[VFS: Mounted root (ext4 filesystem) on device 179:2.
❌ FAIL  phase 215 -- neither the 22x band nor 269
```

**那次启动是干净的** —— 新 `boot_id`、`MemTotal` 一致、root 挂上、dmesg 异常 0 处。
FAIL 来自我写的那条相位区间断言。

⚠️ **同一条断言已经错三次了**：`== 221` 被 224 打掉，`220-224` 被 225 打掉，
`22[0-9]` 被 215 打掉。同一份镜像 12 次启动的实测值是：

```
221 224 225 223 223 223 226 226 222 224 222 215
```

**跨度 11，而且完全覆盖 Armbian 的 220-223。** 它是时序余量的**测量值**，不是标识符。

⚠️ **一条因为错误理由失败的检查，和一条因为错误理由通过的检查一样糟。**
现在脚本只记录这个值，**唯一作为判据的是 269**（那是所有 vdd_log 之前的构建都读到的值，
远在这个区间之外）。

---


## 相关文档

- [hardware.md](hardware.md) — 硬件事实、板型辨识、按键、介质
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 变砖的根因（缺 DRAM 参数）与修复
- [postmortem-dram-instability.md](postmortem-dram-instability.md) — 修好之后发现的随机 panic
- [flashing.md](flashing.md) — 恢复流程的操作步骤
- [device-tree.md](device-tree.md) — 内核与 U-Boot 的设备树策略