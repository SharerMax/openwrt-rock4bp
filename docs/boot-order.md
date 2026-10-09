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

⚠️ **而启动顺序是 SPI 优先**（见本文开头，`rkdeveloptool` 实测过）。既然 SPI 排第一，
ROM 却直接落到 eMMC，**说明 SPI 上没有可引导镜像** —— SPI 那边本来就没有（或早已失效）。

⚠️ **机制补充（10-09）**：我这一节原先把原因写成「Maskrom `wl` 只写 eMMC，不碰 SPI」。
**那句的观察是对的，机制是错的**：`wl` 并不选择介质，**是 loader 选择的** ——
换成 `rk3399_loader_spinor_*` 就写 SPI。详见下面「SPI 现在可以写了」一节。
**SPI 上现在是空的**这个结论不受影响。

⚠️ **后果：当前唯一的恢复路径是 Maskrom。** 没有 TTL 适配器时，SPI 上有没有东西都不影响
TPL/SPL 的可见性，所以之前没人留意它能否引导 —— 但它一旦被写成"备用恢复路径"，
就会在真需要的时候失效。

⚠️ **结论的来源是 ROM 的输出，不是我们的推断。** 整节只有一处依赖推断
（"启动顺序是 SPI 优先"），而那一条已被实测固定。

---

## ⚠️ 2026-10-08：SPI 现在根本不被探测，和文档里记的不一样

⚠️ **本文后面那一节说 `/dev/mtd0` 出现过、`rockchip-spi` 驱动已绑定。
今天（10-08）在 OpenWrt 25.12.5 / 6.12.94 上复现不出来 —— 现在压根没有 `/dev/mtd*`。**
下面先记实测，再解释为什么「记的和测的不一致」这件事本身还没结清。

### 实测（板子可达，root，无密码）

```
/dev/mtd*                    不存在
/sys/bus/platform/devices/ff1d0000.spi/driver   不存在（未绑定）
/sys/bus/platform/drivers/   有 rockchip-spi（驱动注册了，但没绑上）
dmesg: [18.411357] platform ff1d0000.spi: deferred probe pending: (reason unknown)
```

**设备树是对的**，不是节点写错：

```
spi@ff1d0000   status=okay   children: ... flash@0 ...     ← spi1 在 ff1d0000，enabled
```

### 机制：一次**静默**的 defer

`drivers/spi/spi-rockchip.c:877`：

```c
ctlr->dma_tx = dma_request_chan(rs->dev, "tx");
if (IS_ERR(ctlr->dma_tx)) {
        if (PTR_ERR(ctlr->dma_tx) == -EPROBE_DEFER) {
                ret = -EPROBE_DEFER;          /* 直接返回，没有任何 dev_err */
                goto err_disable_pm_runtime;
        }
        dev_warn(rs->dev, "Failed to request TX DMA channel\n");
```

`dmas` / `dma-names = "tx", "rx"` 是**上游 `rk3399-base.dtsi:865` 就有的**，指向
`&dmac_peri`（`ff6d0000`，compatible `arm,pl330`）。DMA 通道拿不到就整条 probe 挂起，
而这条路径**不打日志** —— 所以只有 deferred probe 超时后那句 `(reason unknown)`。

⚠️ **本移植没有引入这个依赖。** `overlay/kernel/rk3399-rock-4b-plus.dts` 的 `&spi1`
块只写了 `status = "okay"` 和 `flash@0`，没碰 `dmas`。

### 同批挂起的三兄弟

```
[18.409961] amba ff6d0000.dma-controller: deferred probe pending: (reason unknown)
[18.410677] amba ff6e0000.dma-controller: deferred probe pending: (reason unknown)
[18.411357] platform ff1d0000.spi:         deferred probe pending: (reason unknown)
```

`/sys/bus/amba/devices/` 里两个 PL330 都在，`/sys/bus/amba/drivers/dma-pl330` 也注册了，
**但都没绑定**。所以 SPI 的挂起是在它们的**下游**，不是并列的三个独立问题。

### 内核配置：不是本移植改的

```
CONFIG_SPI_ROCKCHIP=y
CONFIG_PL330_DMA=y                 → drivers/dma/pl330.o 已编译
# CONFIG_AMBA_PL08X is not set
```

`amba-pl08x.c` 没有被编进去，但 `pl330.c` 编了 —— **两条路径都能驱动 `arm,pl330`，
所以缺 `AMBA_PL08X` 本身不是原因。**

⚠️ 而 `0101-configs-add-rock-4b-plus-rk3399-defconfig.patch` 里的 `CONFIG_*`
**全是 U-Boot 的**（`CONFIG_SYS_LOAD_ADDR`、`CONFIG_DEBUG_UART_BASE`……）。
**本移植没有改过内核配置**，所以上面的组合完全来自 OpenWrt 上游的 rockchip config。

### ⚠️ 未结清：文档里那次 `/dev/mtd0` 到底是在哪套系统上测的

本文后面那节写「两套完全不同的内核（6.12 与 6.18）都读不对」，言下之意 6.12 那边
`mtd0` 是存在的。**今天的 6.12.94 复现不出来。**

两种可能，我还没有证据分辨：

| | 说法 | 需要什么才能定 |
|---|---|---|
| A | 当时那次其实是在 **Armbian** 上测的，文档把两套系统的结果混成了一句 | 回看当时的命令与输出 |
| B | OpenWrt 6.12 **确实**曾经探测成功，后来某次重建改了 config 或 DTS | 逐版本二分构建 |

⚠️ **所以「SPI 曾经可见」这个前提，目前是不成立的。** 后面那节的结论
（读出来的数据是错的、不能拿来做备份）**仍然有效** —— 但它是在「能读到」的前提下得出的，
而今天连「能读到」都不成立了。**两层都要修，不能只认一层。**

### 如果要修，最小改动是去掉 `dmas`

SPI 用 PIO 完全能工作，DMA 只是加速。所以在本移植的 `&spi1` 块里：

```dts
&spi1 {
	status = "okay";
	/delete-property/ dmas;
	/delete-property/ dma-names;

	flash@0 { ... };
};
```

没有 `dmas` 时 `dma_request_chan()` 拿不到 provider 会返回 `-ENODEV` 而不是
`-EPROBE_DEFER`，`spi-rockchip` 会打一条 `Failed to request TX DMA channel` 警告
然后**继续用 PIO** —— 也就是绕开这条静默挂起的路径，而不是再加一层猜测。

⚠️ **⚠️ 但先别急着改。** 本文的结论是：**这块 SPI 就算探测成功，读出来的也是错的**
（0 个 FDT magic、0 条 U-Boot 字符串、整片数据与芯片内容不符）。
**一个会给出错误数据的 `/dev/mtd0` 比没有更危险** —— 它能通过「读稳定吗」这类检查，
备份下来的却不是芯片内容。

所以顺序应该是：先把 PL330 那条挂起链查清楚（为什么两个 DMA 控制器也不绑），
再决定是恢复 DMA 还是退到 PIO。**直接改 SPI 只会把「静默失败」换成「静默给出错误数据」。**

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

进 Maskrom 仍然要先短接 SPI CLK（40-pin 23/25），理由不变：SPI 排第一。

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