# U-Boot 变砖：DRAM 初始化失败

2026-10-06。这块板子现在起不来。本文记录症状、排查过程（**包括走错的岔路**）、
根因、修复，以及哪些部分已验证、哪些没有。

恢复步骤在 `FLASHING.md` 第 10 节，不在本文。

---

## 症状

串口只有三行，然后就再无输出：

```
U-Boot TPL 2025.10-OpenWrt-r33051-f5dae5ece4 (Jun 29 2026 - 12:59:20)
rk3399_dmc_of_to_plat: Cannot read rockchip,sdram-params -1
DRAM init failed: -1
Trying to boot from BOOTROM
Returning to boot ROM...
```

**没有 SPL banner，没有 U-Boot banner。** 复现两次，完全一致 —— 同一个 TPL 二进制
（同样的版本串、同样的构建时间戳 `Jun 29 12:59:20`），同一个电源和同一根线。

`-1` 是 `FDT_ERR_NOTFOUND`：`dev_read_u32_array()` 在 TPL 的设备树里找不到
`rockchip,sdram-params`。TPL 是**唯一**能在 DRAM 未初始化时运行的代码，它一退出，
后面就没有执行环境了。

## 为什么换个介质救不了

RK3399 的启动顺序是 **SPI Flash → eMMC → SD**。SPI 在最前，所以
**SPI 里只要有一个起不来的 U-Boot，后面介质上的系统再好也轮不到。**

这点决定了故障的性质：它不是一个"系统坏了"的问题，而是"引导链最上游坏了"，
而最上游恰好是唯一不能从系统内部改写的介质。

---

## 排查过程

### 岔路一：先怀疑 eMMC 的 `dd`

`dd` 是故障前最后一步操作，直觉上它最可疑。

排除依据：
- 失败点在 DRAM 初始化，**远早于任何存储访问**。TPL 还没走到读 eMMC 那一步。
- `dd` 本身已校验：整盘 sha256 与镜像 sha256 一致。
- 移除 U 盘后故障依旧 —— 而 U 盘在启动顺序里排在 eMMC 之后，SPI 仍在最前。
- 同一份 TPL 二进制在此前 6 次启动里都正常起来了，所以 TPL 本身不是变量。

### 岔路二：怀疑 SPI 内容损坏

SPI 的 env 区本来就有坏 CRC（`bad CRC, using default environment`），
这看起来像"这块 SPI 有坏块"的证据。

排除依据：BootROM 已经**成功**把 TPL 加载进来并跑起来了（版本串打印出来了）。
能把 TPL 跑起来，说明 SPI 的内容是可读的。CRC 坏的是 env，不是引导代码。

### 岔路三：怀疑供电

同一个电源、同一根线，此前 6 次都正常。仍然做了完整断电放电再试，结果一致。

### 岔路四：⚠️ 认为"Armbian 镜像里没有引导程序"——**这个结论是错的**

这一步走偏了最有价值，所以单独记。

当时的推理是：eMMC 上原本装着可用的 Armbian，它一定有过能用的引导程序；
现在 eMMC 被覆盖了，引导程序也一起没了；SPI 那份起不来；Armbian 镜像文件在手 ——
那么从镜像里提取一份出来写进 SD 卡就能救。

**实际只看了镜像的偏移 0。** 偏移 0 确实只有 MBR 和一片零，看起来"什么都没有"。
于是得出"Armbian 镜像里根本没有引导程序"，并据此把恢复方向定为
**必须从外部另找一份可用的 RK3399 引导程序**（当时考虑的是去下 Armbian 的
`rockchip-linux-bootloader` 包，或者干脆去 clone `radxa/u-boot` 自己编）。

后来在核对引导程序位置时才发现：

```
Armbian 镜像偏移 0x8000:  3b 8c dc fc be 9f 9d 51  eb 30 34 ce  24 51 1f 98
我们 idbloader.img 开头:  3b 8c dc fc be 9f 9d 51
```

**头 8 字节完全一致。** 也就是说 Armbian 的引导程序就在镜像的字节 `0x8000` 处 ——
也就是 **LBA 0x40**，正是 RK3399 boot ROM 找 idbloader 的位置，也正是本移植
`defconfig` 头部注释里写的那句 *"Boot flow: idbloader.img at LBA 0x40,
u-boot.itb at LBA 0x4000"*。我只是查错了地方。

