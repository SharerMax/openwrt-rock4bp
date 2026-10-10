# 烧卡与首次启动

把镜像拿到手、烧到介质上、第一次上电该看什么、出了问题怎么回退、eMMC 怎么装、
板子起不来时怎么救。

构建和校验见 [build.md](build.md)，硬件细节见 [hardware.md](hardware.md)，
启动顺序与 SPI 的特殊性见 [boot-order.md](boot-order.md)。

---

## 1. 拿到镜像

构建完成后，镜像在树的 `bin/targets/rockchip/armv8/` 下：

```bash
ls -lah "${OPENWRT_DIR:-$PWD}"/bin/targets/rockchip/armv8/
```

⚠️ `OPENWRT_DIR` 就是[第 5 步构建时用的那个树](build.md#从零开始不依赖任何特定机器)，
没设的话就是当前目录。

拉到别处留档（可选）：

```bash
scp user@buildhost:"${OPENWRT_DIR}/bin/targets/rockchip/armv8/openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz" .
scp user@buildhost:"${OPENWRT_DIR}/bin/targets/rockchip/armv8/sha256sums" .
```

⚠️ **上面的 sha256 是某一次特定构建的**，换一次构建就会变 —— 以树里的
`sha256sums` 为准，用 `sha256sum -c` 校验，不要照抄下面表里的值。

**历史校验和**（别搞混，sha256 变了就是不同镜像）：

| 镜像 sha256 开头 | 说明 |
|---|---|
| `6386de591b5f…` | WiFi/BT 修复前（`sdio0` disabled，芯片不上电） |
| `06b61b20dceb…` | 补上 4 个板级 override，WiFi 硬件层打通 |
| `9932b3dad4d2…` | 删掉猜测的 gpio-keys 节点，包集合修正 |
| `50092eba850c…` / `07d22b762c20…` | 固件源与许可纠正前的最后一版 |
| `e64004a0…` | 2026-10-06 上机验证用的那一版 |

> ⚠️ **别用 `gzip -t` 校验 OpenWrt 镜像。** 它会返回 **exit 2** 并报
> `trailing garbage ignored` —— 这**不是**下载损坏。OpenWrt 的 sysupgrade 镜像在
> gzip 流**之后**附加了 274 字节的 sysupgrade 元数据尾部，`.gz` 本来就不是一个
> 干净的 gzip 成员：
>
> ```
> [gzip 成员][8 字节 0][JSON][19 字节二进制][0x0112]
> {  "metadata_version": "1.1", "compat_version": "1.0",
>    "supported_devices":["radxa,rock-4b-plus"], "version": { ... } }
> ```
>
> 最后两字节 `0x0112` = 274 就是尾部自身的长度。这在**所有** OpenWrt sysupgrade
> 镜像上都成立。真正的校验是 `sha256sums` 里的值，`scripts/deploy.sh --verify`
> 用的就是它。

**第一次建议烧 squashfs**（只读、损坏面小、启动快、便于反复重刷）。
ext4 版本适合后续要持久化数据或装大量包时再用。

> ⚠️ **当前板上跑的是 ext4。** 2026-10-06 那次 microSD 启动用的是 **ext4** 镜像，
> 后续又重烧过一次（当前 `5a09fc41…`）。两个镜像共用同一份 manifest，所以包集合相同
> （`brcmfmac-firmware-43456-sdio - 7.84.17.1-r2`）。
>
> **squashfs 镜像至今未在真机上启动过**，要验证的话还得单独刷一次。
>
> 对 WiFi 排查而言 ext4 更合适：根文件系统可写，固件文件原生持久化，不必再靠 overlay
> 那一层。⚠️ `scripts/deploy.sh` 默认找的是 **squashfs** 镜像，烧 ext4 要显式指定
> 第二个参数 —— 不指定就会烧到另一份镜像上去。

> ⚠️ **别再用那块 SD 卡**。第一次烧 SD 卡时出现 `I/O error ... sector 135842`
> 加 `SQUASHFS error -5`，rootfs 读不了；换 U 盘烧**同一镜像**一次启动成功 ——
> 是那张卡的问题，不是镜像的问题。

---

## 2. ⚠️ 串口线（先确认，再插板子）

这是最容易损坏板子的一步。

| 项 | 要求 |
|---|---|
| 电平 | **3.3V TTL**，**绝对不能用 RS-232/±12V 电平** |
| 常见坑 | 便宜的 "USB-TTL" 有的是 5V 供电脚；USB 转 RS-232 芯片（CH340/FT232 的 232 版）**不能接** |
| 接线 | 只接 **GND / TX / RX** 三根，**不要接 VCC** |
| 波特率 | **1500000 8N1**（不是 115200！） |
| 调试口 | **UART2** |

**RX/TX 要交叉**：板子 TX → 转换器 RX；板子 RX → 转换器 TX。

波特率设错的表现是**满屏乱码或完全没输出**。看不到任何东西时，先怀疑波特率，再怀疑固件有问题 —— 别过早下结论说"没跑起来"。

若不确定线材，**先只接 GND**，插上板子、上电，确认无异常再接 TX/RX。

---

## 3. 烧 microSD 卡 / U 盘

在**构建机**上做（注意：写卡会清空目标设备）。脚本在移植仓库里，不在 OpenWrt 树里：

```bash
cd <移植仓库>                       # 本文写作时是 /home/max/Code/rockpi4bp
scripts/deploy.sh --list            # 先看有哪些设备
scripts/deploy.sh --verify          # 只校验镜像，不写任何设备
sudo scripts/deploy.sh /dev/sdX     # squashfs（默认）
sudo scripts/deploy.sh /dev/sdX ext4   # 可写根
```

`--list` 会打印所有块设备、容量、型号、挂载点。**这一步别跳过** —— 它是防止写错盘的关键。

第二个参数选镜像变体：`squashfs`（默认）或 `ext4`。两者共用同一份 manifest，包集合相同，
区别只在根文件系统类型。

脚本会：
- 先用 `sha256sums` 校验镜像（不用 `gzip -t`，原因见 §1）
- 把镜像展开到临时文件并检查解压后的大小，**在擦盘之前**
- 拒绝分区（`/dev/sda1`）、eMMC 的 `boot0`/`boot1`/`rpmb`、系统盘、非块设备
- 要求你**输入设备路径二次确认**

手动等价命令：

```bash
gzip -dc openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

> 用管道时注意：gzip 会因为上面说的元数据尾部返回 2。数据其实是完整的
> （576 MiB 全部解出），但如果你的 shell 设了 `set -o pipefail`，管道会返回非零。
> `deploy.sh` 是先展开再 `dd`，就是为了绕开这个坑。

---

## 4. 上电前检查

- [ ] 卡已插好
- [ ] 电源用 **USB-C PD/QC 5V/2A 以上**（V1.73 起用的是 CH224D 触发芯片）
- [ ] 先接串口，**再上电**（否则会错过 U-Boot 阶段的日志）
- [ ] 键盘/显示器可选（HDMI 本次划出范围：内核无 DRM 驱动，见 README）

---

## 5. 首次启动该看什么

### 阶段 A：U-Boot

串口有输出就说明 SPI 里的 U-Boot 跑起来了、DRAM 初始化成功 —— **这一环已经在 5 次
上机中反复验证过**，不再是未知数。

期望看到类似：

```
U-Boot 2025.10 ...
DRAM:  ...
```
或 RK3399 SPL 的 `SPL_LOAD U-Boot` / `Trying to boot from ...`。

可能看到这条，**无害**：

```
Loading Environment from SPIFlash... *** Warning - bad CRC, using default environment
```

SPI 里的环境变量 CRC 是坏的，所以回退到默认环境变量 —— 而默认的 `BOOT_TARGETS`
已经同时包含 eMMC 和 USB，照样能引导。想启用 SPI 环境变量需先擦写 `u-boot.env`。

**若串口完全没有任何输出**：先按顺序排除
1. 波特率是不是 1500000
2. TX/RX 有没有交叉
3. 是不是插到了 RS-232 电平的转换器上
4. 以上都对 → 才是 DRAM 初始化失败，这时需要看有无任何偶发字符

看不到任何东西时，**先怀疑波特率和接线，再怀疑固件** —— 别过早下结论说"没跑起来"。

### 阶段 B：内核启动

期望：

```
Starting kernel ...
[    0.000000] Linux version 6.12.94
[    ...] rockchip-rk3399 ...
[    ...] Machine model: Radxa ROCK 4B+
```

`Machine model` 出现 `Radxa ROCK 4B+` 就说明**设备树被正确识别**。

### 阶段 C：进系统

首次启动偏慢属正常（首次展开 rootfs）。之后串口登录（默认无密码）：

```sh
ubus call system board          # 应显示 Radxa ROCK 4B+
cat /proc/cmdline
```

---

## 6. 烧完核对清单

下面是**回归核对**用的 —— 每一项都是板上实测到的值，可以逐条比对。

### 串口日志里要确认的

**1. 不再有 `-517` / `deferred probe pending`**（第一次上机的连锁故障信号，早已消失）

```
vcc-3v3-regulator:      deferred probe pending: -517      ← 应无
fe300000.ethernet:      failed to get phy regulator      ← 应无
sdio-pwrseq:            external clock not ready          ← 应无
```

**2. RK808 probe 成功**

```
rk808-rtc rk808-rtc.2.auto: registered as rtc0
fan53555-regulator 0-0040: FAN53555 Option[8] Rev[1] Detected!
fan53555-regulator 0-0041: FAN53555 Option[8] Rev[1] Detected!
```

**3. 进到登录提示**

```
procd: - init -
Please press Enter to activate this console.
urngd: v1.0.2 started.
```

**4. dtb 大小对得上**

U-Boot 加载 FIT 时会打印：

```
Description:  ARM64 OpenWrt radxa_rock-4b-plus device tree blob
Data Size:    63877 Bytes = 62.4 KiB
```

⚠️ **dtb 大小随镜像版本变，别把它当成常量。** 演进过：

| 字节数 | 对应哪一版 |
|---|---|
| 63273 | 缺 4 个板级 override |
| 63956 | 补上 WiFi/BT/音频 |
| 63779 | 删掉 gpio-keys |
| 63787 | WiFi 供电时钟改名 `lpo` → `ext_clock` |
| **63877** | 加上 `&spi1` + `flash@0`（**当前**） |

数值不符说明烧的是旧镜像 —— 但**要以构建产物为准**，别照抄本文：
`stat -c%s build_dir/target-aarch64_generic_musl/linux-rockchip_armv8/image-rk3399-rock-4b-plus.dtb`

### 进系统后逐项检查

**网口**

```sh
dmesg | grep -iE "stmmac|RTL8211"
ip link
```

期望 `RTL8211F Gigabit Ethernet stmmac-0:00: attached PHY driver` +
`br-lan: port 1(eth0) entered blocking state`。
`ip link` 显示 `NO-CARRIER` 只是没插网线，PHY 已 attach。插上线应能从
`192.168.1.1` 打开 LuCI。

**WiFi**

⚠️ **OpenWrt 出厂配置里 `default_radio0.disabled='1'`**，所以开机会看到
`wlan0 ... state DOWN`、扫描 0 个 BSS。**这不等于芯片坏了** —— 先把接口拉起来再扫：

```sh
dmesg | grep -iE "mmc2|brcmfmac|sdio-pwrseq"
cat /sys/kernel/debug/gpio | grep -i reset
ip link show wlan0                        # ⚠️ busybox 的 ip 不支持 -br
ip link set wlan0 up
iw dev wlan0 scan | grep -c '^BSS'
```

期望：

```
mmc2: new ultra high speed SDR104 SDIO card
gpio-10 (|reset) out hi                              芯片出复位
brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/9 wl0: ... version 7.84.17.1
3: wlan0: <BROADCAST,MULTICAST>  link/ether 08:fb:ea:65:f8:da
15                                                     扫到的网络数（会变）
```

`brcmf_c_preinit_dcmds` 那一行是关键 —— 它出现就说明芯片真的在跑固件并响应驱动。
**没有 `HT Avail timeout`** 就是修好了。

⚠️ 用 `ip link show`，不要用 `ip -br link show` —— busybox 的 `ip` 不支持 `-br`，
返回空，看起来像"没有无线网卡"。

早期版本 `wlan0` 不出现，两个阶段的原因完全不同：

- 缺 `brcmfmac43456-sdio.bin`（non-free 固件缺口）
- 固件装上了、上传也成功，但芯片起不来：`brcmf_sdio_htclk: HT Avail timeout` ——
  根因是 `sdio-pwrseq` 的时钟属性名写成 `lpo`，驱动只认 `ext_clock`，导致 32.768 kHz
  时钟从未使能。完整分析见 [wifi.md](wifi.md) 的第 0 节。

如果 `wlan0` 出现、固件也在跑，但扫不到网络，那是 regdb / 射频功率 / 信道设置问题，
与本移植无关（`CONFIG_CFG80211_CRDA_SUPPORT` 在 OpenWrt 内核里未开，属于上游取舍）。

**recovery / Maskrom 按键**

```sh
cat /sys/kernel/debug/gpio | grep -i recovery
```

期望**无输出** —— 板载按键是 **Maskrom / Reset / Recovery 三颗**，前两颗由 boot ROM 和
引导程序在上电瞬间采样，Linux 侧不存在对应输入，所以 DTS 里刻意没有 gpio-keys 节点。
⚠️ 这条命令与 Recovery 键**是否存在无关**（它是实物）；⚠️ 也不要从无输出推断按键不存在。
⚠️ **按键已实测能进 maskrom、且不必短接 SPI** —— 见
[hardware.md](hardware.md#板载按键maskromresetrecovery)。

**eMMC / SPI**

```sh
lsblk                              # 应看到 mmcblk0 28.9 GiB
dmesg | grep -iE "mmc0|HS400"
```

**板型与识别**
```sh
cat /proc/device-tree/model       # 应为 Radxa ROCK 4B+
ubus call system board
cat /proc/cmdline
ls /sys/class/leds/               # 蓝色状态灯 gpio3_PD5
```

**板载按键**

板上是 **Maskrom / Reset / Recovery 三颗按键**。前两颗由 **boot ROM 与引导程序在上电瞬间**
采样 —— 按住 **Maskrom 或 Recovery** + 上电即进 maskrom（**不必短接 SPI**），
**Linux 侧不存在对应输入**。所以 DTS 里刻意没有 gpio-keys 节点，
`/sys/kernel/debug/gpio | grep -i recovery` 应无输出。

进 maskrom 的步骤见第 7 节末尾和第 9 节。

---

## 7. 出了问题怎么回退

**最坏情况（板子起不来）**：从 U 盘重新烧一次即可。U-Boot 在 **SPI Flash** 上，
`dd` 写 eMMC 不碰 SPI，所以引导链不会被污染。

### 装到 eMMC（32G 板载）

镜像分区布局（DOS/MBR，磁盘标识 `0x5452574f`）：

| 分区 | 扇区 | 大小 | 内容 |
|---|---|---|---|
| p1 | 65536–98303（可启动） | 16 MiB | kernel FIT |
| p2 | 131072–1179647 | 512 MiB | rootfs |

**镜像自带引导程序**：**LBA 0x40 放 rkimage 容器（TPL+SPL），LBA 0x4000（8 MiB）
放 U-Boot 本体的 FIT**。这是 OpenWrt rockchip 镜像机制本来就有的行为 ——
`target/linux/rockchip/image/Makefile` 用 `gen_image_generic.sh ... 32768` 留
32 MiB，然后 `dd if=$(UBOOT_DEVICE_NAME)-u-boot-rockchip.bin of=$@ seek=64`。
所以镜像**不依赖 SPI 上的任何东西**，可以独立启动。
U-Boot 的 `BOOT_TARGETS` 是 `"mmc1 mmc0 nvme scsi usb pxe dhcp spi"`，
`mmc0` 就是 eMMC，排在 USB 之前。**写完直接插电就能起，不用改 U-Boot 环境变量。**

> ⚠️ **本文早期版本写着「镜像里不含 TPL/SPL/idbloader —— SPI 上已有 U-Boot，够了」。
> 那是错的，而且从未验证过。** 实测镜像字节 0x8000 就是 rkimage 头，8 MiB 处有
> `d00dfeed`。和下面那条是同一类错误：**没查就写**，方向还恰好相反。

> **引导程序在 eMMC/SD 上的位置是 LBA 0x40，不是 LBA 0。** RK3399 的 boot ROM 在
> `0x40` 扇区（字节 0x8000）找 idbloader，这与 `defconfig` 头部那句
> *"Boot flow: idbloader.img at LBA 0x40, u-boot.itb at LBA 0x4000"* 一致。
>
> 判据：Armbian 镜像字节 0x8000 处的头 8 字节 `3b 8c dc fc be 9f 9d 51`，
> 与 rkimage 容器一致。
>
> ⚠️ 查这一段时容易踩坑：**只看偏移 0 会误判成「Armbian 镜像里根本没有引导程序」**。
> 偏移 0 只有 MBR 和零。这个错误结论一度把恢复方向带偏成
> 「必须从外部重新获取一份引导程序」。

⚠️ **从 U 盘启动时不要用 `sysupgrade`**。此时 root 在 `/dev/sda2`，
sysupgrade 会把 U 盘当成升级目标，等于覆盖你自己的启动盘。走手工 `dd`。

### ⚠️ eMMC 上有什么：先只读地看清，再决定

**这一步不能跳过。** `dd` 会覆盖整盘，**不可逆**。

本文档早期版本把 eMMC 描述成"一个裸分区 `mmcblk0: p1`，没有大小也没有名字，内容未知"
—— **那是错的**，当时的结论来自启动日志里没有分区名，**而没有实际去读**。
只读挂载一看就清楚了 —— 而且**从启动日志读不出来**：日志里看不到分区名，不代表盘上是空的。

**eMMC 布局的变迁**（这一节改过四次）：
一套完整 Armbian → 被 `dd` 覆盖、无备份 → 重装 Armbian → 10-06 写入 OpenWrt 镜像
（Maskrom 整包，p1 16 MiB + p2 512 MiB）→ **10-08 又装回 Armbian**。

⚠️ **2026-10-08 当前实测** —— 单个 28.6 GB ext4，`root=UUID=7043da66-…`：

```
lsblk
  mmcblk0   28.9G
  └─mmcblk0p1  28.6G  ext4  /
```

⚠️ **不要相信上面的变迁描述** —— 每次状态都不同。动手前先只读地读：

```sh
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,PARTLABEL
cat /proc/cmdline | tr ' ' '\n' | grep -E "root=|ubootpart="
```

⚠️ **原始那套 Armbian（1.5 GB、含用户 `rock` 家目录）在更早的一次 `dd` 里被覆盖且
没有备份。**

**覆盖之前先备份。** 先只读地看清里面是什么：

```sh
mkdir -p /mnt/emmc && mount -o ro /dev/mmcblk0p1 /mnt/emmc
ls -la /mnt/emmc
cat /mnt/emmc/etc/os-release 2>/dev/null | head -3
ls -la /mnt/emmc/boot/ /mnt/emmc/home/ 2>/dev/null
du -sh /mnt/emmc
umount /mnt/emmc
```

**备份放哪里也要先算清楚**：U 盘 sda2 只有约 466 MB 可用，装不下 1.5 GB 的
rootfs。构建机有 20 GB，可以直接通过网络拉：

```sh
# 在构建机上执行
ssh root@<board> "tar -C /mnt/emmc -czf - ." > armbian-emmc-backup.tar.gz
```

**判断当前引导源**，避免把运行中的系统覆盖掉：

```sh
sed 's/.*root=//;s/ .*//' /proc/cmdline      # root= 指向哪块盘
cat /proc/partitions | grep -E 'mmcblk0|sda'
```

只有当 `root=` **不**指向 `mmcblk0` 时才安全。写之前还要断言：目标是整盘而非分区、
不是 `mmcblk0boot0/boot1/rpmb`、且未被挂载。

确认可以覆盖后：

```sh
# 把镜像传到板子上，并在板上校验哈希 —— 传错了 dd 出去的就是垃圾
scp openwrt-rockchip-armv8-radxa_rock-4b-plus-ext4-sysupgrade.img.gz root@<board>:/root/emmc.img.gz
ssh root@<board> sha256sum /root/emmc.img.gz      # 与构建机 sha256sums 比对

ssh root@<board> 'gzip -dc /root/emmc.img.gz | dd of=/dev/mmcblk0 bs=4M conv=fsync; sync'
```

**写完必须读回验证**，不要只看 `dd` 的退出码：

```sh
ssh root@<board> '
  echo -n "image : "; gzip -dc /root/emmc.img.gz | sha256sum | cut -d" " -f1
  echo -n "device: "; dd if=/dev/mmcblk0 bs=1M count=576 2>/dev/null | sha256sum | cut -d" " -f1
'
```

两个 sha256 必须一致。

⚠️ **2026-10-06 那次 `dd` 的校验确实一致**（`5847c611…`），**但那次之后 eMMC 被重装了**
（变砖救回过程中的操作），所以现在盘上不是那个布局。上面「先只读地看清」一节里记的是
**当前**实测状态。`5847c611…` 这个值只说明当时写对了字节，不是盘上现在的内容。

写完的 MBR 应当是（当时实测）：

| 分区 | 类型 | 起始 LBA | 大小 |
|---|---|---|---|
| p1 | `0x41` FAT32，可启动标志 `0x80` | 65536 | 32768 扇区 = 16 MiB |
| p2 | `0x83` Linux | 131072 | 1048576 扇区 = 512 MiB |

**注意 p1 是 FAT32 文件系统，不是裸 FIT。** U-Boot 通过 FAT 读里面的
`kernel.itb`，所以在分区起始处找 FIT 魔数 `d00dfeed` 会返回 0，那是正常的，
不代表写坏了 —— 判断依据是上表的分区表和整体 sha256。

**为什么 dd 是安全的**：镜像本身就是 576 MiB 的完整整盘镜像（p2 末尾扇区
1179647 已到镜像边界），`dd` 写完布局就对了。ARM mbr 设备的 sysupgrade 内部
做的也是同一件事，只是额外补写分区表 —— 这里不需要。

**不要写 `/dev/mmcblk0boot0` / `boot1` / `rpmb`**：那是 eMMC 的 boot 分区，
Rockchip 的 U-Boot TPL 不从那里读，动了反而可能出问题。

**不要用 `sysupgrade` 装到 eMMC**：从 U 盘启动时 root 在 `/dev/sda2`，sysupgrade
会把 U 盘当成升级目标。

### 装完如何确认真的从 eMMC 引导

✅ **已验证过一次**（tty8，2026-10-06，Maskrom 写整包）：`mmc@fe330000.bootdev.part
/boot.scr` → `VFS: Mounted root (ext4 filesystem) on device 179:2`。

⚠️ **但那次之后同一份镜像又出现了随机 panic**（6 次启动 3 次崩）。所以
"能从 eMMC 引导"已验证，**"能稳定引导"没有** —— 见
[postmortem-dram-instability.md](postmortem-dram-instability.md)。

⚠️ **两个介质同时插着也能启动**（`BOOT_TARGETS` 里 `mmc0` 排在 `usb` 之前），
所以要确认引导源，**必须先拔掉 microSD/读卡器**：

```sh
# 断电、拔掉 microSD、上电，然后：
sed 's/.*root=//;s/ .*//' /proc/cmdline     # 不再是 PARTUUID=...-02
cat /proc/partitions | grep -E 'mmcblk0|sda' # 应当只有 mmcblk0，没有 sda
```

⚠️ 注意 SPI 上是 **Armbian 的 U-Boot**（稳定，6 次零 panic）。它引导 eMMC 只说明
"Armbian 的 TPL 能引导 eMMC"，**不能用来证明本移植的引导程序可用**。

如果起不来，回退方式：插 microSD。U-Boot 的 boot 链会自动往后走到 `usb`
（这条已经多次走通）。

### 最后一层兜底：Maskrom 模式

**这是唯一能改写 SPI 上引导程序的路径。** 板子起不来、microSD 也救不回来时的最后手段。

板载按键是 **Maskrom / Reset / Recovery 三颗**（2026-10-10 目视确认）—— **Linux 侧看不到
任何事件**，所以 DTS 里没有 gpio-keys 节点。按键的硬件事实与板型辨识见
[hardware.md](hardware.md#板载按键maskromresetrecovery)。

⭐ **2026-10-10/11 实测：按住板上的 Maskrom 或 Recovery 键就能进 maskrom，不用短接 SPI。**
重复多次每次都成功，`log/tty19.txt` 有完整串口记录：

```
① 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
② 主板未供电前按住 Maskrom 或 Recovery 按键
③ 使用电源适配器给主板供电
④ 主板供电后松开按键
若主板电源绿灯常亮，说明成功进入 Maskrom 模式。
```

成功后 PC 上会枚举出 Rockchip 的 maskrom USB 设备（旧 wiki 记录为 `2207:330c`），
用 `rkdeveloptool` 或官方 `rk3399_loader` 刷写。

### ⚠️⚠️ 如果板子是**引导程序坏了**，用下面这条，不是上面那条

⚠️ **2026-10-11 测出机制之后，这一点从"方便"变成了"关键"。** 串口记录显示按键这条路是
**U-Boot proper** 发现按键后自己复位进 maskrom 的：

```
download key pressed, entering download mode...resetting ...
```

也就是说**它要先有一个能跑起来的 U-Boot proper**。⚠️ **引导程序跑不起来时按键能不能救回来，
没有测过。** 而那正是需要救砖流程的场景 —— ⚠️ **不要因为按键更方便就把它当唯一入口。**

**引导程序坏掉时唯一已知可用的是 Radxa 官方五步流程（短接那步不能省）：**

```
① 若主板有 SPI Flash，需将 SPI Flash 对应引脚接 GND
② 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
③ 主板未供电前按住 Maskrom 按键
④ 使用电源适配器给主板供电
⑤ 主板供电后松开 Maskrom 按键
```

第 ① 步买的是**由 ROM 直接进 maskrom，不依赖引导程序**。⚠️ 官方流程只写了按 Maskrom 键，
**Recovery 键 + 短接的组合没有测过**。

⚠️ 选错 loader 会静默写到另一块介质 —— **两条路都一样**，这是另一个坑，见下。

⚠️ **不是"SPI 排第一所以按键没用"** —— 它确实枚举出了设备；也**不是**"按键优先级高于 SPI"
—— 按键根本没参与 ROM 的介质选择。机制见
[boot-order.md](boot-order.md) 与 [hardware.md](hardware.md#板载按键maskromresetrecovery)。

> ⚠️ **但别把"短接"读成"绕过 SPI 的手段"。** 实测短接**不会**让 boot ROM 跳过 SPI
> —— 短接后 `mtd0` 消失，但串口第一行仍是 SPI 里的 TPL。**SPI 排第一、读到就赢。**
> 详见 [boot-order.md](boot-order.md)。

✅ **两条进 maskrom 的路径都在真机验证过**（2026-10-06 官方五步含短接 SPI；
2026-10-10 板上按键直进、不短接，重复多次）。这条路径可用，比整机报废值得好得多。

⚠️ **⚠️ 但请读这一条再照做：`rk3399_loader` 是 eMMC loader，它不写 SPI。**
它初始化的是 eMMC，之后 `wl` 只对 eMMC 生效 —— **用错 loader 时 `wl` 会报"成功"，
只是写到另一块介质，没有任何警告。** SPI 要用 `rk3399_loader_spinor_*.bin`，**或者**用普通 loader 再 `rkdeveloptool cs 9`
  （`9=SPINOR`）。上面那句"已在真机验证过"验证的是**进 Maskrom 这个流程**，
  不是"它能写 SPI"。机制与已就绪的 payload 见
  [boot-order.md 的 SPI 一节](boot-order.md#spi-现在可以写了2026-10-09)。

写 SPI 用专用脚本，不要手敲 `wl`：

```bash
scripts/flash-spi.sh --check                            # 只读，先跑这个
scripts/flash-spi.sh --plan                             # 再看命令
scripts/flash-spi.sh --write --loader <spinor-loader>   # 真写
```

脚本在写之前会 `cs 9` 确认介质、**写完之后 `rl` 读回来逐字节比对**。
读回走的是 ROM loader，不是 Linux —— 所以它不受
[boot-order.md 记的那个 SPI 读不对的问题](boot-order.md#linux-从这块-spi-读不到正确的内容)
影响，是这块芯片第一次可信的读。

⚠️ **`--write` 一次都没在硬件上跑过**，loader 版本也未定（见该节）。

⚠️ **不要手拼 `idbloader-spi.img` + `u-boot.itb`。** SPI 要的是 `rkspi` 容器
（每 4 KiB 页只用前 2 KiB、后面补零），U-Boot 本体在 `0xE0000` 而不是 `0x4000`；
两者和偏移都由 U-Boot 构建合成了单个 `u-boot-rockchip-spi.bin`，
`assert-spi-boot-image.py` 会验它确实是同一次构建的 rkspi 变体。
⚠️ **混用两个容器会停在 SPL 之后** —— 那看起来像引导程序坏了，不像文件选错了。

✅ **`recovery/` 里现在就是当前构建的字节** —— 10-09 重新放入 10-08 那个 6 次连续
零 panic 的构建。用之前先核对：

```
cd recovery && sha256sum -c SHA256SUMS.txt
```

⚠️ **但别默认它永远是最新的。** 这个目录**已经骗过一次人**：它长期放着 base 构建的
产物，而那份已知 6 次启动 3 次 panic —— 在紧急时刻去拿，拿到的就是一个已知半坏的
引导程序。所以规矩是：**每次用之前都核对哈希**，或者直接从当前构建目录取：

```
build_dir/target-aarch64_generic_musl/u-boot-rock-4b-plus-rk3399/u-boot-2025.10/
```

---

## 8. 板型、版本与 SPI 环境变量

板型辨识、早期版 vs V1.73 量产版的区别，见 [hardware.md](hardware.md)。这里只记一条
与恢复相关的：

**这块板贴了 4MB SPI Flash（早期版，约 V1.6/V1.72）。** 判据是串口日志里的
`SF: Detected XT25F32B ... total 4 MiB`。

日志里这条**无害**：

```
Loading Environment from SPIFlash... *** Warning - bad CRC, using default environment
```

CRC 坏了所以用默认环境变量 —— 而默认的 `BOOT_TARGETS` 已经同时包含 eMMC 和 USB，
照样能引导。

⚠️ **但别把 `bad CRC` 归因于缺 `/etc/fw_env.config`。** 早先文档这么写过，**已撤回**
—— 这条消息从项目最开始就有，早于 SPI 节点、也早于短接 SPI 实验，所以不是缺配置文件
造成的。更可能的原因是这块 SPI 在 Linux/U-Boot 下读不到正确内容，但**没有证据，
不下结论**。见 [boot-order.md](boot-order.md#linux-从这块-spi-读不到正确的内容)。

---

## 9. SPI 里的 U-Boot 起不来时怎么救（DRAM 初始化失败）

> 排查过程（含几条走错的岔路）、根因、方法论陷阱、以及哪些部分已验证/未验证，记在
> [postmortem-u-boot-ddr.md](postmortem-u-boot-ddr.md)。本节只讲怎么救。

### 当前状态（2026-10-06）

**板子已恢复可用。SPI 上是 Armbian 的 U-Boot（稳定），eMMC 上是本移植的引导程序
（不稳定）。** 这一节保留下来是因为流程仍然有效，而且下面几条结论是**实测排除**的。

| | 状态 |
|---|---|
| Maskrom 恢复流程 | ✅ **已在真机验证**（官方 `rk3399_loader` + Armbian 引导程序） |
| **Maskrom 写 eMMC 整包** | ✅ **已验证**（`rkdeveloptool wl 0 <镜像>`），**不碰 SPI** |
| 本移植的 U-Boot 是否跑过 | ✅ **跑过了** —— `rockchip,sdram-params` 修复确认生效 |
| ⚠️ 但**稳定性** | ❌ **base 版 6 次启动 3 次内核 panic**（函数指针被指向垃圾地址）。✅ `+vdd_log` 构建 **6 次连续零 panic，达到判据** |
| 根因 | **DRAM 初始化** —— 同样的内核/dtb/rootfs 用 Armbian 的 TPL 零 panic |
| 风险落在哪 | ⚠️ **不限于这台板子** —— 任何用这份引导程序的板子都有 50% 概率 panic |

⚠️ **早先写"决定不写 SPI，保留那份可用的"是对的**，但理由变了：不是"我们的引导程序
没验证过"，而是"**我们的引导程序验证出问题了**"。写 SPI 只会把一个不稳定的引导程序
放到所有板子的启动路径上。

**当前该做的**：拿到 Armbian 的 U-Boot 源码，比对它的 `rk3399-sdram-*.dtsi` 和
`drivers/ram/rockchip/`，找出差异。**在比对之前不要改参数。**

如果确实要用 Maskrom 写 SPI：把 `idbloader-spi.img` + `u-boot.itb` 写进去，上电看串口
第一行是否变成 `U-Boot TPL 2025.10-OpenWrt-…`。失败按同一流程刷回
Armbian（SPI 上只有引导程序，完全可从镜像文件复现）。

### 症状：串口只到 TPL 就停

```
U-Boot TPL 2025.10-OpenWrt-r33051-f5dae5ece4 (Jun 29 2026 - 12:59:20)
rk3399_dmc_of_to_plat: Cannot read rockchip,sdram-params -1
DRAM init failed: -1
Trying to boot from BOOTROM
Returning to boot ROM...
```

没有 SPL banner，没有 U-Boot banner，之后再无输出。

### 为什么换成 U 盘或 eMMC 都没用

RK3399 的启动顺序是 **SPI Flash → eMMC → SD**，SPI 在最前面。
**SPI 里只要有一个坏掉的 U-Boot，后面介质上的系统再好也轮不到。**

### 根因：U-Boot 的板级设备树缺 DRAM 参数

U-Boot 会按板名去找 `arch/arm/dts/<board>-u-boot.dtsi`。本板原来**没有**这个文件，
于是回退到通用的 `rk3399-u-boot.dtsi` —— 它不包含 `rockchip,sdram-params`，
TPL 拿不到 DRAM 参数就直接退出，连 SPL 都进不去。

**构建过程完全没有提示**：`idbloader.img` 正常产出、大小也正常，
只有把它刷进 SPI 之后才发现板子起不来 —— 而且到那时已经没法往 SPI 写东西了。

修复：`package/boot/uboot-rockchip/patches/0102-board-rockchip-Add-ROCK-4B-plus-U-Boot-dtsi.patch`
（源文件 `overlay/u-boot/rk3399-rock-4b-plus-u-boot.dtsi`）。细节与第二层坑见
[device-tree.md](device-tree.md#缺一个板级-u-boot-dtsi)。

### 修复后的产物

```
192512   idbloader.img        sha256 76bf3bcf…
385024   idbloader-spi.img    sha256 62e4142c…
1295360  u-boot.itb           sha256 37f1c604…
```

`rockchip,sdram-params` 现在在编译出的 `u-boot.dtb` 里（1530 个 u32），`binman` 节点也在。
修复前的对比：`idbloader.img` 180224 B → 192512 B，`rockchip,sdram-params` 从 0 处变成 1 处。

⚠️ **这个 sha256 只在源码未改动时稳定**，详见
[build.md](build.md#可复现的准确含义)。

### 恢复路线 A：microSD 卡上放一份好的引导程序（首选，不用拆板）

从 microSD 引导时，引导程序放 **LBA 0x40**（不是 LBA 0），理由见
[第 7 节](#装到-emmc32g-板载)。
**只用 `idbloader.img`**（192512 B，eMMC/SD 变体），**不要**用 `idbloader-spi.img`。

**Linux / 构建机上：**

```
dd if=idbloader.img of=/dev/sdX bs=512 seek=64 conv=fsync
```

**Windows 上：** 现成的 Etcher / Rufus 不合适 —— 192 KB 的镜像对几十 GB 的卡会被直接
拒写。仓库里带了一个只写这一处的脚本：

```powershell
.\scripts\write-idbloader-sd.ps1                          # ① 只列盘，什么都不写
.\scripts\write-idbloader-sd.ps1 -DiskNumber 2 -Preview    # ② 打印完整计划，仍不写
.\scripts\write-idbloader-sd.ps1 -DiskNumber 2             # ③ 真写
```

`-Preview` 会把镜像路径/大小/sha256、目标设备、偏移和落点全部打出来然后停下，
**不需要管理员权限**。② ③ 的输出除最后一行外完全相同，所以 ② 能确认 ③ 要干的正是
你以为是的那件事。

脚本做四件事：**只写 0x8000 处的 192512 字节，0 扇区的 MBR 和分区表完全不动**；
拒写任何被 Windows 判定为系统盘/启动盘的设备；拒写非 512 整数倍的偏移、以及放不下的偏移；
写完**读回校验 sha256**。③ 要手输 `YES` 才继续，没有默认值。

成功判据：串口打出 SPL 和 U-Boot banner。之后 U-Boot 先试 `mmc1`（卡上没有系统、失败），
再往后走。

⚠️ **只写 `idbloader.img` 是不够的。** 它只有 TPL+SPL（不含 U-Boot 本体），U-Boot 本体
在单独的 `u-boot.itb` 里、要去 LBA 0x4000。往一张空卡上只写 idbloader，板子会停在
SPL 之后。

⚠️ **更实际的做法：直接烧完整的镜像。** 镜像本身就带引导程序（见第 7 节），
`dd` 整盘下去就行，不用管什么 LBA。

> **这条路已被真机走通，但要注意它验证的不是本移植的引导程序。**
> 2026-10-06 实测：OpenWrt 从 microSD 完整启动 —— Armbian 的 U-Boot 从 SPI 起来，
> 在卡上找到 `/boot.scr`，加载 `Linux-6.12.94` 的 kernel FIT 和
> `radxa_rock-4b-plus` 的 dtb，crc32+sha1 校验通过。
>
> **卡上 LBA 0x40 那份我们自己的引导程序没有被执行过** —— boot ROM 试 SPI 成功就
> 不再看别处。镜像自带引导程序这件事只在**不贴 SPI 的板子**上才起作用，而那种板子
> 上这份引导程序尚未被验证过。

> 脚本本身被真卡测出过两个 bug（`-f` 被 `Write-Host` 当成参数、以及未校验扇区对齐），
> 所以才加了 `-Preview` —— 管理员门禁原本把碰磁盘的那半段挡在后面，导致它无法被执行验证。

### 恢复路线 B：Maskrom 重刷 SPI

见[最后一层兜底：Maskrom 模式](#最后一层兜底maskrom-模式)。

⭐ **引导程序还正常时**：按住板上的 Maskrom 或 Recovery 键上电即可，**不必短接 SPI Flash
引脚**，重复多次实测（2026-10-10/11）。

⚠️⚠️ **引导程序坏了时不要只按键。** 按键这条路由 **U-Boot proper** 触发
（`download key pressed, entering download mode...resetting ...`），它需要一个能跑起来的
U-Boot proper；⚠️ **跑不起来时能不能救回来没测过**。**那种情况走 Radxa 官方五步流程、
短接 SPI CLK（40-pin 23/25）** —— 那条由 ROM 直接进，不依赖引导程序。

✅ **两条都在真机验证过**（2026-10-06 官方五步含短接，救回过起不来的板子；
2026-10-10/11 按键直进不短接，`log/tty19.txt`）。

⚠️ **❌ 从 Linux 写 SPI 这条替代路径不可用 —— 已在真机验证。**
不是"读不稳定"，是**读到的不是芯片内容**。完整证据见
[boot-order.md](boot-order.md#linux-从这块-spi-读不到正确的内容)。

### ❌ 已验证无效：短接 SPI 引脚让 boot ROM 跳过 SPI

曾把这条当作"可逆的替代方案"推荐过 —— **在真机上测过，不成立**：

| 现象 | 说明 |
|---|---|
| 短接后 `mtd0` 消失 | 短接对 Linux 确实生效 |
| 串口第一行仍是 `U-Boot TPL 2022.07_armbian` | **boot ROM 照样从 SPI 加载引导程序** |
| `Loading Environment from SPIFlash` 仍出现 | U-Boot proper 也照样读 SPI |

结论：**SPI 在 boot ROM 里排第一，只要它能被读到就赢**，没有硬件手段绕过它**去改变
引导顺序**。要改 SPI 上的引导程序，Maskrom 是唯一一条路。

⭐ **但注意这条结论的范围**：它说的是"引导顺序绕过不了 SPI"，**不是**"进 maskrom
必须先短接 SPI"。2026-10-10 实测按住板上按键、不短接 SPI 也能进 maskrom。

⚠️ **2026-10-11 测出机制后，这里也要改一句**：串口里那两件事**不是同时发生的**，
是**有先后** —— ROM 正常把板子启动到 U-Boot proper，**U-Boot proper 自己发现按键、
自己复位**，ROM 才在复位后进 USB download 路径。所以按键**并不参与 ROM 的介质选择**，
而且**它依赖一个能跑起来的 U-Boot proper**；短接引脚那条由 ROM 自己做，不依赖引导
程序。详见 [硬件按键一节](hardware.md#板载按键maskromresetrecovery)。

### 进了系统之后不要试图修 SPI

原文档这里写的是"第一件事是把 SPI 修好"。**做不到** —— 读不回来就无法验证，
写下去是盲写。要修只能用 Maskrom。
