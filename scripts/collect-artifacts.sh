#!/usr/bin/env bash
# ==============================================================================
# 从 openwrt/bin/targets/<target> 收集要发布的固件，并生成按设备区分的校验和
#
# 只拷三类文件：
#   - 镜像：*.img.gz / *.itb（排除 *-rootfs.img.gz —— 那是给容器/自定义布局用的
#     纯 rootfs，没有引导，PVE 导入也用不上，白占几百 MB 上传量）
#   - 引导件：*.bin（preloader）/ *.fip（BL31 + U-Boot）
#   - 已装包清单：*.manifest —— 排查「包到底进没进去」最直接
#
# 用法：scripts/collect-artifacts.sh <openwrt目录> <设备名> <target> <输出目录>
# ==============================================================================

set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WIN="${1:?用法: collect-artifacts.sh <openwrt目录> <设备名> <target> <输出目录>}"
DEV="${2:?缺设备名}"
TARGET="${3:?缺 target（如 x86/64）}"
OUT="${4:?缺输出目录}"

SRC="$WIN/bin/targets/$TARGET"
require_dir "$SRC" "找不到产物目录 $SRC（target 写错了？）"
ensure_dir "$OUT"

# 主镜像
find "$SRC" -maxdepth 1 -type f \( -name '*.img.gz' -o -name '*.itb' \) \
	! -name '*-rootfs.img.gz' -exec cp -f {} "$OUT/" \;
# 引导件：preloader 是 .bin，BL31/U-Boot 是 .fip（不是 .bin，写成 *fip*.bin 会全漏掉）
find "$SRC" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.fip' \) \
	-exec cp -f {} "$OUT/" \;
# 已装包清单
find "$SRC" -maxdepth 1 -type f -name '*.manifest' -exec cp -f {} "$OUT/" \;

cd "$OUT" || die "进不去 $OUT"
[ -n "$(ls -A)" ] || die "未找到任何固件产物（$SRC）"
ls -lh

# 校验和必须和设备产物同目录，才能被 upload-artifact 一起带走。
# 文件名带设备名：publish job 会把三个 artifact 合并到同一目录，都叫
# sha256sums.txt 会互相覆盖。
sum="sha256sums-${DEV}.txt"
sha256sum $(ls -1 | grep -v '^sha256sums-') > "$sum" || die "生成 $sum 失败"
sub "校验和 → $sum"
