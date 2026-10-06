# ROCK 4B+ OpenWrt 25.12.5 — 烧卡与首次启动

## 1. 拿到镜像

在构建机上（`hyv-ub24`）：

```bash
ssh hyv-ub24 'cd /home/max/Code/openwrt && ls -lah bin/targets/rockchip/armv8/'
```

拉到本机（可选，方便留档）：

```bash
scp hyv-ub24:/home/max/Code/openwrt/bin/targets/rockchip/armv8/openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz .
scp hyv-ub24:/home/max/Code/openwrt/bin/targets/rockchip/armv8/sha256sums .
```

校验（**当前构建 `3d57e40`**）：

```
c218adcd8556d4cd3a7e87eaabe5f8de496571884b4847b4675f073c2ab33103  openwrt-rockchip-armv8-radxa_rock-4b-plus-ext4-sysupgrade.img.gz
bf684c3d6ac4d8e6aab56e6e716d27f0854927b98ffa355935229d8d73cc2a30  openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz
```

**历史校验和**（别搞混，sha256 变了就是不同镜像）：

| squashfs sha256 | 说明 |
|---|---|
| `6386de591b5f…` | WiFi/BT 修复前（`sdio0` disabled，芯片不上电） |
| `06b61b20dceb…` | 补上 4 个板级 override，WiFi 硬件层打通 |
| `9932b3dad4d2…` | 删掉猜测的 gpio-keys 节点，包集合修正 |
| `50092eba850c…` | 固件源与许可纠正前的最后一版 |

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

> **实际用的是 ext4，不是 squashfs。** 2026-10-06 上机验证的是 **ext4** 镜像
> （`e64004a0…`，177 个包）。两个镜像共用同一份 manifest，所以包集合相同
> （`brcmfmac-firmware-43456-sdio - 7.84.17.1-r2`），WiFi 行为不受影响 ——
> 但**squashfs 镜像至今未在真机上启动过**，要验证的话还得单独刷一次。
>
> 对 WiFi 排查而言 ext4 其实更合适：根文件系统可写，固件文件原生持久化，
> 不必再靠 overlay 那一层。`scripts/deploy.sh` 默认找的是 squashfs 镜像，
> 烧 ext4 需要手动指定文件名。

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
ssh hyv-ub24
/home/max/Code/rockpi4bp/scripts/deploy.sh --list          # 先看有哪些设备
/home/max/Code/rockpi4bp/scripts/deploy.sh --verify        # 只校验镜像，不写任何设备
sudo /home/max/Code/rockpi4bp/scripts/deploy.sh /dev/sdX           # squashfs（默认）
sudo /home/max/Code/rockpi4bp/scripts/deploy.sh /dev/sdX ext4      # 可写根
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

