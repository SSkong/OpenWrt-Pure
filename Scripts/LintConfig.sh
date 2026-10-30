#!/usr/bin/env bash
# ==============================================================================
# 配置离线 lint —— 不需要联网、不需要 OpenWrt 源码树，几十毫秒
#
# 建这个脚本的原因：我们已经多次靠人工核对「包名写错没」「是不是重复了」「设备覆盖
# 到底生效没生效」。其中三类错误完全可以在本地/PR 阶段静态查出来，不必花两小时构建：
#
#   A. 行语法          既不是注释、也不是 `CONFIG_X=y|m|N|"..."|# CONFIG_X is not set`
#                      —— 多为手滑截断、缺引号、说明文字混进了符号行
#   B. 文件内重复符号   同一文件里同一符号写了两遍。kconfig 取最后一行，前面那行是
#                      静默失效的死代码，而且极易让人误判当前生效值
#   C. 覆盖顺序        base.config 与设备 config 是**顺序拼接**后交给 defconfig 的，
#                      同一符号后出现的为准。所以想关掉 base 里打开的包，
#                      `# CONFIG_X is not set` 必须写在 `CONFIG_X=y` **之后**；
#                      写在前面等于没关（lint 报 ERROR）。反过来（后面是 is not set）
#                      是正确的设备级覆盖，只打印一行说明覆盖了什么。
#
# 用法：bash Scripts/LintConfig.sh [设备名,设备名...]   # 缺省=devices.json 里的全部
# 退出码：0 通过 / 1 有 ERROR
# ==============================================================================

set -uo pipefail
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_CFG="$ROOT/Config/base.config"
CFG_DIR="$ROOT/Config"
DEV_JSON="$ROOT/Config/devices.json"
require_file "$BASE_CFG"

rc=0
err() { printf '  ✗ %s\n' "$*" >&2; rc=1; }

# 去尾部空白。必须写成纯参数展开：这里每行都要调一次，用命令替换 $(...) 会
# 每行 fork 一个子 shell，500 行 × 5 个文件就把脚本拖到近一分钟。
#   rtrim <变量名>   —— 直接改调用方变量（bash 的 nameref 在 4.3+ 可用）
rtrim() {
	local -n _s="$1"
	case "$_s" in
		*[![:space:]]*) _s="${_s%%"${_s##*[![:space:]]}"}" ;;
		*) _s="" ;;
	esac
}

dev_names_from_json() {
	[ -f "$DEV_JSON" ] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -r '.[].name' "$DEV_JSON" 2>/dev/null | grep -v '^$' && return 0
		return 1
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])): print(d.get("name") or "")' "$DEV_JSON" 2>/dev/null | grep -v '^$' && return 0
		return 1
	fi
	return 1
}

devices=()
if [ "${1:-}" != "" ]; then
	IFS=',' read -r -a devices <<< "$1"
else
	mapfile -t devices < <(dev_names_from_json)
	if [ "${#devices[@]}" -eq 0 ]; then
		while IFS= read -r f; do
			n="$(basename "$f" .config)"
			[ "$n" = "base" ] || devices+=("$n")
		done < <(find "$CFG_DIR" -maxdepth 1 -name '*.config' -type f | sort)
	fi
fi

