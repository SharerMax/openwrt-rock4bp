# 构建

构建环境、目录结构、构建流程、包集合、23 项校验、产物与可复现性。

---

## 环境

| 项 | 值 |
|---|---|
| 构建机 | `hyv-ub24`，Ubuntu 24.04.5，10 核，10GB RAM |
| 源码树 | `/home/max/Code/openwrt` |
| 工具链 | gcc 14.3.0，binutils 2.44，musl |
| 内核 | 6.12.94（v25.12.5 pin 的版本，hash `e998a232b941…`） |
| U-Boot | mainline 2025.10 |
| 配置 | `rockchip/armv8` → `radxa_rock-4b-plus` |

### ⚠️ umask 必须设为 022

构建机默认 umask 是 `0002`，而 `include/prereq-build.mk` 会硬性检查并拒绝非 022。
`scripts/build.sh` 里已经 `umask 022`。

### 依赖

按 `include/prereq-build.mk` + `include/u-boot.mk` 逐条核对安装，全部满足。

### remote 配置

gitee 镜像停更在 `8dff4c9a34`，已改为官方源：`origin` = github，`origin-git` =
git.openwrt.org，`gitee` 仅作参考。

⚠️ **不要用 curl 测远端可达性**（本机 Windows 没有 curl），用 `git ls-remote`。

### 磁盘是当前最大约束

构建机 58G，已用 35G，剩 21G。Debian 的 `firmware-nonfree` 源包 105MB 只是为了取一个
483KB 的文件，下载完立刻删掉。

---

## 目录结构

本仓库是**移植层**，不是 OpenWrt 树。树在构建机上 `/home/max/Code/openwrt`。

```
README.md                          入口：状态、已验证清单、进度
AGENTS.md                          给 AI agent 的工作指南
docs/
  hardware.md                      硬件事实、板型辨识、按键、介质
  boot-order.md                    启动顺序、SPI 引导、SPI 读不对
  device-tree.md                   设备树策略、U-Boot 板级 dtsi、dtc 坑
  build.md                         本文件
  flashing.md                      烧卡 / 烧 eMMC / 变砖恢复
  wifi.md                          WiFi 排查完整记录
  postmortem-u-boot-ddr.md         U-Boot 变砖的排查记录
  radxa-rock4b-plus-product-brief.pdf   Radxa 官方 Product Brief
overlay/                           按 OpenWrt 源码树路径镜像
  target/linux/rockchip/image/armv8.mk             +20 行：radxa_rock-4b-plus
  target/linux/rockchip/image/armv8.mk.orig        上游基线（故意不同步）
  package/boot/uboot-rockchip/Makefile             +8 行：U-Boot 变体 + UBOOT_TARGETS
  package/boot/uboot-rockchip/Makefile.orig        上游基线（故意不同步）
  package/firmware/broadcom-nonfree/Makefile       新增：BCM43456 固件包
  kernel/rk3399-rock-4b-plus.dts                   130 行 delta，继承上游两个 dtsi
  u-boot/rock-4b-plus-rk3399_defconfig             U-Boot defconfig（基于 rock-4se）
  u-boot/rk3399-rock-4b-plus-u-boot.dtsi           U-Boot 板级 dtsi（含 LPDDR4 DRAM 参数）
scripts/
  build.sh                                         manifest + 构建后 23 项校验
  regen-dts-patch.sh                               重新生成内核补丁 + dtc 校验
  sync-overlay.sh                                  比对 overlay/ 与远端源码树
  check-patch-sources.sh                           三个补丁源与生成的补丁逐一比对
  extract-patch-file.sh                            从多文件补丁里取单个文件的新增内容
  assert-sdram-params-in-image.py                  断言镜像/引导程序里带着 RK3399 DRAM 参数
  extract-debian-43456.sh                          从 Debian 源包提取 43456 固件
  extract-synaptics-license.py                     提取 Synaptics 许可全文
  deploy.sh                                        把整盘镜像写进 U 盘 / SD / eMMC
  write-idbloader-sd.ps1                           Windows：把 idbloader 写到卡的 LBA 0x40
  wifi-test.sh                                     AP6256 上电测试（每组合一次冷启动）
log/                                               串口日志，**被 .gitignore 排除**
recovery/                                          只在构建机上，见下
```

⚠️ **`recovery/` 只在构建机上**（`/home/max/Code/rockpi4bp/recovery/`），不在本仓库里
—— 它是构建产物和恢复材料的临时存放处。里面有：

