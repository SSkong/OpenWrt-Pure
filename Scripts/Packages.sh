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

# ---------- NAT 维护 / P2P（muink）----------
clone_pkg natmapt             muink/openwrt-natmapt              master
clone_pkg luci-app-natmapt    muink/luci-app-natmapt             master
clone_pkg stuntman            muink/openwrt-stuntman             master   # stuntman-client/-server

# ---------- DNS / 分流核心 ----------
clone_pkg mosdns              sbwml/luci-app-mosdns              v5       # mosdns + geo2txt + luci-app-mosdns
# smartdns 用 pymumu 上游原版替换 feeds 自带版本（feeds/packages/net/smartdns 与本仓库同名，
# 由文件末尾的通用去重逻辑删除）。核心包无条件 include feeds 的 rust-package.mk，
# 依赖 feeds 里 rust 包存在；其 rust 子包 smartdns-ui 未设 DEFAULT，默认不选，不会拉 rust/host。
clone_pkg smartdns            pymumu/openwrt-smartdns            master   # 核心（含可选子包 smartdns-ui）
clone_pkg luci-app-smartdns   pymumu/luci-app-smartdns           master   # LuCI 前端

# ---------- 带宽 / 穿透 / 组网 ----------
clone_pkg bandix              timsaya/openwrt-bandix             main     # PKG_NAME=bandix
clone_pkg luci-app-bandix     timsaya/luci-app-bandix            main
clone_pkg easytier            EasyTier/luci-app-easytier         main     # easytier + easytier-noweb + luci-app-easytier
clone_pkg honk                189160/luci-app-honk               main     # honk + luci-app-honk
clone_pkg zerotier-luci       rabbitrogi/luci-app-zerotier       main     # 核心 zerotier 用官方 feeds

# ---------- 媒体 / 推送 / DNS 工具 ----------
clone_pkg unblockneteasemusic UnblockNeteaseMusic/luci-app-unblockneteasemusic js
clone_pkg wechatpush          tty228/luci-app-wechatpush         master
clone_pkg airconnect          sbwml/luci-app-airconnect          main     # luci-app-airconnect + airconnect
clone_pkg oxidns              hahaher123/luci-app-oxidns         main     # luci-app-oxidns
clone_pkg kixdns              JohnsonRan/luci-app-kixdns         main     # kixdns(Rust) + kixdns-stats + luci-app-kixdns

# ---------- 任务 / 定时 / 磁盘 / 看门狗 / 分区（sirpdboy & Arthur97172）----------
clone_pkg taskplan            sirpdboy/luci-app-taskplan         main     # luci-app-taskplan
clone_pkg timecontrol         sirpdboy/luci-app-timecontrol      main     # luci-app-timecontrol（nft 定时控制）
clone_pkg tasks               Arthur97172/luci-app-tasks         main     # luci-app-tasks（定时/开机/上网控制）
clone_pkg netspeedtest        sirpdboy/netspeedtest              main     # luci-app-netspeedtest + ookla-speedtest + homebox
clone_pkg watchdog            sirpdboy/luci-app-watchdog         main     # luci-app-watchdog + watchdog
clone_pkg partexp             sirpdboy/luci-app-partexp          main     # luci-app-partexp（分区扩容）
clone_pkg online-upgrade      Arthur97172/luci-app-online-upgrade main
clone_pkg substore            Arthur97172/luci-app-substore      main     # 依赖 luci-lua-runtime + luci-compat

# ---------- 容器 / 磁盘 / 端口转发 / KMS ----------
clone_pkg luci-app-dockox     permails/luci-app-dockox           main     # 根无PKG_NAME，回退=目录名，外层须叫 luci-app-dockox；拉 docker 全家
clone_pkg diskbox             permails/luci-app-diskbox          master   # luci-app-diskbox（磁盘/分区/RAID）
clone_pkg socat-reforged      busybin/luci-app-socat-reforged    main     # luci-app-socat-reforged（socat 端口转发）
clone_pkg luci-app-vlmcsd     permails/luci-app-vlmcsd           main     # 外层须叫 luci-app-vlmcsd，否则与内嵌 vlmcsd/ 子包同名

