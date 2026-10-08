# U-Boot 变砖：DRAM 初始化失败

**排查记录。** 2026-10-06，这块板子起不来了。本文记录症状、排查过程（**包括走错的
岔路**）、根因、修复，以及哪些部分已验证、哪些没有。

**只想知道结论**：见 [boot-order.md](boot-order.md) 和 [README.md](../README.md) 顶部的
状态节。**要动手恢复**：见 [flashing.md](flashing.md) 第 9 节。**要理解修复本身**：
见 [device-tree.md](device-tree.md)。

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

`README.md` 和 `docs/flashing.md` 当时都写着"镜像里不含 TPL/SPL/idbloader —— SPI 上已有
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
- 两次构建产物 sha256 相同（⚠️ **仅限源码完全未改动时**，见下方「可复现性的准确含义」）
- 重建后的**镜像在 LBA 0x40 处确实带着修好的引导程序**（3 处命中）

**已在真机上验证**（2026-10-06 / 10-08）：
- ✅ **Maskrom 恢复路径可用** —— 用官方 `rk3399_loader` + Armbian 引导程序救回
- ✅ **Maskrom 写 eMMC 整包可用** —— `rkdeveloptool wl 0 <镜像>`，且不碰 SPI
- ✅ **OpenWrt 从 microSD 完整启动** —— Armbian 的 U-Boot 从 SPI 起来，在卡上找到
  `/boot.scr`，加载 `Linux-6.12.94` 的 kernel FIT 和 `radxa_rock-4b-plus` 的 dtb，
  crc32+sha1 校验通过。**6 次启动零 panic**
- ✅ **本移植的 U-Boot 首次在真机执行**（2026-10-06，Maskrom 写 eMMC 之后）——
  TPL 打出 `lpddr4_set_rate` + 两通道各 `Size=2048MB`，**本文记录的缺陷确实修好了**
- ✅ **eMMC 上的 OpenWrt 引导可用** —— tty8 从 `mmc@fe330000` 找到 `/boot.scr`，
  `VFS: Mounted root (ext4 filesystem) on device 179:2`

**未解决**（⚠️ 由上面第三条引出，是当前最高优先级的问题）：
- ❌ **本移植的 U-Boot 会导致随机 panic** —— base 版 6 次启动 3 次内核 panic，
  三次都是"函数指针被指向垃圾地址"。⚠️ **但那个"决定性对照"有两个共变变量** ——
  引导程序换了，**引导介质也换了**（Armbian 全从 U 盘，本移植全从 eMMC），
  **不能**据此断定是 TPL 的问题。
  完整证据链见 [postmortem-dram-instability.md](postmortem-dram-instability.md)。
- ❌ **~~DRAM 参数不同~~ 已排除** —— `rk3399-sdram-lpddr4-100.dtsi` 在 v2022.07 与
  v2025.10 **逐字节相同**（sha256 `2874c640…`）。DRAM 的 CONFIG 也相同，板级 dtsi
  也相同。
- ⚠️ **唯一剩下的差异**：v2025.10 把 LPDDR4 切 400MHz 挪到了
  `set_memory_map` / `calculate_ddrconfig` / `dram_all_config` **之前**；
  v2022.07 是在 dtsi 频率下配完再升频。上游 mainline 代码，**未验证是否相关**。
- ⚠️ **U-Boot 版本差异已查**（2026-10-08）：`drivers/ram/rockchip/sdram_rk3399.c`
  两版只差 +64/−48 行（93 KB 的 3%），**不是"可能有实质变动"那种程度**。

**已撤回的说法**：
- ❌ 「本移植的 U-Boot 一次都没上过真机」—— 2026-10-06 通过 Maskrom 写 eMMC 执行了
- ❌ 「LBA 0x40 那份从未被执行」—— 同上
- ❌ 「风险在不贴 SPI 的量产板，那类板只能靠镜像自带那份，而那份没被验证过」——
  **方向反了**：那份现在验证过了，结论是"能启动但会崩"，所以风险不在"能不能引导"，
  而在"任何板子上用这份引导程序都会有 50% 概率 panic"

### 「可复现」到底指什么

