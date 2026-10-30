#!/bin/bash
# 自定义软件包引入：全部从上游源码仓库克隆，编译进固件
# 原则：只加包，不改内核；官方 feeds 已有的包不在此重复（直接在 Config 里选中即可）
set -u

cd "${1:-.}" || exit 1
mkdir -p package/custom
FAIL=0

# clone_pkg <仓库> <分支> <目标名> [子目录[,子目录2...]]
#   无子目录：整个仓库直接落到 package/custom/<目标名>
#   有子目录：只取这些子目录，落到 package/custom/<目标名>/（可多个）
clone_pkg() {
	local repo="$1" branch="$2" name="$3" subs="${4:-}"
	echo "==> ${name}  (${repo}@${branch}${subs:+ : $subs})"
	rm -rf "/tmp/pkg-${name}"
	if ! git clone -q --depth 1 ${branch:+-b "$branch"} "https://github.com/${repo}.git" "/tmp/pkg-${name}"; then
		echo "ERROR: clone ${repo} 失败" >&2
		FAIL=1
		return 1
	fi
	if [ -z "$subs" ]; then
		mv "/tmp/pkg-${name}" "./package/custom/${name}"
	else
		mkdir -p "./package/custom/${name}"
		local IFS=','
		for s in $subs; do
			if [ -d "/tmp/pkg-${name}/${s}" ]; then
				cp -rf "/tmp/pkg-${name}/${s}/." "./package/custom/${name}/"
			else
				echo "ERROR: ${repo} 中不存在子目录 ${s}" >&2
				FAIL=1
			fi
		done
		unset IFS
		rm -rf "/tmp/pkg-${name}"
	fi
}

# ---------- 代理 / 分流 ----------
clone_pkg vernesong/OpenClash master openclash luci-app-openclash
clone_pkg sbwml/luci-app-dae master dae "dae,luci-app-dae"
clone_pkg 189160/luci-app-honk master honk "honk,luci-app-honk"
clone_pkg fcshark-org/openwrt-fchomo main fchomo "mihomo,luci-app-fchomo"
clone_pkg nikkinikki-org/OpenWrt-nikki main nikki "nikki,luci-app-nikki"
clone_pkg QiuSimons/FlowCone main flowcone openwrt
clone_pkg QiuSimons/vmlinux-btf master vmlinux-btf

# ---------- DNS / 广告过滤 ----------
# 官方 feeds 自带同名包（版本较旧），先用自定义版 → 删除 feeds 里的同名包避免 duplicate package
rm -rf feeds/luci/applications/luci-app-smartdns package/feeds/luci/luci-app-smartdns 2>/dev/null || true
rm -rf feeds/luci/applications/luci-app-adguardhome package/feeds/luci/luci-app-adguardhome 2>/dev/null || true
clone_pkg pymumu/openwrt-smartdns master smartdns
clone_pkg pymumu/luci-app-smartdns master luci-app-smartdns
clone_pkg w9315273/luci-app-adguardhome main luci-app-adguardhome

# ---------- 组网 / 网络工具 ----------
clone_pkg EasyTier/luci-app-easytier main easytier "easytier,luci-app-easytier"
clone_pkg QiuSimons/OpenWrt-Add master oa-common \
	"apps/luci-app-airconnect,apps/luci-app-bandix,apps/openwrt-bandix,apps/luci-app-natmapt,apps/openwrt-natmapt,apps/luci-app-arpbind,apps/luci-app-ap-modem,apps/luci-app-3cat,apps/luci-app-partexp,apps/luci-app-taskplan,apps/luci-app-unblockneteasemusic,apps/luci-app-wechatpush,apps/luci-app-ramfree,apps/luci-app-mosdns,apps/luci-app-zerotier,apps/homeproxy"
clone_pkg QiuSimons/OpenWrt-Add master oa-legacy \
	"legacy/openwrt_pkgs/luci-app-vlmcsd,legacy/openwrt_pkgs/luci-app-usb-printer,legacy/openwrt_pkgs/luci-app-cpufreq,legacy/luci-app-xlnetacc"
clone_pkg QiuSimons/OpenWrt-Add master addition-trans-zh "apps/addition-trans-zh"

# ---------- 应用过滤 ----------
clone_pkg destan19/OpenAppFilter master OpenAppFilter

# ---------- 存储 / 文件 / 系统 ----------
clone_pkg whzhni1/luci-app-harbor-file-pro main harbor-file-pro luci-app-harbor-file-pro
clone_pkg sbwml/luci-app-openlist2 main openlist2 "openlist2,luci-app-openlist2"
clone_pkg lisaac/luci-app-diskman master luci-app-diskman applications/luci-app-diskman
clone_pkg sirpdboy/luci-app-watchdog main luci-app-watchdog
clone_pkg my1639963/luci-app-wolmon main luci-app-wolmon src/luci-app-wolmon

# ---------- 监控 / 运维 ----------
clone_pkg cndoin/luci-app-fluxora main luci-app-fluxora
clone_pkg Arthur97172/luci-app-online-upgrade main luci-app-online-upgrade
clone_pkg Arthur97172/luci-app-substore main luci-app-substore
clone_pkg sqchr888/luci-app-ghacc main luci-app-ghacc
clone_pkg svenshi/luci-app-oxidns main luci-app-oxidns

# ---------- 主题 ----------
clone_pkg eamonxg/luci-theme-shadcn main luci-theme-shadcn

echo "==> 自定义包："
find package/custom -maxdepth 1 -mindepth 1 -type d | sort
[ "$FAIL" = "0" ] || { echo "ERROR: 有包克隆失败" >&2; exit 1; }
