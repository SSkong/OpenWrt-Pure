#!/bin/bash
# 纯净基底上的最小定制：仅设备默认 IP / 主机名 + LuCI 显示构建日期
# 不删官方组件、不换主题、不碰内核
set -u

cd "${1:-.}" || exit 1

DEVICE="${2:?用法: Settings.sh <openwrt目录> <x86|bpi-r4|h68k>}"
case "$DEVICE" in
	x86)     DEF_IP="192.168.1.1";  HOSTNAME_WRT="OpenWrt-X86" ;;
	bpi-r4)  DEF_IP="192.168.10.1"; HOSTNAME_WRT="OpenWrt-BPI-R4" ;;
	h68k)    DEF_IP="192.168.20.1"; HOSTNAME_WRT="OpenWrt-H68K" ;;
	*) echo "ERROR: 未知设备 $DEVICE" >&2; exit 1 ;;
esac

echo "==> 设备 ${DEVICE}：管理IP ${DEF_IP}，主机名 ${HOSTNAME_WRT}"

CFG=./package/base-files/files/bin/config_generate
[ -f "$CFG" ] && {
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/${DEF_IP}/g" "$CFG"
	sed -i "s/hostname='OpenWrt'/hostname='${HOSTNAME_WRT}'/g" "$CFG"
}

# LuCI 概览页追加构建标识（纯展示，便于区分固件版本）
STATUS_JS=./feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js
[ -f "$STATUS_JS" ] && sed -i "s/(luciversion || '')/(luciversion || '') + (' \/ ${DEVICE}-$(date -u +%y.%m.%d)')/g" "$STATUS_JS"

echo "==> Settings 完成"