这里原本写「两次构建产物 sha256 相同」。后来发现 `recovery/` 里 18:40 存的产物和当前
20:48 的构建 sha256 **不同**，所以那句话需要限定条件，否则读起来像"任何时候重建都得到
同一串字节"。

实测结论：

| | 18:40 的构建 | 20:48 的构建 |
|---|---|---|
| `idbloader.img` | `b8fa872f…` | `76bf3bcf…` |
| 差异字节数 | — | 1945 / 192512（1.01%） |
| DTB 节点数 | 19 | 19 |
| 属性值（路径感知） | 82 项 | **82 项全部相同** |
| 版本串 `U-Boot SPL 2025.10-…(Jun 29 2026 - 12:59:20)` | — | **逐字节相同** |

差异**全部落在 DTB 的 string table 和 struct 排列上**，`code` 区在 `idbloader.img` 里
一个字节都没变。`u-boot.itb` 里那 2 处"属性变化"是 DTB 变了导致 FIT 里记录的
`/images/fdt-1/hash/value` 和 `data-size` 跟着变 —— 派生结果，不是根因。

中间隔着提交 `20f3a4e1ff`，它改了 defconfig patch 和 dtsi patch，但**只动注释**。
语义没变，字节变了。

所以准确的说法是：

- **可复现的是语义，不是字节。** 同一份源码重建，得到功能等价但 sha256 可能不同的产物。
- 字节级可复现只在**源码未改动**时成立（`dtc` 对同一份输入输出确定）。
- 想判定两次构建是不是同一份东西，别比 sha256，**比设备树的路径+属性**。

⚠️ 这直接影响恢复流程：`recovery/` 里的 U-Boot 产物**不是**当前构建的字节。
如果将来要用 Maskrom 把本移植的引导程序写进 SPI，应该先从当前构建目录取，而不是直接用
`recovery/` 里这份。`recovery/` 里那份本身是好的（同样含 `rockchip,sdram-params`），
只是不属于现在这棵树。

> ⚠️ **已过时（10-09）**，而且当时的情况**比这句话更糟**。`recovery/` 里放的一直是
> **base 构建**，而那份已知 6 次启动 3 次 panic —— 在紧急时刻去拿，拿到的就是一个
> 已知半坏的引导程序。该目录已清空，改放**通过判据的那个构建**，附 `SHA256SUMS.txt`
> 与 `recovery/README.md`（含「只放测过的构建」这条规矩）。
> `recovery/spi-working-armbian.bin` **已删除**（0 个 FDT magic、0 条 U-Boot 字符串）。

### ⚠️ 这个"未验证项"已经不再是未验证 —— 而且验出了新问题

**本节原先写着"只剩 Maskrom 写 SPI 一条，决定不写，引导程序保持未在真机验证"。**
那是 2026-10-06 当时的记录。**后来发现第四条路：Maskrom 可以写 eMMC，不碰 SPI。**

```bash
sudo rkdeveloptool db rk3399_loader_v1.27.126.bin
sudo rkdeveloptool wl 0 os.img        # 整包写进 eMMC
```

这一条路**保留了 SPI 上那份能用的 Armbian 引导程序**（正好当对照组），而且让本移植的
引导程序第一次在真机上执行。

结果：

| | 结论 |
|---|---|
| ✅ **`rockchip,sdram-params` 修复生效** | TPL 打出 `lpddr4_set_rate` + `Channel 0/1: LPDDR4, 400MHz ... Size=2048MB`。**本文记录的缺陷确实修好了。** |
| ❌ 但**同一份 TPL 会导致随机 panic** | base 版 6 次启动 3 次内核 panic（`+vdd_log` 构建只测过 1 次） |
| ✅ eMMC 引导**已验证** | tty8 首次从 eMMC 挂上 root |

所以这个"未验证项"的最终状态不是"验证通过"，而是**"验证出了下一个问题"**：
DRAM 参数虽然让 TPL 跑起来了，但训练结果可能不稳，导致运行期随机内存损坏。

完整证据链、12 次启动的对照表、三次 panic 的栈，见
**[postmortem-dram-instability.md](postmortem-dram-instability.md)**。