这条岔路的代价不是浪费时间，而是**方向性错误**：它把"修复本移植的 U-Boot"
换成了"去外部找一个能用的"，而后者更慢、更不可靠，而且绕过了真正的问题
（见下一节）。

**教训**：判断"某个东西不存在"之前，确认查的位置是不是它该在的位置。
偏移 0 是最容易被查、也最容易被误信的位置。

### 岔路五：⚠️ 更根本的一条 —— 我们自己的镜像其实也自带引导程序

上面那条岔路是关于 Armbian 镜像的。**同一个错误结论，本文作者对自家镜像也犯过。**

`README.md` 和 `FLASHING.md` 当时都写着"镜像里不含 TPL/SPL/idbloader —— SPI 上已有
U-Boot，够了"。这句话**也是没查就写的**，而且方向恰好相反。

实际去查自家镜像：

```
byte 0x080000 (LBA 0x40)     rkimage 头          ← 引导程序
byte 0x800000 (LBA 0x4000)    d00dfeed (FIT)      ← U-Boot 本体，SPL 就是来这里找的
```

这是 OpenWrt rockchip 镜像机制**本来就有的行为**：

```
target/linux/rockchip/image/Makefile
  PADDING=1 gen_image_generic.sh ... 32768                  # 留 32 MiB
  dd if=$(UBOOT_DEVICE_NAME)-u-boot-rockchip.bin of=$@ seek=64 conv=notrunc
```

包也一直在装 `$(BUILD_VARIANT)-u-boot-rockchip.bin` 到 `STAGING_DIR_IMAGE`，而
`UBOOT_DEVICE_NAME` 的默认推导 `$(lastword $(subst _, ,$(1)))-$(SOC)` 对
`radxa_rock-4b-plus` 正好给出 `rock-4b-plus-rk3399` —— 就是我们的 U-Boot 变体名。

**这件事本该早就知道，因为它改变了 SPI 的地位**：镜像既然自带引导程序，
**SPI 就不是必需的**，它只是"排第一"而已。它挡路是真的（那次变砖），但它不是必需的。

同一次检查还查出：镜像里内嵌的那份是 **17:33 构建的**，而修复后的引导程序是
**18:40 重建的 —— 镜像里是坏的那份**。也就是说，修好构建树之后镜像并不会自动更新，
断言必须打在镜像上（`build.sh` 现在的 3 条 image 断言就是为这件事加的）。

> 判断"某个东西不存在"之前，先确认查的位置对不对；判断"某个东西存在"也一样。
> 这两次都是**没查就写**，而两次的结论方向相反 —— 一次把恢复引向外部，
> 一次让人以为镜像不自足。

---

## 根因

U-Boot 会按板名去找一个板级设备树：

```
arch/arm/dts/rk3399-rock-4b-plus-u-boot.dtsi
```

**这个文件不存在。** 而 `scripts/Makefile.lib` 里的回退逻辑是这样的：

```make
u_boot_dtsi_options = $(strip $(wildcard <board>-u-boot.dtsi) \
                       $(wildcard $(CONFIG_SYS_SOC)-u-boot.dtsi) \
                       $(wildcard $(CONFIG_SYS_CPU)-u-boot.dtsi) \
                       $(wildcard $(CONFIG_SYS_VENDOR)-u-boot.dtsi) \
                       $(wildcard u-boot.dtsi))

# We use the first match to be included
dtsi_include_list = $(notdir $(firstword $(u_boot_dtsi_options)))
```

**这是优先级链，只取第一个命中，不是并集。** 板级文件不存在，第一个命中就成了
`$(CONFIG_SYS_SOC)-u-boot.dtsi`，即 `rk3399-u-boot.dtsi`。

那份通用文件提供 `binman` 节点和 `bootph-*` 标记，所以构建能过；
但它**不提供 `rockchip,sdram-params`**。TPL 于是拿不到 DRAM 参数，直接退出。

判据（同一棵 U-Boot 源码树里的两个构建）：

| | `u-boot.dtb` | `rockchip,sdram-params` |
|---|---|---|
| `nanopc-t4`（能工作，出货目标） | 96560 B | **有** |
| `rock-4b-plus`（本移植） | 90840 B | **没有** |

差 5720 字节，就是那个参数块的大小。`grep` 全树所有 rk3399 的 `.dts`/`.dtsi`，
**没有一个**自带这个属性 —— 它只存在于 `arch/arm/dts/` 下的板级文件里。