# ---------- A + B：逐文件扫描 ----------
scan_file() {
	local f="$1" lineno=0 line body sym seen=""
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		body="$line"
		# 行尾注释是这里的常态（`CONFIG_X=y   # 说明`），先剥掉再判语法。
		# 只在 " #" 处切，避免动到 CONFIG_X="a # b" 这种值（真出现时它仍能被下面的
		# *="*" 分支认下）。
		case "$body" in *' '#*) body="${body%% #*}" ;; esac
		rtrim body

		case "$body" in
			''|'#'*)
				case "$body" in
					'# CONFIG_'*' is not set')
						sym="CONFIG_${body#\# CONFIG_}"; sym="${sym% is not set}"
						[ -n "$sym" ] && seen="$seen$sym"$'\n' ;;
					'# CONFIG_'*)
						err "$f:$lineno 注释掉的符号行写法异常：$body" ;;
				esac
				continue ;;
			CONFIG_*)
				case "$body" in
					# 注意：case 模式里被引号包住的 * 会变成字面量，所以 "..." 这一支
					# 必须写成转义引号 *=\"*\" ，不能写成 *='"*"'
					*'=y'|*'=m'|*=[0-9]*|*=\"*\") : ;;
					*) err "$f:$lineno 符号行写法异常：$body" ;;
				esac
				sym="${body%%=*}"
				[ "$sym" = "CONFIG_" ] && err "$f:$lineno 符号名为空：$body"
				seen="$seen$sym"$'\n' ;;
			*) err "$f:$lineno 既不是注释也不是 CONFIG_ 行：$body" ;;
		esac
	done < "$f"

	# B：同一文件内同一符号出现多次
	dups="$(printf '%s' "$seen" | grep -v '^$' | sort | uniq -d)"
	while IFS= read -r d; do
		[ -n "$d" ] && err "$f 内符号重复定义（kconfig 只取最后一行）：$d"
	done <<< "$dups"
}

step "A/B 逐文件扫描（行语法 + 文件内重复符号）"
scan_file "$BASE_CFG"
for d in "${devices[@]}"; do
	[ -f "$CFG_DIR/$d.config" ] && scan_file "$CFG_DIR/$d.config"
done

# ---------- C：覆盖顺序（base 在前、设备在后，后者为准）----------
# 单趟扫描：按顺序读 base 再读设备，同一符号只记「首次状态」与「末次状态」。
# 第一版是"对每个符号再 grep 一遍全文"，200 个符号 × 3 设备就是近两千次子进程，
# 在本机慢到像挂死；这里用关联数组做到零子进程。
step "C 覆盖顺序（base.config 在前，设备 config 在后，后者为准）"
for d in "${devices[@]}"; do
	cfg="$CFG_DIR/$d.config"
	[ -f "$cfg" ] || continue

	declare -A f_state=() l_state=() f_src=() l_src=() cnt=()
	for pair in "base:$BASE_CFG" "dev:$cfg"; do
		src="${pair%%:*}"
		file="${pair#*:}"
		while IFS= read -r line || [ -n "$line" ]; do
			body="$line"
			case "$body" in *' '#*) body="${body%% #*}" ;; esac
			rtrim body
			case "$body" in
				'# CONFIG_'*' is not set')
					sym="CONFIG_${body#\# CONFIG_}"; sym="${sym% is not set}"; st=off ;;
				CONFIG_*)
					sym="${body%%=*}"; st=on ;;
				*) continue ;;
			esac
			[ -n "$sym" ] && [ "$sym" != "CONFIG_" ] || continue
			if [ -z "${cnt[$sym]:-}" ]; then
				f_state[$sym]="$st"; f_src[$sym]="$src"; cnt[$sym]=1
			else
				cnt[$sym]=$((cnt[$sym] + 1))
			fi
			l_state[$sym]="$st"; l_src[$sym]="$src"
		done < "$file"
	done

	for sym in "${!cnt[@]}"; do
		[ "${cnt[$sym]}" -ge 2 ] || continue
		[ "${f_state[$sym]}" != "${l_state[$sym]}" ] || continue
		if [ "${l_state[$sym]}" = on ]; then
			err "$d：$sym 先写 is not set（${f_src[$sym]}）又被打开（${l_src[$sym]}），关闭不生效 —— is not set 必须写在 =y 之后"
		else
			printf '  • %s：%s 由 %s 打开、被 %s 关闭（覆盖生效）\n' \
				"$d" "$sym" "${f_src[$sym]}" "${l_src[$sym]}"
		fi
	done
	unset f_state l_state f_src l_src cnt
done

[ "$rc" -eq 0 ] || die "配置 lint 未通过，见上"
step "配置 lint 通过"