⚠️ 早先列的三条排除仍然成立，但它们排的是"写 SPI"这条路，与现在无关：
从运行中系统写不了 SPI（读不对）；短接 SPI 不影响 boot ROM（实测）；而
"借道镜像自带的那份"—— **这条当时判断为"从未被执行"，是错的**，它后来执行了，
只是走的是 eMMC 而不是 SPI。

### ⚠️ Linux 从这块 SPI 读不到正确的内容

板子救回后查 SPI，查出的结论比预想严重，而且**推翻了本文早期的一个说法**。

早期这里写的是"读不可信：三次 `sha256sum` 给出三个不同哈希、两次 `dd` 差 607414
字节"。那是**在 Armbian 6.18.54 上**观察到的现象，方向对了但描述错了 ——
问题不是"读不稳定"，而是**读到的根本不是芯片内容**。

### 在 OpenWrt 上：读完全可重复，但内容是错的

给内核补上 `&spi1` + `flash@0` 节点之后（见 README「设备树策略」节），
`/dev/mtd0` 出现了，控制器也绑上了：

```
/proc/mtd            mtd0: 00400000 00001000 "spi1.0"
/sys/class/mtd/mtd0  type=nor   flags=0xc00   bad_blocks=0
rockchip-spi 驱动已绑定，spi1.0 存在
```

**两次独立读取（块大小 64 KiB 和 4 KiB 各一次）字节完全相同**，
`md5 = 9346c99ff025fe0d9d814842d97cebbd`。按"读是否稳定"的标准，这是完美通过。

**但内容是错的：**

```
整个 4 MiB 里：rkimage magic  无
              FIT magic(d00dfeed) 无
              U-Boot TPL / SPL / 2022 / 20  全部无
```

而这块芯片上明明有能跑的引导程序 —— SPL 明确 `Trying to boot from SPI`，
U-Boot proper 起来了，还从 SPI 读了环境变量（`bad CRC`）。

用 Armbian 镜像里那份引导程序做参照（它确定是 rkimage，`0x8000` 处有 magic），
和 dump 逐段比对：

```
0x8000 / 0x9000 / 0x12000 / 0x20000 各 256 字节   全部 NOT FOUND
dump contains 3b8cdcfcbe9f9d51 : no
dump contains d00dfeed         : no
```

**JEDEC ID 这类短事务读对了**（所以 4 MiB / 4 KiB 的几何信息合理），
**批量数据读全是错的**。

### 为什么这个更危险

因为它**能通过任何"读是否稳定"的检查**。一个确定性失败返回每次都一样的错误数据，
于是：

- 三次 `md5sum` 相同 → "读稳定，通过"
- 两种块大小结果相同 → "与块大小无关，通过"
- `bad_blocks=0`、`type=nor` → "芯片认出来了，通过"

**一个能在垃圾上通过的检查不是检查。** 这是本文第三次出现同一类错误
（前两次是没查就下结论：LBA 位置查错、镜像是否自带引导程序搞反）。
教训都一样：**验证必须包含"结果符合预期"这一步，不能只验证"结果一致"。**

### 三个后果

1. **没法从 Linux 做可信备份。** 备份下来的不是芯片内容。
2. **不能从 Linux 写入引导程序。** 写完读不回来验证 —— 那是对唯一会造成不可逆变砖
   的介质做盲写。
3. `docs/flashing.md` 原本那句"进了系统之后第一件事是把 SPI 修好"**行不通**，
   已改为走 Maskrom。

### 短接 SPI 引脚：✅ 已验证对 boot ROM 无效

曾推荐过"短接 SPI 引脚到 GND，让 boot ROM 跳过 SPI 去用镜像自带的那份"。
**这在真机上测过，不成立**：

| 现象 | 说明 |
|---|---|
| 短接后 `mtd0` 消失 | 短接对 Linux **确实**生效 |
| 但串口第一行仍是 `U-Boot TPL 2022.07_armbian` | **boot ROM 照样从 SPI 加载引导程序** |
| `Loading Environment from SPIFlash` 仍出现 | U-Boot proper 也照样读 SPI |

