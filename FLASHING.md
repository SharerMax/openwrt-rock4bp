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

校验（**当前构建 `55a6a7f064`**）：

```
16a0cdd1be8490beee3f7531be1a71e7d6536f48bb2c99eaa3f356073170e0a1  openwrt-rockchip-armv8-radxa_rock-4b-plus-ext4-sysupgrade.img.gz
9932b3dad4d204c3f238e17399ec2edab07992846a2f1c4d47b7b805e9befc87  openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz
```

**历史校验和**（别搞混，sha256 变了就是不同镜像）：

| squashfs sha256 | 说明 |
|---|---|
| `6386de591b5f…` | WiFi/BT 修复前（`sdio0` disabled，芯片不上电） |
| `06b61b20dceb…` | 补上 4 个板级 override，WiFi 硬件层打通 |
| `9932b3dad4d2…` | 删掉猜测的 gpio-keys 节点，包集合修正（当前） |

**第一次建议烧 squashfs**（只读、损坏面小、启动快、便于反复重刷）。
ext4 版本适合后续要持久化数据或装大量包时再用。

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

## 3. 烧 microSD 卡

在**构建机**上做（注意：写卡会清空目标设备）：

```bash
ssh hyv-ub24
cd /home/max/Code/openwrt
lsblk                       # 确认哪块是 SD 卡
./scripts/deploy.sh /dev/sdX
```

脚本会打印目标设备、容量、型号，并要求你**输入设备路径二次确认**，也会拒绝写系统盘。

手动等价命令：

```bash
gzip -dc openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

---

## 4. 上电前检查

- [ ] 卡已插好
- [ ] 电源用 **USB-C PD/QC 5V/2A 以上**（V1.73 起用的是 CH224D 触发芯片）
- [ ] 先接串口，**再上电**（否则会错过 U-Boot 阶段的日志）
- [ ] 键盘/显示器可选（HDMI 本次划出范围：内核无 DRM 驱动，见 README）

---

## 5. 首次启动该看什么

### 阶段 A：U-Boot（最关键，也是最大的未知数）

要看到串口有输出，就说明 DRAM 初始化成功了 —— 这是整个移植里最不确定的一环
（U-Boot 的 defconfig 是从 ROCK 4SE 抄的，只改了两行 DT 引用）。

期望看到类似：

```
U-Boot 2025.10 ...
DRAM:  ...
```
或 RK3399 SPL 的 `SPL_LOAD U-Boot` / `Trying to boot from ...`。

**若串口完全没有任何输出**：先按顺序排除
1. 波特率是不是 1500000
2. TX/RX 有没有交叉
3. 是不是插到了 RS-232 电平的转换器上
4. 以上都对 → 才是 DRAM 初始化失败，这时需要看有无任何偶发字符

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
Data Size:    63779 Bytes = 62.3 KiB
```

`63779` 对应"补上 WiFi/BT override、删掉 gpio-keys"这一版。数值不符说明烧的是旧镜像。

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
```

期望 `mmc2: new ultra high speed SDR104 SDIO card` 和 `gpio-10 (|reset) out hi`
（芯片出复位）。`wlan0` **不会出现** —— 缺 `brcmfmac43456-sdio.bin`，这是已知的、
划出范围的 non-free 固件缺口，不是移植缺陷。

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

⚠️ **从 U 盘启动时不要用 `sysupgrade`**。此时 root 在 `/dev/sda2`，
sysupgrade 会把 U 盘当成升级目标，等于覆盖你自己的启动盘。走手工 `dd`。

⚠️ **eMMC 上已经有东西了。** 上机日志里只出现一个裸分区 `mmcblk0: p1`
（没有大小也没有名字），U-Boot 跳过它直接走了 USB —— 现有布局不是 OpenWrt
认识的。`dd` 会覆盖 MBR 和 p1/p2，**不可逆**。先只读地看清：

```sh
fdisk -l /dev/mmcblk0
blkid /dev/mmcblk0p1
mkdir -p /mnt/emmc && mount -o ro /dev/mmcblk0p1 /mnt/emmc && ls -la /mnt/emmc
```

确认可以覆盖后：

```sh
# U 盘的 sda1 已经挂在 /boot，把镜像拷进去
cp <img.gz> /boot/

gzip -dc /boot/openwrt-rockchip-armv8-radxa_rock-4b-plus-squashfs-sysupgrade.img.gz \
  | dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress

sync
poweroff
```

**为什么 dd 是安全的**：镜像本身就是 576 MiB 的完整整盘镜像（p2 末尾扇区
1179647 已到镜像边界），`dd` 写完布局就对了。ARM mbr 设备的 sysupgrade 内部
做的也是同一件事，只是额外补写分区表 —— 这里不需要。

**不要写 `/dev/mmcblk0boot0` / `boot1` / `rpmb`**：那是 eMMC 的 boot 分区，
Rockchip 的 U-Boot TPL 不从那里读，动了反而可能出问题。

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
