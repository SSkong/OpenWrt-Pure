#!/bin/bash
# SONiC 全锥形 NAT（fullcone）— 内核 + 用户态 + 防火墙 + LuCI 四层一起打
#
# 需求背景：官方 25.12 已移除 kmod-nft-fullcone（Fullcone-NAT 被上游改成
# FlowCone 方案），所以 base.config 里那行只能注释掉。本项目是另一条路：
# 把 SONiC（Broadcom 出品）的 fullcone 补丁移植进 nf_nat，再打通 nftables
# 与 fw4，实现 per-zone / per-protocol 粒度。
#
# 与旧 nft-fullcone 的本质区别：
#   - 映射存在 conntrack 自身（第二张 3-tuple 哈希表），不是平行哈希表，
#     读路径走 RCU 而不是全局自旋锁；生命周期由 conntrack 自动回收
#   - 支持全部 L4 协议（TCP/UDP/ICMP/GRE/SCTP/DCCP/UDPLite），旧实现只有 UDP
#   - fullcone 是 per-rule 标志位，走普通 masquerade 的流量零额外开销
#   - 不新增内核模块、不新增 Kconfig，直接编进 nf_nat / xt_MASQUERADE / nft_masq
#     .ko，所以固件里不需要额外装任何 kmod 包
#
# 本脚本只做两件事：把 9 个补丁放到构建系统会读取的位置，给 libnftnl 打开
# PKG_FIXUP:=autoreconf。补丁的真正应用由 OpenWrt 在编译期完成（失败会硬报错，
# 不会静默跳过）。
#
# 顺序要求：必须在 `./scripts/feeds install -a` 之后调用（LuCI 补丁要落到
# feeds/luci/applications/luci-app-firewall/ 下），且必须在 `make download`
# 之前（libnftnl 补丁改变了下载后要重新生成构建系统的行为）。
set -u

cd "${1:?用法: Fullcone.sh <openwrt目录>}" || exit 1
PATCH_DIR="${2:?用法: Fullcone.sh <openwrt目录> <补丁目录>}"

# 补丁按 6.12 编写并用 v6.12 源码 + v25.12.6 的包版本逐个验证过 fuzz=0。
# 内核大版本一变，hack 目录名和 nf_nat_core.c 的结构都可能变，直接拦住。
HACK="target/linux/generic/hack-6.12"
[ -d "$HACK" ] || {
	echo "ERROR: 找不到 $HACK" >&2
	echo "       本套补丁只针对内核 6.12 验证（25.12 分支）。升级内核需重新 rebase 后改这里。" >&2
	exit 1; }

need() { [ -f "${PATCH_DIR}/$1" ] || { echo "ERROR: 缺少补丁 ${PATCH_DIR}/$1" >&2; exit 1; }; }
for p in 984-add-sonic-fullcone-support.patch 985-add-sonic-fullcone-to-ipt.patch \
         986-add-sonic-fullcone-to-nft.patch 901-iptables-sonic-fullcone.patch \
         001-libnftnl-fullcone-expression.patch 002-nftables-fullcone-expression.patch \
         001-firewall4-sonic-fullcone.patch 001-firewall3-sonic-fullcone.patch \
         001-luci-app-firewall-fullcone-options.patch zh_Hans.po; do
	need "$p"
done