所以短接既不能让 boot ROM 跳过 SPI，也没有把板子弄挂（有一次截断的日志让我以为
挂掉了，那是误读）。**这条路已经关闭，别再试。**

### 一条待查的线索

我们把 `spi-max-frequency` 定成 10 MHz（当时判断"保守"），上游 rock-pi-4b 用 108 MHz。
**两个频率都读不对**，所以频率大概不是主因 —— 但没有更多证据，不下结论。
已知 JEDEC ID 能读对而批量读全错，指向读路径而不是芯片。

---

## 相关文档

- [postmortem-dram-instability.md](postmortem-dram-instability.md) — **修好之后发现的随机 panic（当前最高优先级）**
- [boot-order.md](boot-order.md) — 启动顺序、镜像自带引导程序、SPI 读不对（结论摘要）
- [device-tree.md](device-tree.md) — 修复本身：板级 U-Boot dtsi 与 wildcard 优先级链
- [build.md](build.md) — 21 项校验里几批是怎么加出来的
- [flashing.md](flashing.md) — 恢复路线的操作步骤
- [README.md](../README.md) — 当前状态与进度

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
5. **危险路径要能只读地跑一遍。** 见 `docs/flashing.md` 第 10 节那个 PowerShell 脚本：
   管理员门禁把写盘那段挡在评审之外，于是两个 bug 一直没人看见，
   加了 `-Preview` 之后两分钟暴露。
6. **shell 里注意同名变量。** `sh` 没有局部作用域，函数里用与顶层同名的计数器会
   直接覆盖 —— `check-patch-sources.sh` 因此把一次真实的漂移报成"全部匹配"且
   exit 0，只因为被检查的最后一个文件恰好是匹配的那个。
   **负控制要挑中间那个文件做。**
7. **⚠️ "结果一致"不等于"结果正确"。** 这块 SPI 在 OpenWrt 下两次独立读取
   （不同块大小）**字节完全相同**，`type=nor`、`bad_blocks=0`、几何信息也对 ——
   稳定性检查满分通过。但整个 4 MiB 里没有 rkimage 头、没有 FIT magic、
   没有 U-Boot banner，而这块芯片上明明有能跑的引导程序。
   **确定性失败返回每次都一样的错误数据，于是它能通过任何"读是否稳"的检查。**
   验证必须包含"**结果符合预期**"这一步，不能只验证"结果一致"。
8. **⚠️ 我自己连续三次栽在同一件事上**：没查够就下结论 —— LBA 位置查错（岔路四）、
   镜像是否自带引导程序搞反（岔路五）、把截断的日志当完整观察（"板子起不来了"，
   还据此让人去拆线）。前两次写进文档、第三次发成了指令。
   写"已验证"之前，先问一句：**这条证据是完整的吗？**
9. **⚠️ "日志停了"不等于"系统停了"。** 第 4 次，同一个错误。tty7/tty9 的串口输出
   在 1.2～1.4 秒处断掉，我两次描述成"卡住"，其中一次实际是 panic。
   **截断的日志只能证明"没看到"，不能证明"没有"。**
10. **⚠️ 一次抓取里可能有多次启动。** 统计 12 次启动时，脚本只看每份日志的**最后**
    一条结果，于是把 tty8 判成"panic" —— 而它的**第一次**启动是完整挂上 root 的。
    **统计前必须先按 banner 切分再逐次判定。**
    同源问题：把一个序列压成单一结论，扔掉了唯一有用的那部分。
11. **⚠️ "能工作"和"稳定"是两件事，而一次成功证明不了后者。** 本移植的引导程序
    6 次启动里挂上 root 1 次、panic 3 次。**"启动成功过一次"完全不能推出
    "可以交付"。** 评估可靠性至少要 6 次以上，而这里故障率是 50%。
12. **⚠️ 排除法要选好对照。** 定位 DRAM 问题靠的是"同样的内核/dtb/rootfs，
    只换 TPL" —— 变量唯一，结论才站得住。早先怀疑 WiFi 是因为"panic 发生在
    `mmc_rescan` 附近"，那是**位置巧合，不是因果**；下一次 SDIO 成功时照样崩，
    假设立刻作废。**找因果要找变量，不是找相关。**