```
idbloader.img / idbloader-spi.img / u-boot.itb     引导程序
                                                     ⚠️ 18:40 那版，非当前构建的字节
openwrt-...-ext4-sysupgrade.img.gz                当前镜像的副本（与 bin/ 逐字节一致）
spi-working-armbian.bin                            从板上读到的 SPI dump
                                                     ⚠️ 这份不是芯片内容，见 boot-order.md
```

### overlay 里的两类文件，不要混为一谈

- **直接进树的源文件**（`*.mk`）—— 由 `sync-overlay.sh` 按显式路径映射双向同步
- **补丁源**（`*.dts` / `*defconfig` / `*-u-boot.dtsi`）—— 本身不进树，要先生成补丁

补丁源和补丁脱节过一次，现在由 `check-patch-sources.sh` 每次都比对。

`*.orig` 记录上游改动前的样子，**故意不在同步映射里** —— 把它们拷过去会还原掉本移植。

远端同步采用覆盖法：`scp` 把 `overlay/` 下的文件按相对路径拷进远端源码树。因上游固定在
`v25.12.5`，本地保存完整副本不会有漂移问题。

---

## 构建流程

`scripts/build.sh` 的顺序是**硬性的**：

```
1. manifest 修正（禁用 4329-sdio）
2. make defconfig      ← 改 DEVICE_PACKAGES 后必需
3. make -j10
4. 构建后 23 项校验     ← 不是装饰
```

日志写到 `/tmp/build-full.log`，结尾打印校验块、`REAL_EXIT_CODE` 和日志年龄。

⚠️ **`scripts/build.sh` 是包集合清单的唯一可复现来源** —— `.config` 在 OpenWrt 里是
gitignore 的，只存在于构建机上，所以清单决定写进了脚本里。

### 三个必踩的坑

**① `scripts/config` 是构建目录，不是 helper 脚本。** 新版 OpenWrt 把它变成了
`scripts/config/` 目录，`./scripts/config --disable` 报"是一个目录"。而
`scripts/kconfig.pl` 是做 config diff 的，也没有 `--disable`。要改 `.config` 就按 kconfig
格式直接改，再让 `make defconfig` 归一化。

**② 改 `DEVICE_PACKAGES` 后必须 `make defconfig`。** 不跑的话构建只打一行
`WARNING: your configuration is out of sync`，然后**照旧把旧包集合打进镜像**。差点把
`kmod-r8169` 之类的又带进去。

**③ 重生成补丁时"pristine"基线必须真的干净。** 上轮构建后内核树的
`dts/rockchip/Makefile` 里已经有我们那行了，直接拿来做基线会让补丁**把同一行加两次**，
dtb 目标重复会直接编译失败。`scripts/regen-dts-patch.sh` 现在会先剥掉残留行并断言它确实
不存在。

---

## 23 项构建后校验

前几次"看起来成功"都是因为没查最终产物 —— 构建返回 0 但镜像里缺东西。现在
`scripts/build.sh` 结尾强制检查并写进日志：

```
=== post-build verification ===
  OK/FAILED  43456 firmware apk built
  OK/FAILED  43456 firmware in image manifest
  OK/FAILED  brcmfmac driver in image manifest
  OK/FAILED  absent from manifest: brcmfmac-firmware-4329-sdio
  OK/FAILED  absent from manifest: kmod-r8169
  OK/FAILED  absent from manifest: cypress-firmware-4356-sdio
  OK/FAILED  absent from manifest: brcmfmac-nvram-4356-sdio
  OK/FAILED  dtb is newer than the patch that builds it
  OK/FAILED  dtb enables the WiFi power-sequence clock (ext_clock, not lpo)
  OK/FAILED  dtb still carries the board model
  OK/FAILED  dtb exposes the SPI flash (spi1 okay, with a jedec,spi-nor child)
  OK/FAILED  kernel patch applied without rejects
  OK/FAILED  u-boot dtb is newer than the patch that builds it
  OK/FAILED  u-boot dtb carries the RK3399 DRAM parameters (rockchip,sdram-params)
  OK/FAILED  u-boot dtb has a binman node (board -u-boot.dtsi must re-include rk3399-u-boot.dtsi)
  OK/FAILED  u-boot dtb sets vdd_log to 950mV
  OK/FAILED  both idbloader variants built
  OK/FAILED  0103 applied: no early LPDDR4 rate switch ahead of the channel loop
  OK/FAILED  0103 applied: both controllers switched after the configuration
  OK/FAILED  0103 applied without rejects
  OK/FAILED  image is newer than the staged bootloader it embeds
  OK/FAILED  staged bootloader contains the RK3399 DRAM parameters
  OK/FAILED  the image embeds that bootloader at LBA 0x40
```

