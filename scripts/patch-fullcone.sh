#!/usr/bin/env bash
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
# 补丁集来自 mufeng05/openwrt-sonic-fullcone（kernel/ + firewall/ + patches/
# + translations/），本脚本把它映射到 OpenWrt 构建系统会读取的位置，并给
# libnftnl 打开 PKG_FIXUP:=autoreconf。真正打补丁由 OpenWrt 在编译期完成
# （失败会硬报错，不会静默跳过）。上游更新时按同样的目录对应关系同步即可。
#
# 顺序要求：必须在 `./scripts/feeds install -a` 之后调用（LuCI 补丁要落到
# feeds/luci/applications/luci-app-firewall/ 下），且必须在 `make download`
# 之前（libnftnl 补丁改变了下载后要重新生成构建系统的行为）。
#
# 通用守卫（存在性 / CRLF / put）统一在 lib.sh，与 patch-h68k.sh 共用同一套。
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ $# -ge 2 ] || usage_die "patch-fullcone.sh <openwrt目录> <补丁目录>"
enter "$1"
PATCH_DIR="$2"
[ -d "$PATCH_DIR" ] || die "补丁目录不存在: $PATCH_DIR"

# 补丁按 6.12 编写并用 v6.12 源码 + v25.12.6 的包版本逐个验证过 fuzz=0。
# 内核大版本一变，hack 目录名和 nf_nat_core.c 的结构都可能变，直接拦住。
HACK="target/linux/generic/hack-6.12"
[ -d "$HACK" ] || die "找不到 $HACK；本套补丁只针对内核 6.12 验证（25.12 分支），升级内核需重新 rebase 后改这里"

for p in 984-add-sonic-fullcone-support.patch 985-add-sonic-fullcone-to-ipt.patch \
         986-add-sonic-fullcone-to-nft.patch 987-sonic-fullcone-fix-races-and-drops.patch \
         901-iptables-sonic-fullcone.patch \
         001-libnftnl-fullcone-expression.patch 002-nftables-fullcone-expression.patch \
         003-nftables-fullcone-json-parser.patch \
         001-firewall4-sonic-fullcone.patch 001-firewall3-sonic-fullcone.patch \
         001-luci-app-firewall-fullcone-options.patch zh_Hans.po; do
	require_file "${PATCH_DIR}/$p" "缺少补丁 ${PATCH_DIR}/$p"
done
check_no_crlf "$PATCH_DIR"

step "内核层：nf_nat 3-tuple 哈希表 + xt_MASQUERADE/nft_masq 的 fullcone 表达式"
put "${PATCH_DIR}/984-add-sonic-fullcone-support.patch" "$HACK" 984-add-sonic-fullcone-support.patch
put "${PATCH_DIR}/985-add-sonic-fullcone-to-ipt.patch"  "$HACK" 985-add-sonic-fullcone-to-ipt.patch
put "${PATCH_DIR}/986-add-sonic-fullcone-to-nft.patch"  "$HACK" 986-add-sonic-fullcone-to-nft.patch
# 987 是在 984 之上的修正，不属于 SONiC 原补丁：并发竞争（manip_src 哈希桶的锁）
# 与外部主动连入时被误丢的包。编号排最后，保证 apply 顺序在 984 之后。
put "${PATCH_DIR}/987-sonic-fullcone-fix-races-and-drops.patch" "$HACK" 987-sonic-fullcone-fix-races-and-drops.patch

step "用户态：iptables FULLCONE target / libnftnl 与 nftables 的 fullcone 表达式"
# iptables 1.8.9 起才有 extensions/libxt_NAT.c，25.12 是 1.8.10，符合。
put "${PATCH_DIR}/901-iptables-sonic-fullcone.patch"      package/network/utils/iptables/patches 901-sonic-fullcone.patch
put "${PATCH_DIR}/001-libnftnl-fullcone-expression.patch" package/libs/libnftnl/patches          001-fullcone-expression.patch
put "${PATCH_DIR}/002-nftables-fullcone-expression.patch" package/network/utils/nftables/patches 002-fullcone-expression.patch
# 003 修的是 002 引入的两个崩溃面：nft -j（JSON 输入）走不到 fullcone 表达式，
# 以及 nft -o 优化器在 fullcone 规则上解引用空指针。编号必须排在 002 之后。
put "${PATCH_DIR}/003-nftables-fullcone-json-parser.patch" package/network/utils/nftables/patches 003-fullcone-json-parser.patch

# libnftnl 补丁往 src/Makefile.am 里加了 src/expr/fullcone.c，使 .am 比 tar 包自带的
# .in 更新，make 会用打包时的 automake 版本（1.3.1 是 automake-1.17）重新生成
# Makefile.in，而构建环境里只有 OpenWrt 自己的 1.18.x，直接 "automake-1.17: not found"。
# PKG_FIXUP:=autoreconf 让 autotools 用随源码树的版本重跑一遍。
# nftables 包本身已经带 PKG_FIXUP:=autoreconf，只有 libnftnl 需要补。
NFTNL_MK="package/libs/libnftnl/Makefile"
require_file "$NFTNL_MK"
if has_line '^PKG_FIXUP:=.*autoreconf' "$NFTNL_MK"; then
	sub "libnftnl 已带 PKG_FIXUP:=autoreconf"
else
	awk '!ins && /^include \$\(INCLUDE_DIR\)\/package\.mk/ { print "PKG_FIXUP:=autoreconf"; print ""; ins=1 } { print }' \
		"$NFTNL_MK" > "$NFTNL_MK.tmp" && mv "$NFTNL_MK.tmp" "$NFTNL_MK" ||
		{ rm -f "$NFTNL_MK.tmp"; die "无法给 $NFTNL_MK 注入 PKG_FIXUP"; }
	sub "libnftnl 已注入 PKG_FIXUP:=autoreconf"