U-Boot 里每一个 RK3399 板子都有这个文件：`rock-pi-4a`、`rock-pi-4c`、
`rock-4c-plus`、`rock-4se`、`nanopc-t4`。**所以它们都能起，我们不能。**

### 为什么构建一声不吭

这是这次事故真正昂贵的地方。

- 构建返回 0，没有 warning，没有失败的 target。
- `idbloader.img` **正常产出**，180224 字节，大小完全正常。
- `scripts/build.sh` 当时那 9 项校验**全过**。

因为所有既有校验问的都是"文件在不在、大小对不对、内容是不是这个项目要的"，
**没有一个问"这块板子能不能靠它启动"**。

于是这个缺陷的暴露条件变成了：把这份引导程序刷进 SPI。而一旦刷进去，
板子就再也无法写入替换 —— 因为写 SPI 需要 Maskrom，而 Maskrom 又要先短接
SPI 引脚（因为 SPI 里的东西会抢先接管）。**缺陷和恢复手段，被同一个原因锁住了。**

---

## 修复时的第二个坑

第一版修复只补了 DRAM 参数，构建**改挂在别的地方**：

```
binman: Device tree './u-boot.dtb' does not have a 'binman' node
```

原因就是上面那个"只取第一个命中"。一旦有了板级文件，它就成了第一个命中，
`rk3399-u-boot.dtsi` **被顶掉而不是叠加** —— 于是 `binman` 节点
（定义在 `rockchip-u-boot.dtsi` 里，而后者只被 `rk3399-u-boot.dtsi` 引用）就没了。

所以板级 dtsi 必须**自己把链接回去**：

```dts
#include "rk3399-u-boot.dtsi"              /* binman 节点 + bootph-* 标记 */
#include "rk3399-sdram-lpddr4-100.dtsi"    /* 只有 &dmc { rockchip,sdram-params = ... } */
```

这和 nanopc-t4 最终拿到的结果一致（`rk3399-nanopc-t4-u-boot.dtsi` →
`rk3399-nanopi4-u-boot.dtsi` → `rk3399-u-boot.dtsi`）。

两个坑的性质值得记下来：**第一个坑是运行时变砖，第二个坑是构建期失败。**
后者反而是好事 —— 它在拿到板子之前就暴露了。如果只修了 DRAM 参数就宣布完成，
下一次构建会以另一个原因失败，而两件事看起来毫不相干。

### 参数选型

`rk3399-sdram-lpddr4-100.dtsi`，依据是 Radxa 官方 spec：
**ROCK 4B+ = 64 位双通道 LPDDR4 @ 3200Mb/s（2/4 GB）**，
与 ROCK Pi 4、rock-4se 同规格，而 mainline U-Boot 给这些板子用的正是这个文件。

**没有**走 `rk3399-rock-pi-4-u-boot.dtsi`（它包含上面那个文件），因为它还会顺带
加上 `&sdhci` 时序覆盖（`mmc-ddr-1_8v`、`mmc-hs200-1_8v`）和一个 `leds` 节点。
eMMC 本来就能跑到 HS400，缺的只有 DRAM 参数 —— 在一块当前起不来的板上，
只改构建和 TPL 真正要求的那两样。

也没有加 `spi1 { flash@0 { ... } }`：SPI 引导走 `CONFIG_ROCKCHIP_SPI_IMAGE`，
不依赖 MMC 那种 flash 节点；能工作的 nanopc-t4 的 dtb 里同样没有 `flash@0`。

---

## 修复结果

```
b8fa872f46d2654201c036b8a6d6d7276be786cb15cbecd5f86cb5faedf488bf  idbloader.img        192512 B
e8aaf9319e10a888e727ba5bfb3088a7a0bad3001259bcb085e46ef3c491bd85  idbloader-spi.img   385024 B
```

| | 修复前 | 修复后 |
|---|---|---|
| `rockchip,sdram-params` | 0 处 | 1 处，1530 个 u32 |
| `binman` 节点 | 无 | 有 |
| `idbloader.img` | 180224 B | 192512 B |
| `tpl/u-boot-tpl.bin` | 61519 B | 67673 B |

TPL 变大是因为设备树里多了那个参数块。**两次独立构建产物 sha256 完全一致**，
注释类改动确认是惰性的。

