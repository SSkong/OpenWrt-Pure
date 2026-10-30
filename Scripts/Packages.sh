#!/bin/bash
# 自定义软件包引入：整仓克隆到 package/custom/<名称>
#
# 原理：OpenWrt 构建系统递归扫描 package/ 下的 Makefile，按 Makefile 所在目录识别包，
# 所以"仓库根本身是包"和"仓库内含多个子包目录"都能被正确发现，无需手工拆分。
# 分支均已核实为对应仓库的默认分支。
#
# 原则：只加包，不改内核。官方 feeds 已有的包不在此重复（在 Config 里直接选中即可）。
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

# sparse_add <目标名> <路径列表...>   —— 从 QiuSimons/OpenWrt-Add 只取需要的目录
sparse_add() {
	local target="$1"; shift
	local paths="$*"
	echo "==> ${target}  <= QiuSimons/OpenWrt-Add (sparse)"
	rm -rf "package/custom/${target}" /tmp/oa-sparse
	mkdir -p "package/custom/${target}"
	if ! git clone -q --depth 1 --filter=blob:none --no-checkout \
		https://github.com/QiuSimons/OpenWrt-Add /tmp/oa-sparse 2>/dev/null; then
		echo "ERROR: OpenWrt-Add 克隆失败" >&2; FAIL=1; return 1
	fi
	(
		cd /tmp/oa-sparse
		git sparse-checkout set ${paths} >/dev/null 2>&1 && git checkout -q master >/dev/null 2>&1
	) || { echo "ERROR: OpenWrt-Add 稀疏检出失败" >&2; FAIL=1; rm -rf /tmp/oa-sparse; return 1; }
	cp -rf /tmp/oa-sparse/. "package/custom/${target}/"
	rm -rf /tmp/oa-sparse
}

# ---------- 代理 / 分流 ----------
clone_pkg openclash         vernesong/OpenClash              master
clone_pkg dae               sbwml/luci-app-dae               main   # 含 dae + luci-app-dae
clone_pkg honk              189160/luci-app-honk             main   # 含 honk + luci-app-honk
clone_pkg fchomo            fcshark-org/openwrt-fchomo       master # 含 mihomo + luci-app-fchomo
clone_pkg nikki             nikkinikki-org/OpenWrt-nikki     main   # 含 nikki/mihomo-* + luci-app-nikki
clone_pkg flowcone          QiuSimons/FlowCone               master # openwrt/{flowcone,luci-app-flowcone}
clone_pkg vmlinux-btf       QiuSimons/vmlinux-btf            master # dae / flowcone 的 BTF 元数据

# ---------- DNS / 广告过滤 / 应用管理 ----------
clone_pkg smartdns          pymumu/openwrt-smartdns          master
clone_pkg luci-app-smartdns pymumu/luci-app-smartdns         master
clone_pkg adguardhome       w9315273/luci-app-adguardhome    main
clone_pkg openappfilter     destan19/OpenAppFilter           master

# ---------- 组网 / 网络工具 ----------
clone_pkg easytier          EasyTier/luci-app-easytier       main

# ---------- OpenWrt-Add 精选（稀疏检出）----------
sparse_add oa-apps \
	apps/luci-app-airconnect apps/airconnect-openwrt \
	apps/luci-app-bandix apps/openwrt-bandix \
	apps/luci-app-natmapt apps/openwrt-natmapt \
	apps/luci-app-arpbind apps/luci-app-ap-modem apps/luci-app-3cat \
	apps/luci-app-partexp apps/luci-app-taskplan \
	apps/luci-app-unblockneteasemusic apps/luci-app-wechatpush apps/luci-app-ramfree \
	apps/luci-app-mosdns apps/luci-app-zerotier apps/homeproxy apps/addition-trans-zh

sparse_add oa-legacy \
	legacy/openwrt_pkgs/luci-app-vlmcsd legacy/openwrt_pkgs/vlmcsd \
	legacy/openwrt_pkgs/luci-app-usb-printer legacy/openwrt_pkgs/luci-app-cpufreq \
	legacy/openwrt_pkgs/luci-app-autoreboot legacy/openwrt_pkgs/luci-app-eqos \
	legacy/openwrt_pkgs/luci-app-socat legacy/openwrt_pkgs/luci-app-vsftpd \
	legacy/openwrt_pkgs/coremark legacy/openwrt_pkgs/lshw \
	legacy/luci-app-xlnetacc legacy/luci-app-cpulimit legacy/luci-app-frpc_frps \
	legacy/openwrt_pkgs/filebrowser legacy/openwrt_pkgs/gowebdav legacy/openwrt_pkgs/luci-app-gowebdav

# ---------- 存储 / 文件 / 系统 ----------
clone_pkg harbor-file-pro   whzhni1/luci-app-harbor-file-pro main
clone_pkg openlist2         sbwml/luci-app-openlist2         main
clone_pkg diskman           lisaac/luci-app-diskman          master
clone_pkg watchdog          sirpdboy/luci-app-watchdog       main
clone_pkg wolmon            my1639963/luci-app-wolmon        main

# ---------- 监控 / 运维 ----------
clone_pkg fluxora           cndoin/luci-app-fluxora          main   # PKG_NAME=luci-app-wan-traffic
clone_pkg online-upgrade    Arthur97172/luci-app-online-upgrade main
clone_pkg substore          Arthur97172/luci-app-substore    main
clone_pkg ghacc             sqchr888/luci-app-ghacc          main
clone_pkg oxidns            svenshi/luci-app-oxidns          main

# ---------- 主题 ----------
clone_pkg theme-shadcn      eamonxg/luci-theme-shadcn        main

echo "==> 自定义包目录："
find package/custom -maxdepth 1 -mindepth 1 -type d | sort
echo "==> 识别到的 Makefile 数：$(find package/custom -name Makefile | wc -l)"
[ "$FAIL" = "0" ] || { echo "ERROR: 有包获取失败" >&2; exit 1; }