# 补丁必须是 LF。Windows 下 checkout 会把 .patch 转成 CRLF，打不进 LF 的内核源码，
# 现象是 "context does not match" 且很难看出是行尾问题。
# 注意用 tr 逐字节数 CR：grep/awk 在部分环境（MSYS 文本模式）会把 CR 吃掉，查不出来。
crlf=""
for f in "$PATCH_DIR"/*; do
	[ -f "$f" ] || continue
	n="$(LC_ALL=C tr -cd '\r' < "$f" | wc -c)"
	[ "${n:-0}" -gt 0 ] && crlf="$crlf $f"
done
[ -z "$crlf" ] || { echo "ERROR: 补丁含 CRLF 行尾，需转成 LF:$crlf" >&2; exit 1; }

# put <源补丁> <目标目录> <目标文件名>
put() {
	mkdir -p "$2" || { echo "ERROR: 无法创建 $2" >&2; exit 1; }
	cp -f "${PATCH_DIR}/$1" "$2/$3" || { echo "ERROR: 无法写入 $2/$3" >&2; exit 1; }
}

echo "==> 内核层：nf_nat 3-tuple 哈希表 + xt_MASQUERADE/nft_masq 的 fullcone 表达式"
put 984-add-sonic-fullcone-support.patch "$HACK" 984-add-sonic-fullcone-support.patch
put 985-add-sonic-fullcone-to-ipt.patch  "$HACK" 985-add-sonic-fullcone-to-ipt.patch
put 986-add-sonic-fullcone-to-nft.patch  "$HACK" 986-add-sonic-fullcone-to-nft.patch

echo "==> 用户态：iptables FULLCONE target / libnftnl 与 nftables 的 fullcone 表达式"
# iptables 1.8.9 起才有 extensions/libxt_NAT.c，25.12 是 1.8.10，符合。
put 901-iptables-sonic-fullcone.patch package/network/utils/iptables/patches 901-sonic-fullcone.patch
put 001-libnftnl-fullcone-expression.patch package/libs/libnftnl/patches 001-fullcone-expression.patch
put 002-nftables-fullcone-expression.patch package/network/utils/nftables/patches 002-fullcone-expression.patch

# libnftnl 补丁往 src/Makefile.am 里加了 src/expr/fullcone.c，使 .am 比 tar 包自带的
# .in 更新，make 会用打包时的 automake 版本（1.3.1 是 automake-1.17）重新生成
# Makefile.in，而构建环境里只有 OpenWrt 自己的 1.18.x，直接 "automake-1.17: not found"。
# PKG_FIXUP:=autoreconf 让 autotools 用随源码树的版本重跑一遍。
# nftables 包本身已经带 PKG_FIXUP:=autoreconf，只有 libnftnl 需要补。
NFTNL_MK="package/libs/libnftnl/Makefile"
[ -f "$NFTNL_MK" ] || { echo "ERROR: 找不到 $NFTNL_MK" >&2; exit 1; }
if grep -q '^PKG_FIXUP:=.*autoreconf' "$NFTNL_MK"; then
	echo "    libnftnl 已带 PKG_FIXUP:=autoreconf"
else
	awk '!ins && /^include \$\(INCLUDE_DIR\)\/package\.mk/ { print "PKG_FIXUP:=autoreconf"; print ""; ins=1 } { print }' \
		"$NFTNL_MK" > "$NFTNL_MK.tmp" && mv "$NFTNL_MK.tmp" "$NFTNL_MK" || {
		echo "ERROR: 无法给 $NFTNL_MK 注入 PKG_FIXUP" >&2; rm -f "$NFTNL_MK.tmp"; exit 1; }
	echo "    libnftnl 已注入 PKG_FIXUP:=autoreconf"
fi

echo "==> 防火墙层：fw4（nftables，per-zone/per-proto）/ fw3（iptables）"
put 001-firewall4-sonic-fullcone.patch package/network/config/firewall4/patches 001-sonic-fullcone.patch
# 25.12 仍保留 firewall3 包，但默认用 fw4；fw3 补丁只在该包被选中编译时才生效
if [ -d package/network/config/firewall ]; then
	put 001-firewall3-sonic-fullcone.patch package/network/config/firewall/patches 001-sonic-fullcone.patch
else
	echo "    firewall3 包不存在，跳过（正常，25.12 默认 fw4）"
fi

echo "==> LuCI：把 fullcone 选项并进原生防火墙页面（不额外装 LuCI 应用）"
LUCI_FW="feeds/luci/applications/luci-app-firewall"
[ -d "$LUCI_FW" ] || {
	echo "ERROR: 找不到 $LUCI_FW" >&2
	echo "       请先执行 ./scripts/feeds update -a && ./scripts/feeds install -a" >&2
	exit 1; }
put 001-luci-app-firewall-fullcone-options.patch "$LUCI_FW/patches" 001-add-fullcone-options.patch

# po/ 不进 build_dir，用 patches/ 打不到翻译文件，只能直接追加。
ZH_PO="$LUCI_FW/po/zh_Hans/firewall.po"
if [ -f "$ZH_PO" ]; then
	if grep -q 'Fullcone NAT' "$ZH_PO"; then
		echo "    zh_Hans 翻译已存在"
	else
		cat "${PATCH_DIR}/zh_Hans.po" >> "$ZH_PO" && echo "    zh_Hans 翻译已追加"
	fi
else
	echo "    WARNING: $ZH_PO 不存在，跳过中文翻译（不影响功能）" >&2
fi

echo "==> 落地校验"
fail=0
for f in "$HACK/984-add-sonic-fullcone-support.patch" \
         "$HACK/985-add-sonic-fullcone-to-ipt.patch" \
         "$HACK/986-add-sonic-fullcone-to-nft.patch" \
         package/network/utils/iptables/patches/901-sonic-fullcone.patch \
         package/libs/libnftnl/patches/001-fullcone-expression.patch \
         package/network/utils/nftables/patches/002-fullcone-expression.patch \
         package/network/config/firewall4/patches/001-sonic-fullcone.patch \
         "$LUCI_FW/patches/001-add-fullcone-options.patch"; do
	[ -s "$f" ] || { echo "  ✗ 缺失或为空: $f" >&2; fail=1; }
done
grep -q '^PKG_FIXUP:=.*autoreconf' "$NFTNL_MK" || { echo "  ✗ libnftnl 缺 PKG_FIXUP" >&2; fail=1; }
[ "$fail" -eq 0 ] || { echo "ERROR: 有补丁未落到预期位置" >&2; exit 1; }

echo "==> fullcone 补丁就位（9 个补丁 + libnftnl PKG_FIXUP + zh_Hans 翻译）"
echo "    编译期由 OpenWrt 应用；补丁打不上会直接报错，不会静默跳过。"
echo "    刷机后启用（defaults.fullcone 是总开关，关着时 zone 里的设置无效）："
echo "      uci set firewall.@defaults[0].fullcone='1'"
echo "      uci set firewall.@zone[1].fullcone='1'"
echo "      uci add_list firewall.@zone[1].fullcone_proto='udp'   # 可选，仅 UDP"
echo "      uci commit firewall && /etc/init.d/firewall restart"
echo "    验证：nft list ruleset | grep fullcone"
echo "    测 NAT 类型：内网机器跑 pystun3，结果应为 Full Cone"