（其中一条在 `for` 循环里对 4 个包各跑一次，所以日志打印 26 行 ——
`grep -c 'check "' scripts/build.sh` 数的是语句位置，不是执行次数。）

### ⚠️ 有三类补丁，护法不一样

| 补丁类型 | 例子 | 谁盯它 |
|---|---|---|
| 新增文件 | `0001`（内核 DTS）、`0101`（defconfig）、`0102`（板级 dtsi） | `check-patch-sources.sh` 比对 payload |
| **修改已有上游文件** | **`0103`（`sdram_rk3399.c`）** | **`build.sh` 的三条断言，直接盯编译用的源码** |
| 新增文件且跨多文件 | `0001` 还改了 kernel Makefile | 同第一类，但必须按文件拆 payload 才有意义 |

⚠️ **第二类没有 payload 可比对**（它改的是一个已存在的文件，补丁里只有片段），
所以 `check-patch-sources.sh` 结构上就检查不了它。

⚠️ **而这个改动在产物里完全看不见**：打或不打，`idbloader.img` 都是 192512 字节，
上面所有内容断言的结论**完全一样**。所以断言只能打在**实际参与编译的那份源码**上。

⚠️ **这三条断言本身经过负控制验证** —— 不然它们可能是一组永远通过的摆设：
把删掉的块塞回去、两次调用合并成一次、以及文件本身不存在，三种情况都会让它们失败。
（这一步不能省：仓库里已经有过一个对所有文件都报"没找到"的检查器，
和坏掉的检查器在输出上长得一模一样。）

### 这条断言当场抓到了它自己要防的事

`u-boot dtb sets vdd_log to 950mV` 加进去之后，**第二次运行就失败了** ——
而属性明明在 dtsi 里、也在补丁 payload 里。

原因不在构建：是我写的一个对照脚本（想比较「加 override」和「不加 override」两种
dtb）改了构建树里的 dtsi，`make` 失败（直接跑 `make` 用的是宿主 gcc，缺交叉编译
环境），而脚本用了 `set -e`，**在 restore 之前就被杀掉了**。构建树里少了那 5 行，
下一次构建忠实地产出一个没有该属性的 dtb，**全过程没有任何警告**。

⚠️ **被破坏的构建树会产出一个看起来完全正常的构建。** 只有对编译产物做内容断言才看得出来。

⚠️ **所以：会改构建树的脚本，失败路径也必须恢复。** 别指望 `set -e` 之后的代码还会跑 ——
把恢复放进 `trap`，或者干脆别在构建树里做实验（用副本）。

⚠️ 顺带：这个断言第一次失败是**我自己的算术错** —— 950000 是 `0xE7EF0`，
我写成了 `0xE8A40`。**断言写错和被测物坏掉，输出上看起来一模一样**，
这也是为什么负控制要单独跑。

### 分三批加的，因为犯的错不同

**第一批（4 项，针对 `u-boot dtb`）** —— `rockchip,sdram-params` 缺失时构建返回 0、
`idbloader.img` 正常产出、原有 9 项全过。因为那些校验问的都是**文件在不在、大小对不对、
内容是不是这个项目要的**，没有一个问"这块板子能不能靠它启动"。

**第二批（3 项，针对镜像）** —— 修好构建树之后又发现，**镜像里内嵌的那份引导程序可能是
旧的**。构建树干净、断言全过，而镜像照样带着之前那个坏掉的引导程序 —— 因为镜像是更早
一次构建的产物。镜像才是板子实际执行的东西，所以断言必须打在镜像上。

> 那条 DRAM 参数检查不能写成 shell 一行：`rockchip,sdram-params` 是**大端 FDT 里的 u32
> 数组**，needle 必须从编译出的 dtb 里取，并且**先在那个 dtb 自身上验证有效**再用。
>
> 第一版 needle 是凭记忆敲的，在 `u-boot.dtb` 里 **0 命中**，却在两个容器里都"命中"
> —— 那是巧合字节序列。**一个能在垃圾上通过的检查不是检查。**
> 见 `scripts/assert-sdram-params-in-image.py` 的文档字符串。

