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
set -u

cd "${1:?用法: H68K.sh <openwrt目录>}" || exit 1
PATCH_DIR="${2:?用法: H68K.sh <openwrt目录> <补丁目录>}"

echo "==> 应用 H68K 设备支持补丁（PR#21270 backport）"
if [ ! -f "${PATCH_DIR}/h68k-backport.patch" ]; then
	echo "ERROR: 找不到 ${PATCH_DIR}/h68k-backport.patch" >&2; exit 1
fi
patch -p1 --forward --no-backup-if-mismatch < "${PATCH_DIR}/h68k-backport.patch" || {
	echo "ERROR: H68K backport 补丁应用失败（上游内核/DTS 结构可能已变，需更新补丁）" >&2; exit 1; }

echo "==> 应用 RK3568 PCIe3 PHY SRAM 固件补丁"
if [ ! -f "${PATCH_DIR}/105-phy-rockchip-snps-pcie3-sram-firmware.patch" ]; then
	echo "ERROR: 找不到 PCIe3 PHY 补丁" >&2; exit 1
fi
cp -f "${PATCH_DIR}/105-phy-rockchip-snps-pcie3-sram-firmware.patch" \
	target/linux/rockchip/patches-6.12/ || {
	echo "ERROR: 无法写入 target/linux/rockchip/patches-6.12/" >&2; exit 1; }

echo "==> H68K 补丁应用完成"
