# 启动顺序、SPI 引导，以及那块读不对的 SPI Flash

这块板的三件事必须放在一起看，否则每件单独看都会得出错误结论：

1. **SPI → eMMC → SD 的启动顺序**，决定了任何"绕过 SPI"的手段都无效。
2. **镜像自带引导程序**，所以 SPI 不是必需的 —— 但正因为它在最前面，它挡路。
3. **Linux 读不到这块 SPI 的正确内容**，所以不能从运行中的系统备份或写入它。

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

2026-10-06 用 Maskrom 把整包写进 eMMC（`rkdeveloptool wl 0 <镜像>`），SPI 上那份
Armbian 引导程序被绕过，**镜像自带的那份在真机上执行了**。

结果分两半：

| | 结论 |
|---|---|
| ✅ `rockchip,sdram-params` 修复**生效** | TPL 打出完整 LPDDR4 训练过程，两通道各 2048MB |
| ❌ 但**会随机 panic** | 6 次启动 3 次内核 panic，三次都是"函数指针被指向垃圾地址" |

决定性对照：**同样的内核、同样的 dtb（哈希逐字节相同）、同样的 rootfs**，
Armbian 的 TPL 6 次零 panic，本移植的 TPL 3 次 panic —— 唯一变量是 TPL。

所以根因在 **DRAM 初始化**这一层。完整证据链见
[postmortem-dram-instability.md](postmortem-dram-instability.md)。

⚠️ **原来的推断方向反了。** 早先推断"这份引导程序只对不贴 SPI 的量产板有意义，而
那类板恰好是唯一没被验证过的组合"—— 现在它验证过了，结论是**能启动但会崩**。
所以问题不是"能不能引导"，而是"DRAM 参数是否有缺陷"。

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
   本次没做成：**没有串口接入**（UART2 1500000 8N1 需实物 TTL 适配器），
   进不了 U-Boot 命令行。这是**最有价值**的下一步 —— 目前参照物都是别的构建，
   比对只能到"0 处命中"这个粒度。
2. 在 U-Boot 里逐项对照 `sf` 的时钟/模式与 Linux 侧，缩小差异范围。
3. `armbian-install` 可从 Armbian 侧写 SPI（见 [flashing.md](flashing.md)），
   但**这是写入操作，本次排查明确不做**。

### 仍然没查清的

`&spi1` 与 `spi-max-frequency` 已从"未确认"转为**已实测排除**（见上表）。
真正未确认的是：Linux 读路径与 U-Boot 读路径的具体差异点。

---

## 当前状态

| | 状态 |
|---|---|
| Maskrom 恢复流程 | ✅ **已在真机验证**（官方 `rk3399_loader` + Armbian 引导程序） |
| **Maskrom 写 eMMC 整包** | ✅ **已验证**（`rkdeveloptool wl 0 <镜像>`），且**不碰 SPI** |
| SPI 上现有的引导程序 | Armbian U-Boot（救回时刷的，可用，**6 次启动零 panic**） |
| 本移植的 U-Boot 是否跑过 | ✅ **跑过了** —— 但 **6 次启动 3 次内核 panic** |
| `rockchip,sdram-params` 修复 | ✅ **确认生效**（TPL 打出 `lpddr4_set_rate` + 两通道各 2048MB） |
| OpenWrt 从 microSD 启动 | ✅ 已验证（Armbian U-Boot 引导，稳定） |
| OpenWrt 从 eMMC 启动 | ✅ 已验证（tty8，本移植 U-Boot，但那次之后又崩了） |
| 从运行中系统读写 SPI | ❌ 不可能（读不对，无法验证） |
| Linux 读不对的确切原因 | ❌ **未确认**（2026-10-07 排除 6 项后仍未定位；下一步是 U-Boot `sf read` 取 ground truth） |

### ⚠️ 本移植的 U-Boot 会导致随机 panic

**镜像自带的那份引导程序已经在真机上执行过，DRAM 参数修复确实生效** —— 但同一份 TPL
在 6 次启动里造成 3 次内核 panic（三次都是"函数指针被指向垃圾地址"）。

决定性对照：**同样的内核、同样的 dtb（哈希逐字节相同）、同样的 rootfs**：

| 引导程序 | 启动次数 | 挂上 root | panic |
|---|---|---|---|
| Armbian U-Boot | 6 | 2 | **0** |
| 本移植 U-Boot | 6 | 1 | **3** |

所以根因在 **DRAM 初始化**这一层，不是软件逻辑。完整证据链见
[postmortem-dram-instability.md](postmortem-dram-instability.md)。

⚠️ **风险的分布变了。** 早先写"风险在不贴 SPI 的量产板上，那类板只能靠镜像自带那份"
—— 现在那份确实能启动，但**不稳定**。所以问题不再是"能不能引导"，而是
"引导程序的 DRAM 参数是否有缺陷"。

**SPI 在这块板上仍然是保护**（Armbian 那份稳定可用），但**不能再把它说成"唯一的
兜底"** —— 兜底本身也有 DRAM 稳定性问题，只是它没暴露。

---

## 相关文档

- [hardware.md](hardware.md) — 硬件事实、板型辨识、按键、介质
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 变砖的根因（缺 DRAM 参数）与修复
- [postmortem-dram-instability.md](postmortem-dram-instability.md) — 修好之后发现的随机 panic
- [flashing.md](flashing.md) — 恢复流程的操作步骤
- [device-tree.md](device-tree.md) — 内核与 U-Boot 的设备树策略