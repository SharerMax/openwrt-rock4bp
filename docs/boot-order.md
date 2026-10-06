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

### 但它从未被执行过

在**贴了 SPI 的板子**上，这份引导程序一次都没被运行过 —— SPI 排第一，读到 SPI 就不看
别处了。

所以"镜像自带引导程序"目前**只对不贴 SPI 的 V1.73 量产板有意义**，而那类板恰好是
**唯一没被验证过的组合**。

⚠️ 这也是本移植的 U-Boot 至今未在真机运行过的根本原因，见
[postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) 的「为什么这个未验证项就停在这里」。

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

### 仍然没查清的

我们把 `spi-max-frequency` 定成 10 MHz（当时判断"保守"），上游 rock-pi-4b 用 108 MHz。
**两个频率都读不对**，所以频率大概不是主因 —— 但没有更多证据，不下结论。

`&spi1` 是对的：所有 rk3399 板子（含上游 `rk3399-rock-pi-4b.dts`）都用它，不是总线
选错。

---

## 当前状态

| | 状态 |
|---|---|
| Maskrom 恢复流程 | ✅ **已在真机验证**（官方 `rk3399_loader` + Armbian 引导程序） |
| SPI 上现有的引导程序 | Armbian U-Boot（救回时刷的，可用） |
| 本移植的 U-Boot 是否跑过 | ❌ **一次都没有** |
| 为什么没跑 | 三条路都实测排除，只剩 Maskrom 写 SPI —— **决定不写** |
| OpenWrt 从 microSD 启动 | ✅ 已验证（用 Armbian 的 U-Boot 引导） |
| 从运行中系统读写 SPI | ❌ 不可能（读不对，无法验证） |

**风险落在哪**：这块板不受影响 —— SPI 里是能用的引导程序，OpenWrt 已实测从 microSD
完整启动。**⚠️ 风险在不贴 SPI 的 V1.73 量产板上** —— 那类板 boot ROM 没有 SPI 可退，
只能依赖镜像自带的那份，而那份恰好是唯一没跑过的东西。

**SPI 在这块板上既是麻烦（挡路）也是保护（提供一份能用的引导程序）。**

---

## 相关文档

- [hardware.md](hardware.md) — 硬件事实、板型辨识、按键、介质
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 变砖的完整排查记录
- [flashing.md](flashing.md) — 恢复流程的操作步骤
- [device-tree.md](device-tree.md) — 内核与 U-Boot 的设备树策略