**第三批（1 项，针对内核 DTB）** —— `dtb exposes the SPI flash`。补上 `&spi1` +
`flash@0` 之后 SPI 才在 OpenWrt 下可见，这项检查盯住那两行不会被后续改动丢掉。
⚠️ 它只验证**节点存在**，**不验证能读对** —— 实测那块 SPI 读回来的不是芯片内容，
这项检查对那种情况完全无感。**这是"通过检查"和"功能正常"分离的又一个例子。**

### 两条使用纪律

1. **看校验块，不要只看 `REAL_EXIT_CODE`。** 还要看日志**第一行的时间戳** ——
   有一次 `setsid nohup` 在 `ssh` 里静默失败，校验块读的是上一轮的日志，报了 9 项 OK，
   实际什么都没编译。
2. **校验项按"这个缺陷能不能溜过去"来选**，不是按"我改了什么"来选；而且要打在
   **最终产物**上，不是只打在中间目录上。

---

## 包集合

### 新建 OpenWrt 包时两个必踩的坑

**`Build/Compile` 必须显式定义。** 默认实现会 `cd` 进 `$(PKG_BUILD_DIR)`，而无源包没有
这个目录，构建失败且没有任何有用信息。

**`include $(INCLUDE_DIR)/package.mk` 绝对不能漏。** 漏了的话包**从未被注册**：
不生成 Kconfig 符号，于是 `DEVICE_PACKAGES` 写进去的 `CONFIG_DEFAULT_<pkg>=y` 找不到
对应符号、永远不被提升成能构建的 `CONFIG_PACKAGE_<pkg>=y`；同时 `package.mk` 定义的
`compile:` 目标不存在，报 `No rule to make target 'compile'`。

⚠️ **这个 bug 的表征极具误导性** —— 它表现为"包没被选中"，而真正的问题是"包没被注册"。
为此绕了大量弯路，甚至得出一个**错误结论**："这棵树对非 kmod 包不会自动提升"，还用一个
**同样在坏状态下跑的对照实验**去"证实"它。那个结论完全是 bug 导致的假象。

更早还用过三个**没先验证对照组**的"证据"：`.packageinfo` 里没有我们的包（它根本不列
这类包，`kmod-brcmfmac` 也是 0）、拿未选中的 `cypress-firmware` 当"能工作的对照组"、
在 `.config-package.in` 里找 Kconfig 符号（不在那儿）。

### 修正记录

曾把 `friendlyarm_nanopc-t4` 的包列表抄过来（连 `kmod-brcmfmac` 都漏了）：

```makefile
DEVICE_PACKAGES := kmod-r8169 brcmfmac-nvram-4356-sdio cypress-firmware-4356-sdio
```

| 包 | 问题 |
|---|---|
| `kmod-r8169` | 本板网口是 **RTL8211F PHY 挂在 stmmac MAC 上**，没有 Realtek MAC |
| `cypress-firmware-4356-sdio` | CYW4356 的固件，芯片不对 |
| `brcmfmac-nvram-4356-sdio` | 同上 |
| `brcmfmac-firmware-4329-sdio` | BCM4329 固件（RPi 3B 时代），手工 `.config` 遗留 |

**`brcmfmac-firmware-usb` 去不掉，不是疏失**：`package/kernel/mac80211/broadcom.mk`
声明 `+BRCMFMAC_USB:kmod-usb-core +BRCMFMAC_USB:brcmfmac-firmware-usb`，而 mac80211
backports 配置里 `CPTCFG_BRCMFMAC_USB=y`，所以**任何**用 `kmod-brcmfmac` 的设备都会带上它。
强去掉只能改 backports 的 Kconfig，为 500KB 不相关固件不值得，也不适合上游。

### BCM43456 固件包

`package/firmware/broadcom-nonfree/`。许可分析见 [wifi.md](wifi.md) 的第 5 节。要点：

- 固件 blob 是 **non-free**，linux-firmware 和所有 OpenWrt 包都不含
- **vendored 而非下载**，来源是 `RPi-Distro/firmware-nonfree` 分支 `trixie`
  （commit `3bab0f823f5b53150b76aab77093adef6655b920`）的
  `debian/added-firmware/brcm/`。选它是因为它是非自由 blob 的 Debian 源包，
  **许可随文件一起走**
