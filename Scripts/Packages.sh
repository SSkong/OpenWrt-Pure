#!/bin/bash
# 自定义软件包引入 —— 仅用户指定的原始上游仓库（全部克隆到 package/custom/<名称>）
#
# 原理：OpenWrt 按 Makefile 所在目录递归识别包，整仓克隆即可；仓库根本身是包、
# 或内部含多个子包目录，都能被正确发现，无需手工拆分。分支均已核实为默认分支。
#
# 原则：基底保持纯净（官方 25.12 + LuCI），只在这里引入下面点名的包；不加其它自定义包。
#
# 结构：四个阶段按序调用，失败点一眼可定位
#   clone_all    幂等克隆 45 个上游源        —— 失败会在阶段末一次性列出并退出
#   patch_vendor 给上游包打本地修正           —— 都是断言式：改完必须验到，否则退出
#   swap_feeds   替换 feeds 里的 golang/node  —— 允许失败并回退官方版本（有 warning）
#   dedupe       删除与 custom 同名的 feeds 副本（必须最后一步）
#
# 顺序约束：dedupe 必须最后，因为 swap_feeds 会执行 `feeds install -a` 重建
# package/feeds 下的符号链接 —— 先去重会被这次重建重新装回来。
set -uo pipefail
. "$(dirname "$0")/lib.sh"

enter "${1:-.}"

CLONE_FAILED=()
CLONE_FAIL_COUNT=0

# clone_pkg <目标名> <owner/repo> <分支>
# 目录名必须等于上游 Makefile 的 PKG_NAME（根 Makefile 无 PKG_NAME 时按目录名回退）。
# 网络抖动很常见，失败重试 3 次；仍失败只记名字，由 clone_all 在阶段末汇总退出
# （一次列出全部失败项，比遇到第一个就退更有用，且不会浪费后面的编译时间）。
clone_pkg() {
	local name="$1" repo="$2" branch="$3" try=1
	step "${name}  <= ${repo}@${branch}"
	while :; do
		rm -rf "package/custom/${name}"
		if git clone -q --depth 1 --single-branch -b "$branch" "https://github.com/${repo}.git" "package/custom/${name}" 2>/dev/null; then
			rm -rf "package/custom/${name}/.github" "package/custom/${name}/.git"
			return 0
		fi
		[ "$try" -ge 3 ] && break
		try=$((try + 1))
		sleep 5
	done
	printf '  ✗ 克隆失败（已重试 3 次）: %s@%s\n' "$repo" "$branch" >&2
	CLONE_FAILED+=("${repo}@${branch}")
	CLONE_FAIL_COUNT=$((CLONE_FAIL_COUNT + 1))
	return 1
}

# ==============================================================================
# 阶段 1：克隆全部上游源
# ==============================================================================
clone_all() {
	step "阶段 1/4 克隆上游源"
	ensure_dir package/custom

	# ---------- NAT 维护 / P2P（muink）----------
	clone_pkg natmapt             muink/openwrt-natmapt              master
	clone_pkg luci-app-natmapt    muink/luci-app-natmapt             master
	clone_pkg stuntman            muink/openwrt-stuntman             master   # stuntman-client/-server

	# ---------- DNS / 分流核心 ----------
	clone_pkg mosdns              sbwml/luci-app-mosdns              v5       # mosdns + geo2txt + luci-app-mosdns
	# smartdns 用 pymumu 上游原版替换 feeds 自带版本（feeds/packages/net/smartdns 与本仓库同名，
	# 由阶段 4 的通用去重逻辑删除）。核心包无条件 include feeds 的 rust-package.mk，
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

	# ---------- 测速 / 网络访问控制 ----------
	# cfs：Cloudflare 优选 IP + 测速，可联动 smartdns / 阿里 DDNS。LUCI_PKGARCH=all，
	# 主程序 cfst 不在包内，而是首次运行时按架构从 GitHub Releases 下载（脚本内置
	# ghfast.top / ghproxy.cc 镜像），所以设备侧需要 wget 或 curl + tar + gzip。
	clone_pkg luci-app-cloudflarespeedtest  stevenjoezhang/luci-app-cloudflarespeedtest  main
	# languard：LAN 侧访问控制，纯 shell + nft 规则集（会在 /etc/nftables.d/ 落 90-languard.nft），
	# 依赖 firewall4 / nftables / bash / coreutils，均为官方 feeds 包。
	clone_pkg luci-app-languard             rheatin/luci-app-languard                    main
	# apbridge：跨子网访问 AP / 光猫（本项目自研，见 README「自研插件」一节）。
	# 纯 JS 前端 + rpcd ucode 后端 + shell 做 uci 手术，LUCI_PKGARCH=all，无编译产物。
	clone_pkg luci-app-apbridge             SSkong/luci-app-apbridge                     main

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

	# ---------- sbwml openwrt_helloworld（科学插件防炸上游备份，整仓引入，README 要求）----------
	# 含 passwall/passwall2/ssr-plus/openclash/nikki/mihomo/dae/sing-box/xray/v2ray/trojan/
	# hysteria/shadowsocks 系列/lua-neturl/vmlinux-btf/homeproxy 等 44 个顶层包。
	# 未被 Config 选中的包不会编译，只参与包索引（无副作用）。
	clone_pkg helloworld          sbwml/openwrt_helloworld            v5

	if [ "$CLONE_FAIL_COUNT" -gt 0 ]; then
		printf 'ERROR: %d 个上游仓库克隆失败（各已重试 3 次）：\n' "$CLONE_FAIL_COUNT" >&2
		printf '  - %s\n' "${CLONE_FAILED[@]}" >&2
		exit 1
	fi
}

