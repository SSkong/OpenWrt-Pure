#!/bin/bash
# H68K 设备支持（唯一需要改动内核/设备树的设备）
#
# 官方 OpenWrt 25.12 的 rockchip/armv8 没有 Hinlink H68K，必须 backport PR#21270：
#   - package/boot/uboot-rockchip：H68K U-Boot 目标
#   - target/linux/rockchip/image/armv8.mk：设备定义（镜像布局、DTS 绑定）
#   - target/linux/rockchip/dts/...：H68K 设备树
#   - base-files 的 board.d（网口/指示灯）、hotplug 网卡亲和性
# 另外补一个 RK3568 PCIe3 PHY SRAM 固件上传补丁：2022 旧版 H68K 的 PCIe3 PHY
# 内部 SRAM 自动加载永不完成（p3phy lock failed → probe -110），导致 eth2/eth3
# （RTL8125B 2.5G）不出现；该补丁手动上传 PHY 固件绕过硬件批次缺陷。
#
# 除以上两项，本仓库不改任何内核源码。
#
# 补丁应用的守卫语义（fuzz=0 预检 / .rej 扫描 / CRLF 检查）统一在 lib.sh，
# 与 Fullcone.sh 共用同一套，避免两份拷贝各自漂移。
set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || usage_die "H68K.sh <openwrt目录> <补丁目录>"
enter "$1"
PATCH_DIR="$2"
[ -d "$PATCH_DIR" ] || die "补丁目录不存在: $PATCH_DIR"

BACKPORT="${PATCH_DIR}/h68k-backport.patch"
PHYFW="${PATCH_DIR}/105-phy-rockchip-snps-pcie3-sram-firmware.patch"
require_file "$BACKPORT"
require_file "$PHYFW"
check_no_crlf "$PATCH_DIR"

# 补丁里的 DTS 与 U-Boot 补丁写死在 patches-6.12 路径下。内核主版本一变，它们会落到
# 一个不存在的目录里并静默失效——设备定义仍在，所以照样能编出固件，只是没有 H68K 支持。
# 这里直接拦住，避免产出"看起来成功但刷不进去"的镜像。
KPVER="$(sed -n 's/^KERNEL_PATCHVER[^0-9]*\([0-9][0-9.]*\).*/\1/p' target/linux/rockchip/Makefile 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$KPVER" ] || die "读不到 target/linux/rockchip/Makefile 的 KERNEL_PATCHVER"
[ "$KPVER" = "6.12" ] || die "rockchip 当前内核为 ${KPVER}，本套补丁只针对 6.12 编写与验证；升级内核需重新 rebase backport 与 PHY 驱动补丁后再改这里"
step "内核版本 ${KPVER}，补丁目标目录 patches-${KPVER}"

step "应用 H68K 设备支持补丁（PR#21270 backport）"
apply_patch_strict "$BACKPORT"
check_rej target package

# 设备定义必须真的进了 armv8.mk，否则 defconfig 会丢弃 DEVICE_hinlink_h68k
has_text 'Device/hinlink_h68k' target/linux/rockchip/image/armv8.mk ||
	die "armv8.mk 里没有 hinlink_h68k 设备定义"

step "应用 RK3568 PCIe3 PHY SRAM 固件补丁"
put "$PHYFW" "target/linux/rockchip/patches-${KPVER}" "$(basename "$PHYFW")"

# 确认 DTS 补丁确实落在当前内核的补丁目录（而不是被打进了一个新建的旧版本目录）
ls "target/linux/rockchip/patches-${KPVER}/"073-1-*H68K*.patch >/dev/null 2>&1 ||
	die "DTS 补丁没有落到 patches-${KPVER}"

step "H68K 补丁应用完成（U-Boot + DTS + 设备定义 + 网口映射 + PCIe3 PHY 固件）"