# ---------- 设备专属应用（只在对应设备的 config 里启用，其他设备克隆但不选）----------
# BPI-R4：风扇 PWM 调速。LUCI_DEPENDS 带 @TARGET_mediatek_filogic，
# 在其他 target 上会被 kconfig 自动隐藏，不会因"未生效"触发校验失败。
clone_pkg luci-app-fan-bpir4  ntbowen/luci-app-fan-bpir4        main
# BPI-R4：MediaTek PPE/WED 硬件卸载状态页。仓库根目录没有 Makefile，
# 包实体在子目录 luci-app-mtk-wed/ 里，buildroot 递归扫描可正常识别，
# 包名按子目录名推导。
clone_pkg mtk-wed             z21100644/luci-app-mtk-wed        main

# ---------- 应用管理 / DNS ----------
clone_pkg openlist2           sbwml/luci-app-openlist2           main     # openlist2 + luci-app-openlist2
clone_pkg luci-app-adguardhome-tk  w9315273/luci-app-adguardhome  main  # 目录名必须=PKG_NAME：该包声明 CONFLICTS:=luci-app-adguardhome，若克隆到名为 adguardhome 的目录会与官方核心包同名
clone_pkg wolmon              my1639963/luci-app-wolmon          main     # src/luci-app-wolmon，下方修相对 include
clone_pkg harbor-file-pro     whzhni1/luci-app-harbor-file-pro   main     # luci-app-harbor-file-pro
clone_pkg openappfilter       destan19/OpenAppFilter             master   # luci-app-oaf + oaf + open-app-filter

# ---------- 硬件信息（MinimaxFlora autocore 25.12 适配，补回官方源没有的 arm/x86）----------
clone_pkg autocore            MinimaxFlora/autocore              openwrt-25.12  # 变体 autocore-arm / autocore-x86，设备配置里分别选

# ---------- 主题（默认主题由 Settings.sh 指定）----------
clone_pkg theme-lumen         qidlek114/luci-theme-lumen         main     # luci-theme-lumen
clone_pkg theme-footstrap     VizzleTF/luci-theme-footstrap      main     # 子包 luci-theme-footstrap
clone_pkg luci-theme-aurora   eamonxg/luci-theme-aurora          master   # 根无PKG_NAME，回退=目录名，外层须叫 luci-theme-aurora
clone_pkg luci-app-aurora-config eamonxg/luci-app-aurora-config  master   # 外层须叫 luci-app-aurora-config

# ---------- wolmon 相对 include 修正（克隆布局下 ../../luci.mk 指向错误）----------
WOLMON_MK="package/custom/wolmon/src/luci-app-wolmon/Makefile"
[ -f "$WOLMON_MK" ] && sed -i 's|^include ../../luci.mk$|include $(TOPDIR)/feeds/luci/luci.mk|' "$WOLMON_MK"

# ---------- sbwml openwrt_helloworld（科学插件防炸上游备份，整仓引入，README 要求）----------
# 含 passwall/passwall2/ssr-plus/openclash/nikki/mihomo/dae/sing-box/xray/v2ray/trojan/
# hysteria/shadowsocks 系列/lua-neturl/vmlinux-btf/homeproxy 等 44 个顶层包。
# 未被 Config 选中的包不会编译，只参与包索引（无副作用）。
clone_pkg helloworld          sbwml/openwrt_helloworld            v5

# README 配套操作①：golang 换成 sbwml 27.x（helloworld 的 Go 核心按该版本构建，官方版本可能编不过）
if [ -d feeds/packages/lang/golang ]; then
  rm -rf feeds/packages/lang/golang
  git clone -q --depth 1 -b 27.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang ||
    echo "::warning::golang 27.x 换源失败，沿用官方版本"
  # lang/golang 目录重建后，此前 scripts/feeds install -a 建的符号链接全部悬空，需重建
  ./scripts/feeds install -a >/dev/null 2>&1 || true
  echo "   golang 已切换为 sbwml 27.x 并重建 feeds 链接"
fi

