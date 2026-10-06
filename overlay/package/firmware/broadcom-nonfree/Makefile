# SPDX-License-Identifier: GPL-2.0-or-later

#
# Broadcom BCM43456 (AP6256) FullMAC SDIO firmware.
#
# The blob is proprietary and is shipped by neither linux-firmware nor any
# upstream OpenWrt package, which is why kmod-brcmfmac cannot bring up an AP6256
# out of the box: the driver derives the firmware name from the SDIO chip ID
# (0x4345 with chiprev bit 0x200 set) and then asks for exactly these files.
#
# PROVENANCE
#
#   RPi-Distro/firmware-nonfree, branch trixie, commit 3bab0f823f5b53150b76aab77093adef6655b920
#   debian/added-firmware/brcm/{brcmfmac43456-sdio.bin,.txt,.clm_blob}
#   Licence text extracted from debian/copyright in the same commit.
#
# That repository is used rather than fetched at build time because it is a
# Debian source package for the non-free blobs, so the licence travels with the
# files. The alternatives are worse:
#
#   Debian's own firmware-nonfree tarball is 105 MB for one 483 KB file, and its
#   20210315 revision no longer contains the 43456 blob at all.
#
#   armbian/firmware has the same files, but its README carries a blanket
#   statement about the proprietary ones: "Redistribution is limited to
#   non-commercial or usage-only contexts". An earlier revision of this package
#   vendored blobs from there, which meant shipping a proprietary file from a
#   repository that does not grant redistribution as a matter of policy. The
#   blob here is proprietary, so that policy is about this file.
#
# LICENCE
#
# RPi's debian/copyright has a stanza specific to these files:
#
#   Files: debian/added-firmware/*/*43456*
#   Copyright: Synaptics
#   License: Synaptics
#
# Note this is NOT the Broadcom SLA that covers "brcm/brcmfmac*.bin" in
# linux-firmware generally; the 43456 blobs are licensed separately by
# Synaptics, and an earlier revision shipped the wrong licence text alongside
# them. The grant, from the Synaptics DRIVER END USER LICENSE AGREEMENT (BINARY
# DISTRIBUTION), is:
#
#   "grants you a non-exclusive, non-transferable license ... to reproduce and
#    distribute the Software in object code form only, solely for use in
#    connection with Synaptics integrated circuit products"
#
# Three conditions follow, and this package meets all of them:
#
#   - object code form only: the blob is installed byte-for-byte, never
#     repackaged, and Build/Verify asserts its sha256
#   - no derivative works: "you may not (i) modify, adapt, or create derivative
#     works" -- hence the hash check
#   - solely for Synaptics ICs: the only consumer is brcmfmac driving a BCM43456
#
# The agreement is installed in /usr/share/licenses/broadcom/ alongside the blob.
# It also imposes an export-control obligation on whoever redistributes this
# image ("the Software may be subject to export control laws and regulations of
# the United States and other countries"), which is worth knowing before
# publishing a build.
#
# If you would rather not redistribute it: drop this package from
# DEVICE_PACKAGES in target/linux/rockchip/image/armv8.mk, then copy the three
# files onto the running system yourself. kmod-brcmfmac is already part of that
# device's package set and picks them up from /lib/firmware/brcm/ as-is.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=brcmfmac-firmware-43456-sdio
PKG_VERSION:=7.84.17.1
PKG_RELEASE:=2
PKG_LICENSE:=SYNAPTICS
PKG_MAINTAINER:=ROCK 4B+ port <port@local>

# The blob is named brcmfmac43456-sdio.bin but self-identifies with the build tag
# 43455c5-roml/43455_sdio. That tag is not a way to tell versions apart --
# Broadcom's build system uses it for the 43456 parts too. The internal version
# string is the discriminator.
#
# Other builds of the same filename exist in the wild, for example a 7.45.96.0
# one in armbian/firmware (482927 bytes, sha256 3167956a...). Neither this port's
# firmware tests nor any known report shows one of them bringing up a BCM43456
# where the others do not; see docs/WIFI-INVESTIGATION.md.