fi

step "防火墙层：fw4（nftables，per-zone/per-proto）/ fw3（iptables）"
put "${PATCH_DIR}/001-firewall4-sonic-fullcone.patch" package/network/config/firewall4/patches 001-sonic-fullcone.patch
# 25.12 仍保留 firewall3 包，但默认用 fw4；fw3 补丁只在该包被选中编译时才生效
if [ -d package/network/config/firewall ]; then
	put "${PATCH_DIR}/001-firewall3-sonic-fullcone.patch" package/network/config/firewall/patches 001-sonic-fullcone.patch
else
	sub "firewall3 包不存在，跳过（正常，25.12 默认 fw4）"
fi

step "LuCI：把 fullcone 选项并进原生防火墙页面（不额外装 LuCI 应用）"
LUCI_FW="feeds/luci/applications/luci-app-firewall"
[ -d "$LUCI_FW" ] || die "找不到 $LUCI_FW；请先执行 ./scripts/feeds update -a && ./scripts/feeds install -a"
put "${PATCH_DIR}/001-luci-app-firewall-fullcone-options.patch" "$LUCI_FW/patches" 001-add-fullcone-options.patch

# po/ 不进 build_dir，用 patches/ 打不到翻译文件，只能直接追加。
# 追加块用 # BEGIN/END openwrt-sonic-fullcone 包住：重复执行时先删旧块再加。
# 否则上游改文案（「所有协议」→「以上全部」）之后，旧条目会残留，同一个 msgid
# 出现两条，msgfmt 取哪条是随机的。上游脚本也是这个做法，保持一致。
ZH_PO="$LUCI_FW/po/zh_Hans/firewall.po"
if [ -f "$ZH_PO" ]; then
	if has_text 'BEGIN openwrt-sonic-fullcone' "$ZH_PO"; then
		sed '/^# BEGIN openwrt-sonic-fullcone$/,/^# END openwrt-sonic-fullcone$/d' "$ZH_PO" > "$ZH_PO.tmp" &&
			mv "$ZH_PO.tmp" "$ZH_PO" || { rm -f "$ZH_PO.tmp"; die "清理旧翻译块失败: $ZH_PO"; }
	fi
	# 更早的版本没有标记块，只有裸条目，按整段删掉再追加。
	# 起止两个条件都要在：sed 的区间删除若匹配不到结束行，会一路删到文件末尾，
	# 把后面所有正常条目清空。上游脚本同样是两个条件同时判断。
	if has_text 'msgid "Fullcone NAT"' "$ZH_PO" && has_text 'msgstr "所有协议"' "$ZH_PO"; then
		sed '/^msgid "Fullcone NAT"$/,/^msgstr "所有协议"$/d' "$ZH_PO" > "$ZH_PO.tmp" &&
			mv "$ZH_PO.tmp" "$ZH_PO" || { rm -f "$ZH_PO.tmp"; die "清理旧翻译条目失败: $ZH_PO"; }
	fi
	printf '\n' >> "$ZH_PO"                       # 与上一条之间留空行，po 解析更稳
	cat "${PATCH_DIR}/zh_Hans.po" >> "$ZH_PO" || die "无法追加翻译到 $ZH_PO"
	has_text '以上全部' "$ZH_PO" || die "zh_Hans 翻译追加后校验失败（缺「以上全部」）"
	sub "zh_Hans 翻译已追加（标记块，可重复执行）"
else
	warn "$ZH_PO 不存在，跳过中文翻译（不影响功能）"
fi

step "落地校验"
miss=0
for f in "$HACK/984-add-sonic-fullcone-support.patch" \
         "$HACK/985-add-sonic-fullcone-to-ipt.patch" \
         "$HACK/986-add-sonic-fullcone-to-nft.patch" \
         "$HACK/987-sonic-fullcone-fix-races-and-drops.patch" \
         package/network/utils/iptables/patches/901-sonic-fullcone.patch \
         package/libs/libnftnl/patches/001-fullcone-expression.patch \
         package/network/utils/nftables/patches/002-fullcone-expression.patch \
         package/network/utils/nftables/patches/003-fullcone-json-parser.patch \
         package/network/config/firewall4/patches/001-sonic-fullcone.patch \
         "$LUCI_FW/patches/001-add-fullcone-options.patch"; do
	[ -s "$f" ] || { printf '  ✗ 缺失或为空: %s\n' "$f" >&2; miss=1; }
done
has_line '^PKG_FIXUP:=.*autoreconf' "$NFTNL_MK" || { echo "  ✗ libnftnl 缺 PKG_FIXUP" >&2; miss=1; }
[ "$miss" -eq 0 ] || die "有补丁未落到预期位置"

step "fullcone 补丁就位（11 个补丁 + libnftnl PKG_FIXUP + zh_Hans 翻译）"
sub "编译期由 OpenWrt 应用；补丁打不上会直接报错，不会静默跳过。"
sub "刷机后启用（defaults.fullcone 是总开关，关着时 zone 里的设置无效）："
cat <<'EOT'
      uci set firewall.@defaults[0].fullcone='1'
      uci set firewall.@zone[1].fullcone='1'
      uci add_list firewall.@zone[1].fullcone_proto='udp'   # 可选，仅 UDP
      uci commit firewall && /etc/init.d/firewall restart
    验证：nft list ruleset | grep fullcone
    测 NAT 类型：内网机器跑 pystun3，结果应为 Full Cone
EOT