`scripts/build.sh` 增加了 4 条基于内容的断言（附负控制验证正则真有区分度），
`scripts/check-patch-sources.sh` 会把三个补丁源和它们生成的补丁逐一比对 ——
后者是因为这次 `defconfig` 改了却没重新生成补丁，树里仍在断言相反的说法，
而没有任何东西报错。

## 已验证 / 未验证

**已验证**（构建机上，可复现）：
- 编译出的 `u-boot.dtb` 含 `rockchip,sdram-params`（1530 个 u32）和 `binman` 节点
- 零 `.rej`
- overlay 源文件与实际参与编译的文件逐字节一致
- 补丁载荷与 overlay 源文件逐字节一致
- 两次构建产物 sha256 相同
- 重建后的**镜像在 LBA 0x40 处确实带着修好的引导程序**（3 处命中）

**已在真机上验证**：
- ✅ **Maskrom 恢复路径可用** —— 用官方 `rk3399_loader` + Armbian 引导程序救回
- 板子重新进入系统（Armbian 26.11.0-trunk.62，eMMC `/dev/mmcblk0p1`）

**未验证**：
- ⚠️ **修复后的 U-Boot 能不能让板子真的启动** —— 一次都没上过真机
- ⚠️ **LPDDR4 参数是否与板上的实际颗粒匹配** —— 选型依据是与同规格板子的
  mainline 用法一致，不是对本板颗粒的实测
- ⚠️ **eMMC 上的 OpenWrt 引导** —— 镜像自带引导程序这一点已确认，但没跑过
- ⚠️ **从 SD 卡引导的恢复路线** —— 未验证

### ⚠️ 这块 SPI 在 Linux 下读不可信

板子救回后顺手查了一下 SPI，结果影响了一条原本打算写进文档的建议。

`/dev/mtd0` **超过约 32 KiB 的传输不可重复**：

- 三次 `sha256sum /dev/mtd0` 给出**三个不同的哈希**
- 两次 `dd` 结果差 **607414 字节**（4 MiB 中的 15%）
- 分块测：128 个 32 KiB 块里 91 个稳定；失败的块里有一批只差 1~2 字节，
  另一批差 32512 字节（像是整体错位了 256 字节）
- **与块大小无关** —— 1 MiB 分成 256 字节块读照样不稳；只与**总传输量**有关

板子能启动说明 boot ROM 和 Armbian 的 U-Boot 读得到它 —— 问题在这个内核
（6.18.54 rockchip64）的 SFC/mtd 读路径上。

**两个后果**：

1. **没法从 Linux 做可信备份。** `dd if=/dev/mtd0 of=whole.bin` 得到的文件不是
   任何东西的拷贝，当备份比没有更糟。
2. **不能信任从 Linux 的写入。** 写完还读不回来验证。

所以 `FLASHING.md` 原本那句"进了系统之后第一件事是把 SPI 修好"**是行不通的**，
已改为走 Maskrom。

---

## 方法论陷阱

1. **"构建成功"不等于"能启动"。** 加校验项的标准应该是
   *"这个缺陷能不能溜过去"*，而不是 *"我改了什么"*。
2. **静默降级比报错危险。** 去找那些"找不到就用兜底"的地方 —— 本次是
   `$(wildcard ...)` 的优先级回退，无警告、无失败、产物大小正常。
3. **判断"不存在"之前先确认位置。** 偏移 0 是最容易被查、也最容易被误信的地方。
   详见岔路四。
4. **风险项被消解和被误判，纸面上长得一样。** README 里那条
   "U-Boot DRAM 拓扑无公开 DTS 可抄 → 不成立" 当时判错了一半：
   "U-Boot 复用主线 DTS"这句话没错，错在把"复用主线 DTS"当成了
   "U-Boot 侧已经没有板级描述要做"。区别只在于有没有去查那个环节本身。
5. **危险路径要能只读地跑一遍。** 见 `FLASHING.md` 第 10 节那个 PowerShell 脚本：
   管理员门禁把写盘那段挡在评审之外，于是两个 bug 一直没人看见，
   加了 `-Preview` 之后两分钟暴露。
6. **shell 里注意同名变量。** `sh` 没有局部作用域，函数里用与顶层同名的计数器会
   直接覆盖 —— `check-patch-sources.sh` 因此把一次真实的漂移报成"全部匹配"且
   exit 0，只因为被检查的最后一个文件恰好是匹配的那个。
   **负控制要挑中间那个文件做。**