# ==============================================================================
# 阶段 2：给上游包打本地修正（改完必须验到，否则直接退出）
# ==============================================================================
patch_vendor() {
	step "阶段 2/4 上游包本地修正"

	# ---------- wolmon 相对 include 修正（克隆布局下 ../../luci.mk 指向错误）----------
	WOLMON_MK="package/custom/wolmon/src/luci-app-wolmon/Makefile"
	if [ -f "$WOLMON_MK" ]; then
		if has_text 'include $(TOPDIR)/feeds/luci/luci.mk' "$WOLMON_MK"; then
			sub "wolmon: include 已是绝对路径"
		elif has_text 'include ../../luci.mk' "$WOLMON_MK"; then
			sed -i 's|^include ../../luci.mk$|include $(TOPDIR)/feeds/luci/luci.mk|' "$WOLMON_MK" ||
				die "wolmon Makefile 改写失败: $WOLMON_MK"
			has_text 'include $(TOPDIR)/feeds/luci/luci.mk' "$WOLMON_MK" ||
				die "wolmon: include 改写未生效: $WOLMON_MK"
			sub "wolmon: include 路径已改为绝对路径"
		else
			warn "wolmon: $WOLMON_MK 里既没有 '../../luci.mk' 也没有绝对路径形式，布局可能已变，需人工确认"
		fi
	else
		warn "wolmon: 未找到 $WOLMON_MK，跳过 include 修正"
	fi

	# ---------- smartdns 源码校验：改为 skip ----------
	# 上游 Makefile 钉死了 PKG_SOURCE_VERSION 对应的 tar.gz sha256，而 codeload 对同一
	# commit 打包出的 tarball 并不保证字节级稳定（gzip 头含时间戳等），重打包即校验失败；
	# 它还会固定 smartdns-webui 的 hash，同样的问题。
	# OpenWrt 的 scripts/download.pl 明确支持 "skip"：hash_cmd() 按 hash 长度判断算法，
	# "skip" 长度为 4 使 hash_cmd 返回空，随后 `$hash_cmd or ($file_hash eq "skip")` 放行，
	# 后续校验都包在 if ($hash_cmd) 里，为空即整段跳过。
	SMARTDNS_MK="package/custom/smartdns/Makefile"
	if [ -f "$SMARTDNS_MK" ]; then
		sed -i -E 's|^(PKG_HASH:=).*|\1skip|; s|^(SMARTDNS_WEBUI_HASH:=).*|\1skip|' "$SMARTDNS_MK" ||
			die "smartdns Makefile 改写失败: $SMARTDNS_MK"
		# 改完必须验到：PKG_HASH 没改成 skip 的话 make download 阶段会校验失败，
		# 但那时已经过了 40 分钟的克隆/准备，错误又远不如此处直观。
		has_line '^PKG_HASH:=skip' "$SMARTDNS_MK" || die "smartdns: PKG_HASH 未改成 skip"
		has_line '^SMARTDNS_WEBUI_HASH:=skip' "$SMARTDNS_MK" || die "smartdns: SMARTDNS_WEBUI_HASH 未改成 skip"
		sub "smartdns: PKG_HASH / SMARTDNS_WEBUI_HASH 已设为 skip"
	else
		warn "smartdns: 未找到 $SMARTDNS_MK，跳过 hash 修正"
	fi

	# ---------- languard 的 postinst 从「文件」补成「宏」----------
	# 上游把安装后动作写成仓库根目录的 postinst / prerm / postrm 文件，但 OpenWrt 只认
	# Package/<name>/postinst 这种 make 宏——include/package-pack.mk 的 BuildPackVariable
	# 读的是 `ifdef Package/$(1)/$(2)`，文件形式完全不会被读取。后果不是编译失败，而是
	# 装上后服务没被 enable，重启后拦截规则不恢复（状态目录由 rpcd 后端 fs.mkdirr 兜底）。
	# 这里补一个等效宏，插在 include luci.mk 之前：luci.mk 自己的 postinst 有 ifndef 保护，
	# 且它定义在后面会覆盖前面的同名宏，所以必须放在 include 之前。
	LG_MK="package/custom/luci-app-languard/Makefile"
	LG_PI="package/custom/luci-app-languard/postinst"
	if [ -f "$LG_MK" ]; then
		if ! has_text 'Package/luci-app-languard/postinst' "$LG_MK"; then
			[ -f "$LG_PI" ] ||
				die "languard: 上游 postinst 文件不见了（$LG_PI），请确认上游打包方式是否变了"

			# 正文直接从上游 postinst 搬，不再手写。手写的简化版丢了上游的
			# [ -n "${IPKG_INSTROOT}" ] 守卫，而打包阶段（package/install）postinst 是在
			# host 上执行、用 IPKG_INSTROOT 指向目标 rootfs 的：没有守卫就会去
			#   mkdir -p /etc/languard          → Permission denied
			#   /etc/init.d/languard restart    → host 上没有，退出码 127
			# 于是 postinst 整体失败，package/install 报错（run 41150505816，H68K）。
			# 转换规则：
			#   1. 去掉 shebang、整行注释、空行
			#   2. 以反斜杠结尾的续行合并成一行 —— 正文最终由 package-pack.mk 用
			#        echo "<宏内容>" > postinst-pkg
			#      落盘，反斜杠在部分 shell 的 echo 里会被当转义符吃掉
			#   3. 每个 $ 写成 $$，make 展开后剩一个（与 luci.mk / rpcd 的写法一致）
			awk '
				FNR == NR {
					if ($0 ~ /^#!/ || $0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
					line = $0
					while (line ~ /\\$/) {
						sub(/\\$/, "", line)
						if ((getline nxt) <= 0) break
						sub(/^[[:space:]]+/, "", nxt)
						line = line " " nxt
					}
					gsub(/\$/, "$$", line)
					body = body line "\n"
					next
				}
				/^include \$\(TOPDIR\)\/feeds\/luci\/luci\.mk/ && !ins {
					print "define Package/luci-app-languard/postinst"
					printf "%s", body
					print "endef"
					print ""
					ins = 1
				}
				{ print }
			' "$LG_PI" "$LG_MK" > "$LG_MK.tmp" ||
				{ rm -f "$LG_MK.tmp"; die "languard: 生成 postinst 宏失败（awk 出错）"; }
			has_text 'define Package/luci-app-languard/postinst' "$LG_MK.tmp" ||
				{ rm -f "$LG_MK.tmp"; die "languard: $LG_MK 里找不到 'include \$(TOPDIR)/feeds/luci/luci.mk' 锚点，宏插不进去"; }
			has_text '[ -n "$${IPKG_INSTROOT}" ] || {' "$LG_MK.tmp" ||
				{ rm -f "$LG_MK.tmp"; die "languard: 生成的宏里没有 IPKG_INSTROOT 守卫，上游 postinst 结构可能变了"; }
			mv "$LG_MK.tmp" "$LG_MK" || die "languard: 写回 $LG_MK 失败"
			sub "languard: 已从上游 postinst 生成 Package/luci-app-languard/postinst 宏"
		fi
		has_text 'Package/luci-app-languard/postinst' "$LG_MK" ||
			die "languard: postinst 宏未注入成功（$LG_MK）"
	else
		warn "languard: 未找到 $LG_MK，跳过 postinst 注入"
	fi
}

# ==============================================================================
# 阶段 3：替换 feeds 里的 golang / node
# 这两处允许失败并回退官方版本（有 warning），因为它们不是硬依赖：
# golang 回退只是 helloworld 的 Go 包可能编不过，node 回退只是编译慢。
# ==============================================================================
swap_feeds() {
	step "阶段 3/4 替换 feeds 的 golang / node"

	# README 配套操作①：golang 换成 sbwml 27.x（helloworld 的 Go 核心按该版本构建，官方版本可能编不过）
	if [ -d feeds/packages/lang/golang ]; then
		rm -rf feeds/packages/lang/golang
		if git clone -q --depth 1 -b 27.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang; then
			# lang/golang 目录重建后，此前 scripts/feeds install -a 建的符号链接全部悬空，需重建
			./scripts/feeds install -a >/dev/null 2>&1 || warn "golang 换源后 feeds install -a 有报错，链接可能未全部重建"
			sub "golang 已切换为 sbwml 27.x 并重建 feeds 链接"
		else
			warn "golang 27.x 换源失败，沿用官方版本"
		fi
	else
		warn "feeds/packages/lang/golang 不存在，跳过换源"
	fi

	# README 配套操作②：node 换成 sbwml 预编译版 https://github.com/sbwml/feeds_packages_lang_node
	# （官方 node 从源码编译极慢；sbwml 用 release 预编译产物秒装。原地替换路径，
	#  package/feeds/packages/node 符号链接指向同一路径无需重建。
	#  注意：不要替换 $(ARCH_PACKAGES)！它在三目标上本就展开为正确资产名
	#  （x86→x86_64、BPI-R4→aarch64_cortex-a53、H68K→aarch64_generic），硬编码会串架构）
	#
	#  PKG_VERSION 必须自己钉死。上游 Makefile 写的是：
	#    PKG_VERSION:=$(shell curl -s https://api.github.com/repos/sbwml/node_workflow/tags | ...)
	#  解析 Makefile 时就发一次未认证的 GitHub API 请求。CI runner 是共享出口 IP，
	#  未认证配额只有 60 次/小时，被限流时返回体里没有 "name" 字段 → 正则匹配不到
	#  → PKG_VERSION 变成空串 → 下载地址变成 .../releases/download/v/x86_64.tar.gz
	#  → 404 →「install: cannot stat .../node-/usr/bin/node」→ 编译 4 小时后才失败
	#  （run 41150505816，X86；同时 build_dir 也变成 node-）。
	#  改用 git ls-remote 取最新 tag（走 git 协议，不吃 API 配额）再写回 Makefile。
	if [ -d feeds/packages/lang/node ]; then
		rm -rf feeds/packages/lang/node
		if git clone -q --depth 1 -b packages-25.12 https://github.com/sbwml/feeds_packages_lang_node feeds/packages/lang/node; then
			NODE_MK="feeds/packages/lang/node/Makefile"
			node_ver="$(git ls-remote --tags --refs https://github.com/sbwml/node_workflow 'v*' 2>/dev/null |
				sed 's|.*refs/tags/v||' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)"
			if [ -z "$node_ver" ]; then
				die "node: 取不到 sbwml/node_workflow 的最新 tag。若不钉版本，上游会在解析时 curl GitHub API，被限流就得到空版本号，最终在下载阶段 404（已浪费过一次 4 小时构建）"
			fi
			sed -i -E "s|^PKG_VERSION:=.*node_workflow.*|PKG_VERSION:=$node_ver|" "$NODE_MK" ||
				die "node: 改写 $NODE_MK 的 PKG_VERSION 失败"
			grep -qxF "PKG_VERSION:=$node_ver" "$NODE_MK" ||
				die "node: PKG_VERSION 未钉入成功（$NODE_MK 里没有 'PKG_VERSION:=$node_ver'，上游 Makefile 布局已变？）"
			sub "node 已切换为 sbwml 预编译版，PKG_VERSION 钉为 $node_ver"
		else
			warn "sbwml node 换源失败，沿用官方版本"
		fi
	else
		warn "feeds/packages/lang/node 不存在，跳过换源"
	fi
}