- 换掉之前的 `armbian/firmware` 是必须的：那仓库 README 明写"再分发限于
  non-commercial / usage-only"，等于来源禁止我们做的事
- **适用的是 Synaptics 协议，不是 Broadcom SLA。** RPi 的 `debian/copyright` 对这批
  文件有单独条目：
  ```
  Files: debian/added-firmware/*/*43456*
  Copyright: Synaptics
  License: Synaptics
  ```
  Broadcom SLA 管的是 linux-firmware 里 `brcm/brcmfmac*.bin` **一般情况**，43456 的
  blob 不在其内 —— 所以早先版本附错了许可文本
- Synaptics 协议（DRIVER END USER LICENSE AGREEMENT, BINARY DISTRIBUTION）
  授权条款是"以目标码形式复制和分发，**仅用于 Synaptics 芯片**"，三个条件都满足：
  逐字节安装（编译期断言 sha256）、不改不派生、唯一消费者就是驱动本板 BCM43456 的
  `brcmfmac`
- 协议还有一条容易被忽略的义务，对再分发镜像的人适用：
  > the Software may be subject to export control laws
- 全文装到 `/usr/share/licenses/broadcom/LICENSE.Synaptics`
  （7218 字节，`bb50f974…`）
- blob 本身在 `.gitignore` 里（构建只需它在磁盘上，git 历史实际上是永久的）
- 不想分发就从 `DEVICE_PACKAGES` 删掉该包，`kmod-brcmfmac` 会用手工拷进去的文件

---

## 产物

OpenWrt 树 HEAD `a48a30233f`（工作区干净），`bin/targets/rockchip/armv8/`：

```
openwrt-...-radxa_rock-4b-plus-ext4-sysupgrade.img.gz        12811789 字节
openwrt-...-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz    11498362 字节
```

U-Boot 产物（`build_dir/target-aarch64_generic_musl/u-boot-rock-4b-plus-rk3399/u-boot-2025.10/`）：

```
192512   idbloader.img          sha256 76bf3bcf…
385024   idbloader-spi.img      sha256 62e4142c…
1295360  u-boot.itb             sha256 37f1c604…
97080    u-boot.dtb
```

⚠️ **一个引导程序需要两个文件。** `idbloader*.img` 只是 TPL+SPL；U-Boot 本体在单独的
`u-boot.itb` 里，要写到 LBA 0x4000。只写前者只能到 SPL。

镜像 sha256（当前）：

```
5a09fc419fb39a81ee3d749f8edcaeaf6313a31e9422b2b476b8db65c7701325  ext4-sysupgrade.img.gz
f462fb96ed4eccb4c29452ce8ab8a5b2964294fc3678129866baedccaed11d29  squashfs-sysupgrade.img.gz
```

历史 sha256（变了就是不同镜像）：`6386de591b5f…`（WiFi 修复前）、`06b61b20dceb…`
（WiFi 硬件层打通）、`9932b3dad4d2…`（删 gpio-keys）、`50092eba850c…` /
`07d22b762c20…`（换 RPi 固件源与 Synaptics 许可前的最后一版）。

⚠️ **`gzip -t` 会对 sysupgrade 镜像返回 2**（gzip 流之后有 274 字节的 sysupgrade 元数据
尾部），**不是损坏**。校验用 `sha256sums` 或 zlib 首个流。

manifest 实测内容：

```
brcmfmac-firmware-43456-sdio - 7.84.17.1-r2    ← 本移植新增
brcmfmac-firmware-usb        - 20260221-r1       ← 上游条件依赖，去不掉
kmod-brcmfmac                - 6.12.94.6.18.26-r1
kmod-brcmutil                - 6.12.94.6.18.26-r1
```

确认已消失的错包：`brcmfmac-firmware-4329-sdio`、`kmod-r8169`、
`cypress-firmware-4356-sdio`、`brcmfmac-nvram-4356-sdio`。

**镜像层面实证**：解开 squashfs 逐字节核对过三个 blob 都在 `/lib/firmware/brcm/`、哈希与
Makefile 钉死的值一致、`LICENSE.Synaptics` 在 `/usr/share/licenses/broadcom/`，
且首行确实是 Synaptics 协议而非 Broadcom SLA。

DTB 反解语义核对：

