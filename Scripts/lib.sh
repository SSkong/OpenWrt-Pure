#!/usr/bin/env bash
# ==============================================================================
# Scripts/*.sh 共用的小工具库 —— 只定义函数，source 时不产生任何副作用
#
# 用法（各脚本头部）：
#   set -uo pipefail
#   . "$(dirname "$0")/lib.sh"
#
# 存在的理由：H68K.sh 与 Fullcone.sh 原本各写了一遍「文件/目录存在性 → fuzz=0 预检 →
# 失败降级 → .rej 扫描 → 落地确认」这套补丁 idiom，逻辑相同但错误文案不同，靠两份
# 拷贝维持一致迟早漂移（比如 CRLF 检查只有 Fullcone 有）。这里统一成一份。
# ==============================================================================

# 注意：本文件被 source，不要在这里 set -e —— 调用方可能有意让某些命令失败
# （例如 Packages.sh 允许换源失败后回退到官方版本）。统一在调用处显式 || die。

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# GitHub Actions 会把它渲染成 workflow 注解，本地跑就是一行带前缀的提示
warn() { printf '::warning::%s\n' "$*"; }

step() { printf '==> %s\n' "$*"; }
sub()  { printf '    %s\n' "$*"; }

usage_die() { printf '用法: %s\n' "$*" >&2; exit 2; }

require_file() {
	[ -f "${1:?require_file: 缺路径}" ] || die "${2:-找不到文件 $1}"
}

require_dir() {
	[ -d "${1:?require_dir: 缺路径}" ] || die "${2:-找不到目录 $1}"
}

# 进入目录失败就直接退（比 `cd x || exit 1` 多一句上下文）
enter() {
	cd "${1:?enter: 缺目录}" 2>/dev/null || die "无法进入目录 $1"
}

# mkdir -p 失败多半是父路径不可写，别让它静默继续
ensure_dir() {
	mkdir -p "${1:?ensure_dir: 缺路径}" || die "无法创建目录 $1"
}

# put <源文件> <目标目录> <目标文件名>
put() {
	local src="${1:?put: 缺源文件}" dst="${2:?put: 缺目标目录}" name="${3:?put: 缺目标文件名}"
	require_file "$src"
	ensure_dir "$dst"
	cp -f "$src" "$dst/$name" || die "无法写入 $dst/$name"
	[ -s "$dst/$name" ] || die "写入后为空: $dst/$name"
}

# 补丁必须是 LF。Windows 下 checkout 会把 .patch 转成 CRLF，打进 LF 的内核源码时
# 现象是 "context does not match" 且极难看出是行尾问题。
# 用 tr 逐字节数 CR：grep/awk 在 MSYS 文本模式会把 CR 吃掉，查不出来。
# check_no_crlf <文件或目录...>
check_no_crlf() {
	local f n bad=""
	for f in "$@"; do
		[ -e "$f" ] || die "check_no_crlf: 路径不存在 $f"
		if [ -d "$f" ]; then
			for g in "$f"/*; do
				[ -f "$g" ] || continue
				n="$(LC_ALL=C tr -cd '\r' < "$g" | wc -c)"
				[ "${n:-0}" -gt 0 ] && bad="$bad $g"
			done
		else
			n="$(LC_ALL=C tr -cd '\r' < "$f" | wc -c)"
			[ "${n:-0}" -gt 0 ] && bad="$bad $f"
		fi
	done
	[ -z "$bad" ] || die "补丁含 CRLF 行尾，需转成 LF:$bad"
}

# apply_patch_strict <补丁文件> [-p<层级>]
# 先做 fuzz=0 预检：offset 偏移可以接受（上游行号漂移是常态），fuzz 不可接受
# （fuzz>0 意味着上下文已经变了，patch 是靠猜位置打进去的）。
# 预检不过才降级到默认 fuzz，并在输出里明说降级了。
apply_patch_strict() {
	local p="${1:?apply_patch_strict: 缺补丁}" strip="${2:--p1}"
	require_file "$p"
	if patch "$strip" --fuzz=0 --dry-run --forward < "$p" >/dev/null 2>&1; then
		patch "$strip" --fuzz=0 --forward < "$p" >/dev/null ||
			die "补丁应用失败（fuzz=0 预检已通过，实际写入却失败）: $p"
		sub "精确应用（fuzz=0）"
	else
		sub "上下文有漂移，按默认 fuzz 应用"
		patch "$strip" --forward --no-backup-if-mismatch < "$p" ||
			die "补丁应用失败：$p（上游结构可能已变，需重新 rebase）"
	fi
}

# check_rej [搜索根...]（缺省 .）
# 部分失败的补丁会留下 .rej，绝不能当成功继续
check_rej() {
	local roots=("$@") rej
	[ "${#roots[@]}" -gt 0 ] || roots=(.)
	rej="$(find "${roots[@]}" -name '*.rej' -type f 2>/dev/null | head -5)"
	[ -z "$rej" ] || die "补丁未完整落地，遗留 .rej 文件: $rej"
}

# grep 的「存在即成功」包装，配合 || die 使用
#   has_line —— 正则（BRE）。注意别用 \$ 转义字面量 $：GNU grep 的 BRE 里
#               \+特殊字符的行为并不一致，实测 '\$\(TOPDIR\)' 匹配不到 " $(TOPDIR)"。
#               字面量请用字符类 [$]，或者直接用 has_text。
#   has_text —— 固定字符串（grep -F），断言"改完的文件里确实有这行"时用这个最稳。
has_line() { grep -q -- "$1" "${2:?has_line: 缺文件}"; }
has_text() { grep -qF -- "$1" "${2:?has_text: 缺文件}"; }
