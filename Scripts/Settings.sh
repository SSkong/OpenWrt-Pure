#!/bin/bash
# 常规定制：默认主题 / 主机名 / 管理 IP / 少量包适配修补
# 这里只做"配置层"和"包 Makefile 适配"，不碰内核源码
set -u

cd "${1:-.}" || exit 1

DEVICE="${2:?用法: Settings.sh <openwrt目录> <x86|bpi-r4|h68k>}"
case "$DEVICE" in
	x86)     DEF_IP="192.168.1.1";  HOSTNAME_WRT="OpenWrt-X86" ;;
	bpi-r4)  DEF_IP="192.168.10.1"; HOSTNAME_WRT="OpenWrt-BPI-R4" ;;
	h68k)    DEF_IP="192.168.20.1"; HOSTNAME_WRT="OpenWrt-H68K" ;;
	*) echo "ERROR: 未知设备 $DEVICE" >&2; exit 1 ;;
esac
THEME="shadcn"

echo "==> 设备 ${DEVICE}  默认IP ${DEF_IP}  主机名 ${HOSTNAME_WRT}  主题 ${THEME}"

# ---------- LuCI：移除在线升级助手、指定默认主题 ----------
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} + 2>/dev/null || true
find ./feeds/luci/collections/ -type f -name "Makefile" \
	-exec sed -i "s/luci-theme-bootstrap/luci-theme-${THEME}/g" {} + 2>/dev/null || true

# ---------- 默认管理 IP / 主机名 ----------
[ -f ./package/base-files/files/bin/config_generate ] && {
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/${DEF_IP}/g" ./package/base-files/files/bin/config_generate
	sed -i "s/hostname='OpenWrt'/hostname='${HOSTNAME_WRT}'/g" ./package/base-files/files/bin/config_generate
}

# ---------- 编译标识（LuCI 概览页显示构建日期） ----------
STATUS_JS="./feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
[ -f "$STATUS_JS" ] && sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ ${DEVICE}-$(date -u +%y.%m.%d)')/g" "$STATUS_JS"

# ---------- 包适配修补 ----------
# smartdns：上游 PKG_MIRROR_HASH 来自其 CI 环境产物，与本 runner 的 git archive 结果不一致，
# 源码已固定 commit，改 skip 跳过镜像哈希校验
for f in package/custom/smartdns/Makefile; do
	[ -f "$f" ] || continue
	sed -i 's/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=skip/' "$f"
	sed -i '/^define Download\/smartdns-webui/,/^endef/ s/MIRROR_HASH:=.*/MIRROR_HASH:=skip/' "$f"
done

# wolmon：Makefile 用相对路径 include ../../luci.mk（feeds 内布局），改绝对路径
WOLMON_MK="$(find package/custom/luci-app-wolmon -name Makefile | head -1)"
[ -n "$WOLMON_MK" ] && sed -i 's|^include ../../luci.mk$|include $(TOPDIR)/feeds/luci/luci.mk|' "$WOLMON_MK"

# flowcone：Rust 包，需 rust/host；Makefile 里 MIRROR_HASH 用 wildcard 兜底，无需改
# openclash：纯 LuCI + 运行时下载核心，依赖 ruby/ruby-yaml（已在 Config 中）

echo "==> Settings 完成"
