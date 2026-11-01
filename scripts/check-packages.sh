#!/usr/bin/env bash
# ==============================================================================
# 校验「请求的包」是否真的进了最终 .config
#
# 背景：.config 是 base.config + 设备 config 拼接后经 make defconfig 生成，defconfig
# 会按 kconfig 依赖重新求解，于是有两种失败形态：
#   a) 无对应源码目录 —— 包名写错、来源仓库没克隆下来
#   b) 被 defconfig 取消选中 —— 依赖不满足（CONFLICTS 互斥、@TARGET_xxx 限定、
#      DEPENDS 里的包没启用等）。这类不会报错，只会静默少东西。
#
# 为什么不拿官方二进制索引静态比对：apk 产物名与 buildroot 包名不是一一对应
# （libstdcpp → libstdcpp6 之类），静态核对会误报。以 defconfig 结果为权威。
#
# 用法：scripts/check-packages.sh <openwrt目录> [设备名]
# 退出码：0 全部生效；1 有关键包未生效；2 前置文件缺失
# ==============================================================================

set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DIR="${1:?用法: check-packages.sh <openwrt目录> [设备名]}"
DEV="${2:-unknown}"

[ -d "$DIR" ] || { printf 'ERROR: 进不去 %s\n' "$DIR" >&2; exit 2; }
enter "$DIR"
for f in .config .config.requested; do
	[ -f "$f" ] || { printf 'ERROR: 缺少 %s（应先跑「应用配置」步骤）\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d)" || die "mktemp 失败"
trap 'rm -rf "$WORK"' EXIT

# 从 kconfig 里取「显式选中」的包名。
#
# 必须按「同一符号以最后一行为准」来算：.config.requested 是 base.config 与设备
# config **顺序拼接**的，设备级覆盖（`# CONFIG_X is not set` 写在 base 的 `=y`
# 之后）才是最终意图。直接 grep `=y` 会让设备级关掉的包同时出现在「请求」和
# 「未生效」里 —— 明明是有意关掉的，构建却判失败（x86 关 luci-app-dockox 时就会踩到）。
#
# 另外必须容忍行尾注释：base.config 里有 `CONFIG_PACKAGE_kmod-mt7921u=y   # MT7921 …`
# 这种写法，kconfig 读取时会把 `#` 之后连同前面空白一起丢掉（历次构建里这些包都
# 真的生效了），但带 `$` 锚点的正则匹配不到。漏掉的后果不是报错而是**静默不校验**
# —— 那行恰好是 kmod-mt7921u，正是关键包清单里的一项。
extract_on() {
	awk '
		{
			line = $0
			sub(/\r$/, "", line)                    # 防 CRLF
			if (line !~ /^[ \t]*#/) {               # 注释行原样保留
				sub(/[ \t]+#.*$/, "", line)         # 行尾注释（kconfig 同样忽略）
				sub(/[ \t]+$/, "", line)
			}
			if (line ~ /^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=y$/) {
				s = line; sub(/=y$/, "", s); st[s] = "y"; next
			}
			if (line ~ /^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=/) {
				s = line; sub(/=.*/, "", s); st[s] = "other"; next
			}
			if (line ~ /^# CONFIG_PACKAGE_[A-Za-z0-9._+-]+ is not set$/) {
				s = line; sub(/^# /, "", s); sub(/ is not set$/, "", s); st[s] = "n"; next
			}
		}
		END { for (s in st) if (st[s] == "y") print s }
	' "$1" | sed 's/^CONFIG_PACKAGE_//' | sort -u
}

extract_on .config.requested > "$WORK/req"
extract_on .config > "$WORK/fin"

# 包目录索引：一次性建表。原先每个包跑一次 `find package feeds -maxdepth 6`，
# 200 个包就是 200 次全树遍历，在 CI 上要几十秒。
find package feeds -maxdepth 6 -type d 2>/dev/null | sed 's#.*/##' | sort -u > "$WORK/dirs" || true

nodir=""
dropped=""
while read -r pkg; do
	[ -n "$pkg" ] || continue
	grep -qxF "$pkg" "$WORK/dirs" || nodir="$nodir $pkg"
	grep -qxF "$pkg" "$WORK/fin"  || dropped="$dropped $pkg"
done < "$WORK/req"

REQ_N=$(wc -l < "$WORK/req" | tr -d ' ')

summary() {
	# 本地跑时没有这个变量，直接跳过
	[ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
	{
		echo "### 包生效校验（${DEV}）"
		echo ""
		echo "- 请求数：${REQ_N}"
		echo "- 无源码目录：${nodir:-无}"
		echo "- defconfig 后取消选中：${dropped:-无}"
		echo "- 关键包未生效：${lost:-0}"
	} >> "$GITHUB_STEP_SUMMARY"
}

echo "请求包数: ${REQ_N}"
echo "无源码目录:${nodir:- 无}"
echo "被 defconfig 取消:${dropped:- 无}"
[ -z "$dropped" ] || warn "有包被 defconfig 取消选中（依赖不满足）:${dropped}"

# 设备级显式关闭：base 里有、最终意图里没有。这类是**有意**关掉的，不该进关键清单，
# 也不该报错，但要打出来 —— 否则「明明关了却还在校验」这种自相矛盾没法被看见。
dev_cfg="$CONFIG_DIR/${DEV}.config"
base_cfg="$CONFIG_DIR/base.config"
if [ -f "$base_cfg" ] && [ -f "$dev_cfg" ]; then
	extract_on "$base_cfg" > "$WORK/base"
	off="$(comm -23 "$WORK/base" "$WORK/req" | tr '\n' ' ' | sed 's/ *$//')"
	echo "设备级关闭: ${off:-无}"
fi

# 关键清单：这些是「加了就该出现」的包，少一个就判失败，避免产出看着正常但缺功能的固件。
# 不手工维护清单，而是从**最终意图**（$WORK/req，已按「同符号最后一行为准」求解）里筛。
#
# 这里曾经是直接 `grep '^CONFIG_PACKAGE_...=y' .config.requested`：grep -o 只看前缀，
# 不看后面是否被设备配置关掉，于是 x86 明确写着
# `# CONFIG_PACKAGE_luci-app-dockox is not set`，它照样被算成「请求了但没生效」，
# 构建在 4 分钟就红（run 41203401554）。已改为复用 req，与上面的判定同一口径。
awk '{
	if ($0 ~ /^(luci-app-|luci-theme-|kmod-)/ ||
	    $0 == "stuntman-client" || $0 == "easytier" ||
	    $0 == "etherwake" ||
	    $0 == "autocore-arm" || $0 == "autocore-x86") print $0
}' "$WORK/req" | sort -u > "$WORK/want"

lost=0
total=0
missing=""
while read -r w; do
	[ -n "$w" ] || continue
	total=$((total + 1))
	if ! grep -qxF "$w" "$WORK/fin"; then
		echo "✗ 未生效: $w"
		missing="$missing $w"
		lost=$((lost + 1))
	fi
done < "$WORK/want"

# 依赖诊断：把未生效包的 depends on 段打印出来，并标出哪个依赖符号最终没启用。
# 目的是一次构建就能定位原因，而不是反复盲试。
if [ "$lost" -gt 0 ]; then
	echo "----- 依赖诊断 -----"

	if [ ! -f tmp/.config-package.in ]; then
		echo "  （tmp/.config-package.in 不存在，跳过符号级诊断）"
	fi

	for w in $missing; do
		start=""
		if [ -f tmp/.config-package.in ]; then
			start=$(grep -n "^config PACKAGE_${w}\$" tmp/.config-package.in | head -1 | cut -d: -f1)
		fi

		if [ -z "$start" ]; then
			echo "  [$w] 未出现在 tmp/.config-package.in → 该包没被 buildroot 采集"
			hit=$(grep -rl "Package/$w" package --include=Makefile 2>/dev/null | head -5)
			if [ -n "$hit" ]; then
				echo "    定义 Package/$w 的 Makefile: $(echo "$hit" | tr '\n' ' ')"
			else
				echo "    package 树中没有 Makefile 定义 Package/$w（包名不符，或 Makefile 被跳过）"
			fi
			d=""
			if grep -qxF "$w" "$WORK/dirs"; then
				d=$(find package feeds -maxdepth 6 -type d -name "$w" 2>/dev/null | head -1)
			fi
			if [ -n "$d" ]; then
				echo "    包目录: $d"
				echo "    PKG_NAME: $(grep -h '^PKG_NAME' "$d/Makefile" 2>/dev/null | head -1)"
			fi
			continue
		fi

		# 取该包的 kconfig 段：从 config 行起，到下一个 config 行前为止
		awk -v s="$start" 'NR >= s { if (NR > s && /^config /) exit; print }' tmp/.config-package.in \
			| grep -E "^(config|	prompt|	depends on|	select|	visible)" \
			| while read -r ln; do
				case "$ln" in
					config\ *)
						echo "  [$w]   $ln"
						continue
						;;
				esac

				# 只取第一个包符号，并保留前置的 ! —— 否定依赖的判断方向相反：
				# depends on !PACKAGE_x 时，x 未启用才满足条件。
				raw=$(echo "$ln" | grep -oE '!?PACKAGE_[A-Za-z0-9._+-]+' | head -1)
				if [ -z "$raw" ]; then
					echo "  [$w]   $ln"
					continue
				fi

				neg=""
				name="${raw#PACKAGE_}"
				case "$raw" in
					'!'*) neg=1; name="${raw#!PACKAGE_}" ;;
				esac

				if grep -qxF "$name" "$WORK/fin"; then
					state="已启用"
				else
					state="未启用"
				fi

				if [ -n "$neg" ]; then
					# 否定依赖：未启用才算满足
					case "$state" in
						未启用) echo "  [$w] ✓满足  $ln" ;;
						*)      echo "  [$w] ✗不满足（该包不应启用）  $ln" ;;
					esac
				else
					case "$state" in
						已启用) echo "  [$w] ✓$state  $ln" ;;
						*)      echo "  [$w] ✗$state  $ln" ;;
					esac
				fi
			done
	done

	echo "----- 依赖诊断结束 -----"
fi

summary

if [ "$lost" -ne 0 ]; then
	die "${lost}/${total} 个关键包未生效"
fi

step "${total} 个关键包全部生效"
exit 0
