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

BACKPORT="${PATCH_DIR}/h68k-backport.patch"
PHYFW="${PATCH_DIR}/105-phy-rockchip-snps-pcie3-sram-firmware.patch"
for f in "$BACKPORT" "$PHYFW"; do
	[ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

# 补丁里的 DTS 与 U-Boot 补丁写死在 patches-6.12 路径下。内核主版本一变，它们会落到
# 一个不存在的目录里并静默失效——设备定义仍在，所以照样能编出固件，只是没有 H68K 支持。
# 这里直接拦住，避免产出"看起来成功但刷不进去"的镜像。
KPVER="$(sed -n 's/^KERNEL_PATCHVER[^0-9]*\([0-9][0-9.]*\).*/\1/p' target/linux/rockchip/Makefile 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$KPVER" ] || { echo "ERROR: 读不到 target/linux/rockchip/Makefile 的 KERNEL_PATCHVER" >&2; exit 1; }
if [ "$KPVER" != "6.12" ]; then
	echo "ERROR: rockchip 当前内核为 ${KPVER}，本套补丁只针对 6.12 编写与验证" >&2
	echo "       升级内核需重新 rebase backport 与 PHY 驱动补丁后再改这里" >&2
	exit 1
fi
echo "==> 内核版本 ${KPVER}，补丁目标目录 patches-${KPVER}"

echo "==> 应用 H68K 设备支持补丁（PR#21270 backport）"
# 先做 fuzz=0 预检：offset 可以接受（上游行号漂移是常态），fuzz 不可接受
# （意味着上下文已经变了，靠猜位置打进去）。
if patch -p1 --fuzz=0 --dry-run --forward < "$BACKPORT" >/dev/null 2>&1; then
	patch -p1 --fuzz=0 --forward < "$BACKPORT" >/dev/null || {
		echo "ERROR: H68K backport 补丁应用失败" >&2; exit 1; }
	echo "    精确应用（fuzz=0）"
else
	echo "    上下文有漂移，按默认 fuzz 应用"
	patch -p1 --forward --no-backup-if-mismatch < "$BACKPORT" || {
		echo "ERROR: H68K backport 补丁应用失败（上游内核/DTS 结构可能已变，需更新补丁）" >&2; exit 1; }
fi

# 部分失败的补丁会留下 .rej，绝不能当成功继续
rej="$(find target package -name '*.rej' -type f 2>/dev/null | head -5)"
[ -z "$rej" ] || { echo "ERROR: 补丁未完整落地，遗留 .rej 文件: $rej" >&2; exit 1; }

# 设备定义必须真的进了 armv8.mk，否则 defconfig 会丢弃 DEVICE_hinlink_h68k
grep -q 'Device/hinlink_h68k' target/linux/rockchip/image/armv8.mk || {
	echo "ERROR: armv8.mk 里没有 hinlink_h68k 设备定义" >&2; exit 1; }

echo "==> 应用 RK3568 PCIe3 PHY SRAM 固件补丁"
cp -f "$PHYFW" "target/linux/rockchip/patches-${KPVER}/" || {
	echo "ERROR: 无法写入 target/linux/rockchip/patches-${KPVER}/" >&2; exit 1; }

# 确认 DTS 补丁确实落在当前内核的补丁目录（而不是被打进了一个新建的旧版本目录）
ls "target/linux/rockchip/patches-${KPVER}/"073-1-*H68K*.patch >/dev/null 2>&1 || {
	echo "ERROR: DTS 补丁没有落到 patches-${KPVER}" >&2; exit 1; }

echo "==> H68K 补丁应用完成（U-Boot + DTS + 设备定义 + 网口映射 + PCIe3 PHY 固件）"