# README 配套操作②：node 换成 sbwml 预编译版 https://github.com/sbwml/feeds_packages_lang_node
# （官方 node 从源码编译极慢；sbwml 用 release 预编译产物秒装。原地替换路径，
#  package/feeds/packages/node 符号链接指向同一路径无需重建。
#  PKG_VERSION 保持 Makefile 原生动态解析，不做钉入。
#  注意：不要替换 $(ARCH_PACKAGES)！它在三目标上本就展开为正确资产名
#  （x86→x86_64、BPI-R4→aarch64_cortex-a53、H68K→aarch64_generic），硬编码会串架构）
if [ -d feeds/packages/lang/node ]; then
  rm -rf feeds/packages/lang/node
  git clone -q --depth 1 -b packages-25.12 https://github.com/sbwml/feeds_packages_lang_node feeds/packages/lang/node ||
    echo "::warning::sbwml node 换源失败，沿用官方版本"
  echo "   node 已切换为 sbwml 预编译版（版本由 Makefile 动态解析）"
fi

# README 配套操作③ + 通用去重（必须放在最后一步：上面的 feeds install -a 会重建链接）
# 删除 feeds 源码树与 package/feeds 符号链接中、与 package/custom 同名的副本，
# 否则 buildroot 收集阶段重复定义直接报错。
hb_names=$(mktemp)
# 取全部 custom 包的 PKG_NAME（根 Makefile 无 PKG_NAME 者按 luci.mk 目录名回退），
# 并追加 CONFLICTS 名单：官方 feeds 里与 custom 包互斥的旧副本必须一并删除。
# 例：luci-app-adguardhome-tk 声明 CONFLICTS:=luci-app-adguardhome，而官方 luci-app-adguardhome
# 属 luci 合集默认 =y，其 CONFLICTS 经 kconfig 变成 "depends on !PACKAGE_luci-app-adguardhome"，
# 若不删官方副本，tk 变体会被 defconfig 静默取消选中。
find package/custom -mindepth 2 -name Makefile 2>/dev/null | while read -r mk; do
  n=$(grep -oE "^PKG_NAME[[:space:]]*:=[[:space:]]*[A-Za-z0-9._+-]+" "$mk" 2>/dev/null | head -1 | sed -E 's/^PKG_NAME[[:space:]]*:=//')
  if [ -n "$n" ]; then echo "$n"; else echo "$mk" | sed -E 's#package/custom/([^/]+)/.*#\1#'; fi
done | sed '/^$/d' | sort -u > "$hb_names"
# README 明确点名的 4 个先行删除（保险）
rm -rf feeds/packages/net/{xray-core,v2ray-core,v2ray-geodata,sing-box}

# luci-app-adguardhome-tk 声明 CONFLICTS:=luci-app-adguardhome，而 feeds install -a 会把官方
# luci-app-adguardhome 装进 package/feeds/luci/，kconfig 里变成
# "depends on !PACKAGE_luci-app-adguardhome" → tk 变体被静默取消。
# 上游用 SDK 时只 install 指定包所以不会遇到，我们装全量 feeds 必须显式删掉官方副本。
for _p in luci-app-adguardhome luci-i18n-adguardhome-zh-cn; do
	find feeds -maxdepth 4 -mindepth 2 -type d -name "$_p" -exec rm -rf {} + 2>/dev/null || true
	find package/feeds -maxdepth 2 -name "$_p" -exec rm -rf {} + 2>/dev/null || true
done

removed=0
while read -r n; do
  [ -n "$n" ] || continue
  for d in $(find feeds -maxdepth 3 -mindepth 2 -type d -name "$n" 2>/dev/null); do
    rm -rf "$d"; removed=$((removed+1))
  done
  for l in $(find package/feeds -maxdepth 2 -name "$n" 2>/dev/null); do
    rm -rf "$l"; removed=$((removed+1))
  done
done < "$hb_names"
rm -f "$hb_names"
echo "   去重：移除 feeds 中与 custom 同名的副本 ${removed} 处"

echo "==> 自定义包目录："
find package/custom -maxdepth 1 -mindepth 1 -type d | sort
echo "==> 识别到的 Makefile 数：$(find package/custom -name Makefile | wc -l)"
[ "$FAIL" = "0" ] || { echo "ERROR: 有包获取失败" >&2; exit 1; }