系统已四次上机验证通过，下面是**回归核对**用的 —— 每一项都是 tty5 日志里
实测到的值，可以逐条比对。

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
Data Size:    63787 Bytes = 62.4 KiB
```

`63787` 对应"WiFi 供电时钟改名为 ext_clock"这一版。数值不符说明烧的是旧镜像。

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

**WiFi 硬件层**

```sh
dmesg | grep -iE "mmc2|brcmfmac|sdio-pwrseq"
cat /sys/kernel/debug/gpio | grep -i reset
ip -br link show wlan0
iw dev wlan0 scan | grep -c '^BSS '
```

期望全部通过：

```
mmc2: new ultra high speed SDR104 SDIO card
gpio-10 (|reset) out hi                              芯片出复位
brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/9 wl0: ... version 7.84.17.1
wlan0    UP    08:fb:ea:65:f8:da
16                                                     扫到的网络数（会变）
```

`brcmf_c_preinit_dcmds` 那一行是关键 —— 它出现就说明芯片真的在跑固件并响应驱动。

**`63787` 字节的 dtb 才带 WiFi 修复。** 早期版本 `wlan0` 不出现，两个阶段的原因
完全不同：

- 缺 `brcmfmac43456-sdio.bin`（non-free 固件缺口）
- 固件装上了、上传也成功，但芯片起不来：
  `brcmf_sdio_htclk: HT Avail timeout` —— 根因是 `sdio-pwrseq` 的时钟属性名写成
  `lpo`，驱动只认 `ext_clock`，导致 32.768 kHz 时钟从未使能。修法见
  `docs/WIFI-INVESTIGATION.md` §0。

如果 `wlan0` 出现但扫不到网络，那是 regdb / 射频功率 / 信道设置问题，与本移植无关
（`CONFIG_CFG80211_CRDA_SUPPORT` 在 OpenWrt 内核里未开，属于上游取舍）。

**recovery / Maskrom 按键**

```sh
cat /sys/kernel/debug/gpio | grep -i recovery
```

期望**无输出** —— 板载按键是 Maskrom 键，由 boot ROM 在上电瞬间采样，Linux 侧
不存在对应输入，所以 DTS 里刻意没有 gpio-keys 节点。

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

板上是 **Maskrom 按键**，不是 recovery 键。功能由 **boot ROM 在上电瞬间**采样 ——
按住 + 上电即进 maskrom，**Linux 侧不存在对应输入**。所以 DTS 里刻意没有
gpio-keys 节点，`/sys/kernel/debug/gpio | grep -i recovery` 应无输出。

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

镜像里**不含** TPL/SPL/idbloader —— SPI 上已有 U-Boot，够了。
U-Boot 的 `BOOT_TARGETS` 是 `"mmc1 mmc0 nvme scsi usb pxe dhcp spi"`，
`mmc0` 就是 eMMC，排在 USB 之前。**写完直接插电就能起，不用改 U-Boot 环境变量。**

> **引导程序在 eMMC/SD 上的位置是 LBA 0x40，不是 LBA 0。** RK3399 的 boot ROM 在
> `0x40` 扇区（字节 0x8000）找 idbloader，这和 `defconfig` 头部注释里那句
> *"Boot flow: idbloader.img at LBA 0x40, u-boot.itb at LBA 0x4000"* 是一致的。
>
> 判据：Armbian 的镜像从字节 0x8000 开始出现高熵数据，其头 8 字节
> `3b 8c dc fc be 9f 9d 51` 与本移植产出的 `idbloader.img` 头 8 字节完全相同。
> 本镜像在 0x40 处是空的，这是有意的 —— 引导链在 SPI 上，见第 10 节。
>
> ⚠️ 查这一段时容易踩坑：**只看偏移 0 会误判成「Armbian 镜像里根本没有引导程序」**。
> 偏移 0 确实只有 MBR 和零，引导程序在 0x8000。这个错误结论一度把恢复方向
> 带偏成「必须从外部重新获取一份引导程序」。

⚠️ **从 U 盘启动时不要用 `sysupgrade`**。此时 root 在 `/dev/sda2`，
sysupgrade 会把 U 盘当成升级目标，等于覆盖你自己的启动盘。走手工 `dd`。

⚠️ **eMMC 上原本装着一套完整可用的 Armbian。** 本文档早期版本把它描述成"一个裸
分区 `mmcblk0: p1`，没有大小也没有名字，内容未知" —— **那是错的**，当时的结论来自
启动日志里没有分区名，而没有实际去读。只读挂载一看就清楚了：

```
$ mount -o ro /dev/mmcblk0p1 /mnt/emmc && ls /mnt/emmc
PRETTY_NAME="Armbian_community 26.11.0-trunk.62 trixie"   (etc/os-release)
$ ls /mnt/emmc/boot/
vmlinuz-6.18.54-current-rockchip64   initrd.img-6.18.54-current-rockchip64
armbianEnv.txt   boot.cmd   boot.scr   dtb-6.18.54-current-rockchip64
$ cat /mnt/emmc/etc/hostname
rockpi-4b
$ ls /mnt/emmc/home/
rock                                    ← 有用户数据
$ du -sh /mnt/emmc
1.5G
```

`dd` 会覆盖 MBR 和 p1/p2，**不可逆**，这套 Armbian 和 `/home/rock` 会永久消失。
2026-10-06 执行时是在明确告知后选择直接覆盖的。

**先只读地看清，再决定：**

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

两个 sha256 必须一致。2026-10-06 实测一致：
`5847c6118853b40a66587c220e484c50b19103e2df72e10a1f1ccd7a77ff760f`

写完的 MBR 应当是（实测）：

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

## 装完如何确认真的从 eMMC 引导

U 盘插着也能启动（`BOOT_TARGETS` 里 `mmc0` 排在 `usb` 前面），所以**要验证就必须
先拔掉 U 盘**，否则无法区分引导源：

```sh
# 断电、拔掉 U 盘、上电，然后：
sed 's/.*root=//;s/ .*//' /proc/cmdline     # 不再是 PARTUUID=...-02
cat /proc/partitions | grep -E 'mmcblk0|sda' # 应当只有 mmcblk0，没有 sda
```

如果 dd 完起不来，回退方式：插 U 盘。U-Boot 的 boot 链会自动往后走到 `usb`
（tty4/tty5 日志已经两次证明这条路走得通）。

### 最后一层兜底：Maskrom 模式

板载按键是 **Maskrom 按键**，不是 recovery 键。功能由 **boot ROM 在上电瞬间**
采样决定 —— Linux 侧看不到任何事件（这也是我从 DTS 里删掉 gpio-keys 节点的原因）。

Radxa 官方进 maskrom 的步骤：

```
① 若主板有 SPI Flash，需将 SPI Flash 对应引脚接 GND
② 使用 USB Type-A 转 USB Type-A 数据线连接主板和电脑
③ 主板未供电前按住 Maskrom 按键
④ 使用电源适配器给主板供电
⑤ 主板供电后松开 Maskrom 按键
```

成功后**电源绿灯常亮**，PC 上会枚举出 Rockchip 的 maskrom USB 设备，
用 `rkdeveloptool` 就能重新刷写。

⚠️ **第 ① 步对这块板是必需的** —— 本板贴了 4MB SPI Flash，不短接的话 SPI 里的
U-Boot 会先接管，拿不到 maskrom。

好消息是**只有进 maskrom 才需要短接 SPI**，正常的 SPI 引导（以及上面的 `dd`
路线）完全不受影响，短接也不用常做。

顺带一提：Radxa 文档说 4A/4B/4SE 用可拆卸 eMMC Module，而 **4A+/4B+ 是板载
eMMC，不支持热插拔模组**，所以 4B+ 刷机走的是 maskrom over USB 而不是模组读卡器。

---

## 8. 关于板型和版本的一点说明

这块板是 **ROCK (Pi) 4B Plus**，2022 年 Radxa 去掉了产品线名字里的 "Pi"，
所以也叫 ROCK 4+（详见项目 README 的"板型辨析"节）。

**你这块是有 4MB SPI Flash 的早期版（约 V1.6/V1.72），不是 V1.73 量产版。**
判据是 Radxa 官方 revisions.md：V1.73 起 SPI Flash 不贴装；
而 2021 年主线补丁里 Radxa 官方原话是 *"dev boards have SPI flash soldered,
but as per manufacturer response, this won't be the case for mass production boards"*。
串口日志里的 `SF: Detected XT25F32B ... total 4 MiB` 印证了这点。

实际影响：**U-Boot 保留 SPI 引导和环境变量支持**。上次日志出现过
`Loading Environment from SPIFlash... *** Warning - bad CRC, using default environment`
—— CRC 坏了所以用默认环境变量，**不影响启动**（后面照样正常引导了）。
如果后续想启用 SPI 环境变量功能，需要先擦写 SPI 里的 u-boot.env。

## 9. 备用：Maskrom 模式（详见第 7 节末尾）

板子起不来、U 盘也救不回来时的最后手段。**具体步骤见第 7 节"最后一层兜底：
Maskrom 模式"**，那里是照 Radxa 官方文档 `low-level-dev/maskrom` 抄的：
断电 → 按住 Maskrom 键 → 上电 → 松手，绿灯常亮即成功。

⚠️ 本板贴了 SPI Flash，**进 maskrom 前必须把 SPI Flash 引脚短接到 GND**，
否则 SPI 里的 U-Boot 会先接管，拿不到 maskrom。

成功后 PC 上会枚举出 Rockchip 的 maskrom USB 设备（旧 wiki 记录为 `2207:330c`），
用 `rkdeveloptool` 重新烧写。

**这条路径尚未在真机验证过**，但比整机报废值得好，所以记着。

### 关于按键数量的一个说明

旧 wiki 记的是"三个按键 maskrom / reset / recovery，同时按住 maskrom + reset 进
maskrom"。而 Radxa **当前**文档对 4A+/4B+ 的描述只提一个 **Maskrom 按键**，
且操作是"按住 + 上电"，没有提 reset 组合。

以官方文档为准。实测的硬件事实：**板载按键按下去没有任何 GPIO 电平变化**
（见 README"recovery 按键"小节），这与"按键由 boot ROM 在上电瞬间采样"一致 ——
如果它同时被 Linux 当输入用，按下就应该能在 debugfs 里看到变化。
另外 4B+ 没有独立的 recovery 功能键：maskrom 本身就是 Rockchip 的恢复入口。

---

## 10. SPI 里的 U-Boot 起不来时怎么救（DRAM 初始化失败）

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

> 同一个坑还有第二层。`scripts/Makefile.lib` 里那个 `wildcard` 是**优先级链、只取第一个命中**：
>
> ```
> u_boot_dtsi_options = $(strip $(wildcard <board>-u-boot.dtsi) $(wildcard $(CONFIG_SYS_SOC)-u-boot.dtsi) ...)
> # We use the first match to be included
> dtsi_include_list  = $(notdir $(firstword $(u_boot_dtsi_options)))
> ```
>
> 所以补上 `<board>-u-boot.dtsi` 之后，通用那份会被**顶掉**而不是叠加，
> 必须在这个文件里自己 `#include "rk3399-u-boot.dtsi"`，否则构建会停在
> `binman: Device tree './u-boot.dtb' does not have a 'binman' node`。
>
> 修复：`package/boot/uboot-rockchip/patches/0102-board-rockchip-Add-ROCK-4B-plus-U-Boot-dtsi.patch`
> （源文件 `overlay/u-boot/rk3399-rock-4b-plus-u-boot.dtsi`）。
> `scripts/build.sh` 里加了 4 条断言盯住这两件事。

