#!/usr/bin/env bash
# 纯净基底上的最小定制：仅设备默认 IP / 主机名 + LuCI 显示构建日期
# 不删官方组件、不换主题、不碰内核
#
# 这里的每一处修改都加了断言。原因：sed 匹配不到时退出码仍然是 0，脚本会假装成功，
# 产出的固件"看起来正常但没定制"——管理 IP 悄悄变成 192.168.1.1 这种问题，
# 刷进去才发现，排查成本极高。宁可在构建前失败。
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ $# -ge 1 ] || usage_die "setup-device.sh <openwrt目录> <x86|bpi-r4|h68k>"
enter "${1:-.}"
DEVICE="${2:?用法: setup-device.sh <openwrt目录> <x86|bpi-r4|h68k>}"

case "$DEVICE" in
	x86)     DEF_IP="10.0.0.1";     HOSTNAME_WRT="OpenWrt-X86" ;;
	bpi-r4)  DEF_IP="192.168.10.1"; HOSTNAME_WRT="OpenWrt-BPI-R4" ;;
	h68k)    DEF_IP="192.168.20.1"; HOSTNAME_WRT="OpenWrt-H68K" ;;
	*) die "未知设备 $DEVICE（可选：x86 / bpi-r4 / h68k）" ;;
esac

step "设备 ${DEVICE}：管理IP ${DEF_IP}，主机名 ${HOSTNAME_WRT}"

# ---------- 默认 IP 与主机名 ----------
# 这是管理 IP 的唯一载体，文件不存在说明构建树不对 —— 直接失败，不要静默跳过
CFG=./package/base-files/files/bin/config_generate
require_file "$CFG"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/${DEF_IP}/g" "$CFG" ||
	die "改写默认 IP 失败: $CFG"
sed -i "s/hostname='OpenWrt'/hostname='${HOSTNAME_WRT}'/g" "$CFG" ||
	die "改写默认主机名失败: $CFG"

has_text "$DEF_IP" "$CFG" ||
	die "默认 IP 未生效：$CFG 里看不到 ${DEF_IP}（上游文本可能已变，需更新这里的 sed 锚点）"
has_text "hostname='${HOSTNAME_WRT}'" "$CFG" ||
	die "默认主机名未生效：$CFG 里看不到 hostname='${HOSTNAME_WRT}'（上游文本可能已变）"
sub "默认 IP / 主机名已写入 $CFG"

# ---------- LuCI 概览页追加构建标识 ----------
# 纯展示，失败不影响功能，所以只 warning 不 die
STATUS_JS=./feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js
STAMP="${DEVICE}-$(date -u +%y.%m.%d)"
if [ -f "$STATUS_JS" ]; then
	sed -i "s/(luciversion || '')/(luciversion || '') + (' \/ ${STAMP}')/g" "$STATUS_JS" ||
		die "改写 LuCI 版本号失败: $STATUS_JS"
	if has_text "${STAMP}" "$STATUS_JS"; then
		sub "LuCI 概览页已追加构建标识 ${STAMP}"
	else
		warn "LuCI 版本号未生效：$STATUS_JS 里找不到锚点 \"(luciversion || '')\"，feeds 路径或上游文本可能已变（不影响功能）"
	fi
else
	warn "找不到 $STATUS_JS，跳过 LuCI 构建标识（不影响功能）"
fi

step "Settings 完成"