FW436_SRCDIR:=$(CURDIR)/files
FW436_SHA_BIN:=ddf83f2100885b166be52d21c8966db164fdd4e1d816aca2acc67ee9cc28d726
FW436_SHA_TXT:=44e0bb322dc1f39a4b0a89f30ffdd28bc93f7d7aaf534d06d229fe56f6198194
FW436_SHA_CLM:=2dbd7d22fc9af0eb560ceab45b19646d211bc7b34a1dd00c6bfac5dd6ba25e8a
FW436_SHA_LIC:=bb50f9742753dc3befc72e8000efaa05f6f98a7c633129f7a7e0202ce1e487e0

# Required. Without it the package is never registered: no Kconfig symbol is
# emitted, so DEVICE_PACKAGES writes a CONFIG_DEFAULT_<pkg>=y that has nothing
# to promote it, and the "compile" target that package.mk defines does not
# exist. The symptom points at package selection rather than at the Makefile.
include $(INCLUDE_DIR)/package.mk

define Package/brcmfmac-firmware-43456-sdio
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Broadcom BCM43456 (AP6256) FullMAC SDIO firmware
  LICENSE_FILES:=LICENSE.Synaptics
endef

define Package/brcmfmac-firmware-43456-sdio/description
  Firmware, CLM blob and NVRAM defaults for the Broadcom BCM43456 WiFi chip, as
  fitted to the Radxa ROCK 4B+ in an AP6256 module. brcmfmac selects this
  firmware name from the SDIO chip ID; without these files the module is
  enumerated on mmc2 but no network interface is ever created.
endef

# There is nothing to compile. This must be defined explicitly: the default
# Build/Compile cds into $(PKG_BUILD_DIR), which does not exist for a package
# with no sources, and the build then fails with no useful message.
define Build/Compile
	true
endef

# The Synaptics agreement forbids modification, so refuse to build if a vendored
# file drifted. OpenWrt has no PKG_HASH mechanism for in-tree files, hence the
# explicit check.
#
# Written as one logical line with backslash continuations on purpose: make runs
# each physical line of a recipe in a separate shell, so a here-document cannot
# span them. The checksum list is piped into sha256sum instead.
define Build/Verify
	cd "$(FW436_SRCDIR)" && { \
		echo '$(FW436_SHA_BIN)  brcmfmac43456-sdio.bin'; \
		echo '$(FW436_SHA_TXT)  brcmfmac43456-sdio.txt'; \
		echo '$(FW436_SHA_CLM)  brcmfmac43456-sdio.clm_blob'; \
		echo '$(FW436_SHA_LIC)  LICENSE.Synaptics'; \
	} | sha256sum -c - || { \
		echo "vendored 43456 firmware does not match the pinned sha256 -- refusing to build"; \
		exit 1; \
	}
endef

define Package/brcmfmac-firmware-43456-sdio/install
	$(INSTALL_DIR) $(1)/lib/firmware/brcm
	$(INSTALL_DATA) $(FW436_SRCDIR)/brcmfmac43456-sdio.bin      $(1)/lib/firmware/brcm/
	$(INSTALL_DATA) $(FW436_SRCDIR)/brcmfmac43456-sdio.txt      $(1)/lib/firmware/brcm/
	$(INSTALL_DATA) $(FW436_SRCDIR)/brcmfmac43456-sdio.clm_blob $(1)/lib/firmware/brcm/
	$(INSTALL_DIR) $(1)/usr/share/licenses/broadcom
	$(INSTALL_DATA) $(FW436_SRCDIR)/LICENSE.Synaptics \
		$(1)/usr/share/licenses/broadcom/LICENSE.Synaptics
endef

$(eval $(call BuildPackage,brcmfmac-firmware-43456-sdio))