### 修复后的产物

```
b8fa872f46d2654201c036b8a6d6d7276be786cb15cbecd5f86cb5faedf488bf  idbloader.img        192512 B
e8aaf9319e10a888e727ba5bfb3088a7a0bad3001259bcb085e46ef3c491bd85  idbloader-spi.img   385024 B
```

`rockchip,sdram-params` 现在在编译出的 `u-boot.dtb` 里（1530 个 u32），`binman` 节点也在。
两次独立构建的产物 sha256 完全一致。修复前的对比：`idbloader.img` 180224 B → 192512 B，
`idbloader.img` 里 `rockchip,sdram-params` 从 0 处变成 1 处。

### 恢复路线 A：microSD 卡上放一份好的引导程序（首选，不用拆板）

从 microSD 引导时，引导程序放 **LBA 0x40**，理由见第 7 节。**只用
`idbloader.img`**（192512 B，eMMC/SD 变体），**不要**用 `idbloader-spi.img`。

**Linux / 构建机上：**

```
dd if=idbloader.img of=/dev/sdX bs=512 seek=64 conv=fsync
```

**Windows 上：** 现成的 Etcher / Rufus 不合适 —— 192 KB 的镜像对几十 GB 的卡会被直接
拒写。仓库里带了一个只写这一处的脚本：

