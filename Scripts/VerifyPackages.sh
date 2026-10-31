#!/bin/bash
# 校验「请求的包」是否真的进了最终 .config
#
# 背景：.config 是 base.config + 设备 config 拼接后经 make defconfig 生成，defconfig 会
# 按 kconfig 依赖重新求解，于是有两种失败形态：
#   a) 无对应源码目录 —— 包名写错、来源仓库没克隆下来
#   b) 被 defconfig 取消选中 —— 依赖不满足（CONFLICTS 互斥、@TARGET_xxx 限定、
#      DEPENDS 里的包没启用等）。这类不会报错，只会静默少东西。
#
# 为什么不拿官方二进制索引静态比对：apk 产物名与 buildroot 包名不是一一对应
# （libstdcpp → libstdcpp6 之类），静态核对会误报。以 defconfig 结果为权威。
#
# 用法：VerifyPackages.sh <openwrt目录> [设备名]
# 退出码：0 全部生效；1 有关键包未生效；2 前置文件缺失
set -u -o pipefail

DIR="${1:?用法: VerifyPackages.sh <openwrt目录> [设备名]}"
DEV="${2:-unknown}"

cd "$DIR" || { echo "ERROR: 进不去 $DIR" >&2; exit 2; }

for f in .config .config.requested; do
	[ -f "$f" ] || { echo "ERROR: 缺少 $f（应先跑「应用配置」步骤）" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 从 kconfig 里取「显式选中」的包名
extract_on() {
	grep -oE '^CONFIG_PACKAGE_[A-Za-z0-9._-]+=y' "$1" \
		| sed 's/^CONFIG_PACKAGE_//; s/=y$//' | sort -u
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
[ -z "$dropped" ] || echo "::warning::有包被 defconfig 取消选中（依赖不满足）:${dropped}"

# 关键清单：这些是「加了就该出现」的包，少一个就判失败，避免产出看着正常但缺功能的固件。
# 从 .config.requested 自动提取，不用手工维护清单。
# easytier 单独列出：它的 luci-app 不带核心包，是最容易「静默少东西」的一项。
grep -oE '^CONFIG_PACKAGE_(luci-app-[A-Za-z0-9._+-]+|luci-theme-[A-Za-z0-9._+-]+|stuntman-client|autocore-(arm|x86)|kmod-[A-Za-z0-9._+-]+|easytier)=y' .config.requested \
	| sed 's/^CONFIG_PACKAGE_//; s/=y$//' | sort -u > "$WORK/want"

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
	echo "ERROR: ${lost}/${total} 个关键包未生效" >&2
	exit 1
fi

echo "✅ ${total} 个关键包全部生效"
exit 0