# ==============================================================================
# 阶段 4：去重（必须最后一步）
# 删除 feeds 源码树与 package/feeds 符号链接中、与 package/custom 同名的副本，
# 否则 buildroot 收集阶段重复定义直接报错。上面的 swap_feeds 会重建 package/feeds
# 下的链接，所以这一步必须晚于它。
# ==============================================================================
dedupe() {
	step "阶段 4/4 与 custom 同名的 feeds 副本去重"

	# 取全部 custom 包的 PKG_NAME（根 Makefile 无 PKG_NAME 者按 luci.mk 目录名回退），
	# 并追加 CONFLICTS 名单：官方 feeds 里与 custom 包互斥的旧副本必须一并删除。
	# 例：luci-app-adguardhome-tk 声明 CONFLICTS:=luci-app-adguardhome，而官方 luci-app-adguardhome
	# 属 luci 合集默认 =y，其 CONFLICTS 经 kconfig 变成 "depends on !PACKAGE_luci-app-adguardhome"，
	# 若不删官方副本，tk 变体会被 defconfig 静默取消选中。
	hb_names="$(mktemp)" || die "mktemp 失败"
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
			rm -rf "$d"; removed=$((removed + 1))
		done
		for l in $(find package/feeds -maxdepth 2 -name "$n" 2>/dev/null); do
			rm -rf "$l"; removed=$((removed + 1))
		done
	done < "$hb_names"
	rm -f "$hb_names"
	sub "移除 feeds 中与 custom 同名的副本 ${removed} 处"
}

# ==============================================================================
clone_all
patch_vendor
swap_feeds
dedupe

step "自定义包目录："
find package/custom -maxdepth 1 -mindepth 1 -type d | sort
sub "识别到的 Makefile 数：$(find package/custom -name Makefile | wc -l)"