```powershell
# 以管理员身份打开 PowerShell
.\scripts\write-idbloader-sd.ps1                 # 先列盘，不带参数不写任何东西
.\scripts\write-idbloader-sd.ps1 -DiskNumber 2   # 按容量和型号选对卡
```

它做三件事：**只写 0x8000 处的 192512 字节，0 扇区的 MBR 和分区表完全不动**；
拒写任何被 Windows 判定为系统盘/启动盘的设备；写完**读回校验 sha256**。
第二步要手输 `YES` 才继续，没有默认值。

成功判据：串口打出 SPL 和 U-Boot banner。之后 U-Boot 先试 `mmc1`（SD 上没有系统、失败），
再走到 `mmc0`（eMMC 上的 OpenWrt 镜像），应该能直接进系统。

⚠️ **这条路没有在真机验证过。** 它赌的是：boot ROM 在 SPI 的 TPL 失败、并且已经
`Returning to boot ROM...` 交回控制权之后，会继续往下试 SD。那句 `Returning to boot ROM...`
说明控制权确实交回去了，所以有希望；但"会不会继续试"是未知的。赌输了走路线 B。

### 恢复路线 B：Maskrom 重刷 SPI

见第 7 节"最后一层兜底：Maskrom 模式"。**本板必须先把 SPI Flash 引脚短接到 GND**，
否则 SPI 里的 U-Boot 会抢先接管，拿不到 maskrom。

要写进 SPI 的是 **`idbloader-spi.img`**（385024 B，和 eMMC/SD 那份大小不同，不要混用）。
具体写入偏移按 `rkdeveloptool` / RKDevTool 的 SPI 布局，照 Radxa 官方文档来。
**这一步同样没有在真机验证过。**

### 进了系统之后，第一件事是把 SPI 修好

SD 卡只是拐杖。只要 SPI 里还是那份坏的引导程序，每次上电都会先撞上它。
从系统里写 SPI 时**务必确认写的是 SPI 变体**，写错变体就是再变一次砖。