```
model       = "Radxa ROCK 4B+"
compatible  = "radxa,rock-4b-plus", "radxa,rockpi4b-plus", "radxa,rockpi4", "rockchip,rk3399"
pmic@1b     rockchip,rk808          ✓
es8316      everest,es8316         ✓
gmac        tx_delay 0x28 / rx_delay 0x11
sdio0       status = "okay" + brcmf child ✓
uart0       status = "okay" + bluetooth child ✓
spi1        status = "okay" + jedec,spi-nor child ✓
gpio-keys   不存在 ✓（按设计删除）
```

---

## 可复现的准确含义

**可复现的是语义，不是字节。**

早先文档写"两次构建产物 sha256 相同"。实测 `recovery/` 里 18:40 存的产物和当前 20:48 的
构建 sha256 **不同**（`b8fa872f…` → `76bf3bcf…`），中间只隔了一个**改注释**的提交
（`20f3a4e1ff`）。

逐层查下来**不是代码变了**：

| 检查 | 结果 |
|---|---|
| 版本串（含固定日期 `Jun 29 2026 - 12:59:20`） | **逐字节相同** → 不是时间戳 |
| DTB 节点数 | 19 → 19 |
| DTB 属性（路径感知） | **82 / 82 全部相同** |
| 差异字节落点 | 全在 DTB 的 string table 与 struct **排列**上；`idbloader.img` 的 code 区 **0 字节**变化 |

`u-boot.itb` 里那 2 处"属性变化"是 DTB 变了导致 FIT 记录的
`/images/fdt-1/hash/value` 和 `data-size` 跟着变 —— 派生结果，不是根因。

所以：

- 字节级可复现只在**源码完全未改动**时成立（`dtc` 对同一份输入输出确定）
- **判定两次构建是不是同一份东西，别比 sha256，比设备树的路径+属性**

⚠️ **实际后果**：`recovery/` 里的 U-Boot 产物不是当前构建的字节。将来若要用 Maskrom 把
本移植的引导程序写进 SPI，应从当前构建目录取。

---

## 原风险项：全部已消解

这份清单写在第一次上机之前。事后逐条核对，**没有一项是真的风险** —— 因为它们全部源于
"自己手写外设描述"，而手写部分已被"继承上游"取代：

| 原风险项 | 实际情况 |
|---|---|
| U-Boot DRAM 拓扑无公开 DTS 可抄 | **判断错了一半**。U-Boot 确实复用内核主线 DTS、也不需要板级 C 驱动 —— 但它还需要一个 `arch/arm/dts/<board>-u-boot.dtsi`，**这个文件不存在、且不报错**。缺的正是 DRAM 参数，代价是一块板。见 [device-tree.md](device-tree.md#缺一个板级-u-boot-dtsi) |
| ES8316 需重新调 I2S/耳麦检测 | **不需要调**。继承上游后全是经硬件验证的值 |
| RTL8211F RGMII 延时需实测微调 | **不需要**。`tx_delay 0x28` / `rx_delay 0x11` 直接可用，1Gbps 实测通过 |
| AP6256 固件与 BT LPO 时钟需核对 | BT 的 LPO 时钟 `&rk808 1` 继承上游正确。**但 WiFi 的 pwrseq 时钟确实要改**（`lpo` → `ext_clock`），见 [device-tree.md](device-tree.md#1-wifi-供电时钟名lpo--ext_clock) |
| RK809 电压选择 GPIO | **芯片型号本身就猜错了** —— 是 RK808 |

**教训一**：这份清单本身是个信号 —— 列得出这么多"高风险项"，说明方法有问题。正确的做法
是去继承经硬件验证的描述，而不是自己写然后逐项担心。

**教训二**：但反过来也要认 —— **"不成立"这个结论下得太早，代价是一块板。** U-Boot 那一行
当时判为不成立，依据是"U-Boot 复用主线 DTS"。那句话本身没错，错在把"复用主线 DTS"当成了
"U-Boot 侧已经没有板级描述要做"。**风险项被消解和风险项被误判，在纸面上长得一模一样**
—— 区别只在于有没有去查那个环节本身。

---

## 相关文档

- [device-tree.md](device-tree.md) — 设备树策略与 dtc 坑
- [wifi.md](wifi.md) — 固件包许可的完整分析
- [flashing.md](flashing.md) — 拿到镜像之后怎么烧
- [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md) — 校验项是怎么加出来的