#!/bin/bash
# 自定义软件包引入 —— 仅用户指定的原始上游仓库（全部克隆到 package/custom/<名称>）
#
# 原理：OpenWrt 按 Makefile 所在目录递归识别包，整仓克隆即可；仓库根本身是包、
# 或内部含多个子包目录，都能被正确发现，无需手工拆分。分支均已核实为默认分支。
#
# 原则：基底保持纯净（官方 25.12 + LuCI），只在这里引入下面点名的包；不加其它自定义包。
set -u

cd "${1:-.}" || exit 1
mkdir -p package/custom
FAIL=0

# clone_pkg <目标名> <owner/repo> <分支>
clone_pkg() {
	local name="$1" repo="$2" branch="$3"
	echo "==> ${name}  <= ${repo}@${branch}"
	rm -rf "package/custom/${name}"
	if ! git clone -q --depth 1 --single-branch -b "$branch" "https://github.com/${repo}.git" "package/custom/${name}"; then
		echo "ERROR: 克隆 ${repo}@${branch} 失败" >&2
		FAIL=1
		return 1
	fi
	rm -rf "package/custom/${name}/.github" "package/custom/${name}/.git"
}

# ---------- natmapt（muink）：核心 + LuCI ----------
clone_pkg natmapt             muink/openwrt-natmapt              master  # PKG_NAME=natmapt
clone_pkg luci-app-natmapt    muink/luci-app-natmapt             master

# ---------- stuntman（muink，natmapt 依赖的 STUN 客户端/服务端）----------
clone_pkg stuntman            muink/openwrt-stuntman             master  # stuntman-client/-server/-testcode

# ---------- mosdns（sbwml：核心 + geo2txt + LuCI 同仓）----------
clone_pkg mosdns              sbwml/luci-app-mosdns              v5

# ---------- bandix（timsaya：核心 + LuCI 分仓）----------
clone_pkg bandix              timsaya/openwrt-bandix             main    # PKG_NAME=bandix
clone_pkg luci-app-bandix     timsaya/luci-app-bandix            main

# ---------- 网易云音乐解锁（UnblockNeteaseMusic 官方）----------
clone_pkg unblockneteasemusic UnblockNeteaseMusic/luci-app-unblockneteasemusic js

# ---------- 微信推送（tty228）----------
clone_pkg wechatpush          tty228/luci-app-wechatpush         master

# ---------- sirpdboy 系列（taskplan / timecontrol / netspeedtest / watchdog / partexp）----------
clone_pkg taskplan            sirpdboy/luci-app-taskplan         main
clone_pkg timecontrol         sirpdboy/luci-app-timecontrol      main    # luci-app-timecontrol（nft 定时控制）
clone_pkg netspeedtest        sirpdboy/netspeedtest              main    # luci-app-netspeedtest + ookla-speedtest + homebox
clone_pkg watchdog            sirpdboy/luci-app-watchdog         main    # luci-app-watchdog + watchdog
clone_pkg partexp             sirpdboy/luci-app-partexp          main    # luci-app-partexp（分区扩容）

# ---------- airconnect（sbwml：airconnect 核心 + LuCI 同仓）----------
clone_pkg airconnect          sbwml/luci-app-airconnect          main

# ---------- zerotier LuCI（rabbitrogi；核心 zerotier 用官方 feeds）----------
clone_pkg zerotier-luci       rabbitrogi/luci-app-zerotier       main

# ---------- homeproxy（immortalwrt；依赖 +sing-box）----------
clone_pkg homeproxy           immortalwrt/homeproxy              master

# ---------- vlmcsd（permails：根 Makefile 无 PKG_NAME，包名回退=目录名，故目录必须叫 luci-app-vlmcsd，
#            否则与其内嵌的 vlmcsd/ 子包同名 → buildroot 重复包错误）----------
clone_pkg luci-app-vlmcsd     permails/luci-app-vlmcsd          main

echo "==> 自定义包目录："
find package/custom -maxdepth 1 -mindepth 1 -type d | sort
echo "==> 识别到的 Makefile 数：$(find package/custom -name Makefile | wc -l)"
[ "$FAIL" = "0" ] || { echo "ERROR: 有包获取失败" >&2; exit 1; }
