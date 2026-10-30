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

# ---------- sbwml openwrt_helloworld（科学插件防炸上游备份，整仓引入，README 要求）----------
# 含 passwall/passwall2/ssr-plus/openclash/nikki/mihomo/dae/sing-box/xray/v2ray/trojan/
# hysteria/shadowsocks 系列/lua-neturl/vmlinux-btf/homeproxy 等 44 个顶层包。
# 未被 Config 选中的包不会编译，只参与包索引（无副作用）。
clone_pkg helloworld          sbwml/openwrt_helloworld            v5

# README 配套操作①：删除 feeds 自带的同名核心包（否则 buildroot 收集阶段重复定义直接报错）。
# 做法：提取 helloworld 内所有 PKG_NAME，逐个在 feeds 源码树 + package/feeds 符号链接里删除同名副本。
hb_names=$(mktemp)
find package/custom/helloworld -mindepth 2 -maxdepth 3 -name Makefile 2>/dev/null | while read -r mk; do
  grep -oE "^PKG_NAME[[:space:]]*:=[[:space:]]*[A-Za-z0-9._+-]+" "$mk" 2>/dev/null | head -1 | sed -E 's/^PKG_NAME[[:space:]]*:=//'
done | sed '/^$/d' | sort -u > "$hb_names"
rm -rf feeds/packages/net/{xray-core,v2ray-core,v2ray-geodata,sing-box}  # README 明确点名的 4 个
removed=0
while read -r n; do
  [ -n "$n" ] || continue
  # feeds 真实源码目录（net/utils/lang 等任意子层）
  for d in $(find feeds -maxdepth 3 -mindepth 2 -type d -name "$n" 2>/dev/null); do
    rm -rf "$d"; removed=$((removed+1))
  done
  # scripts/feeds install 建的符号链接
  for l in $(find package/feeds -maxdepth 2 -name "$n" 2>/dev/null); do
    rm -rf "$l"; removed=$((removed+1))
  done
done < "$hb_names"
rm -f "$hb_names"
echo "   README 去重：移除 feeds 中与 helloworld 同名的副本 ${removed} 处"

# README 配套操作②：golang 换成 sbwml 23.x（helloworld 的 Go 核心按该版本构建，官方版本可能编不过）
if [ -d feeds/packages/lang/golang ]; then
  rm -rf feeds/packages/lang/golang
  git clone -q --depth 1 -b 23.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang ||
    echo "::warning::golang 23.x 换源失败，沿用官方版本"
  echo "   golang 已切换为 sbwml 23.x"
fi

# node 换成 sbwml 预编译版（官方 node 从源码编译极慢；sbwml 用 release 预编译产物秒装；
# 注意：openwrt_helloworld 仓库内并没有 node，node 替换实际来自 sbwml/feeds_packages_lang_node，
# 路径原地替换，package/feeds/packages/node 符号链接仍指向同一路径无需重建）
if [ -d feeds/packages/lang/node ]; then
  rm -rf feeds/packages/lang/node
  git clone -q --depth 1 -b packages-25.12 https://github.com/sbwml/feeds_packages_lang_node feeds/packages/lang/node ||
    echo "::warning::sbwml node 换源失败，沿用官方版本"
  # 原 Makefile 的 PKG_VERSION 是动态拉 tags（CI 瞬断会变空导致构建失败），一次性解析后钉入
  NODE_VER="$(curl -fsSL --retry 3 --max-time 30 https://api.github.com/repos/sbwml/node_workflow/tags 2>/dev/null | grep '"name"' | head -n 1 | sed -E 's/.*"name": "v([^"]+)".*/\1/' || true)"
  [ -n "$NODE_VER" ] || NODE_VER="22.23.2"
  sed -i -E "s|^PKG_VERSION:=.*|PKG_VERSION:=${NODE_VER}|" feeds/packages/lang/node/Makefile
  echo "   node 已切换为 sbwml 预编译版，版本钉入 ${NODE_VER}"
fi

# ---------- vlmcsd（permails：根 Makefile 无 PKG_NAME，包名回退=目录名，故目录必须叫 luci-app-vlmcsd，
#            否则与其内嵌的 vlmcsd/ 子包同名 → buildroot 重复包错误）----------
clone_pkg luci-app-vlmcsd     permails/luci-app-vlmcsd          main

echo "==> 自定义包目录："
find package/custom -maxdepth 1 -mindepth 1 -type d | sort
echo "==> 识别到的 Makefile 数：$(find package/custom -name Makefile | wc -l)"
[ "$FAIL" = "0" ] || { echo "ERROR: 有包获取失败" >&2; exit 1; }
