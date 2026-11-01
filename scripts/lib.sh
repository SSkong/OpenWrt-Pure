#!/usr/bin/env bash
# ==============================================================================
# scripts/*.sh 共用工具库：只定义函数与常量，source 时不产生副作用
#
# 用法（每个脚本开头的三行，顺序固定）：
#   #!/usr/bin/env bash
#   set -uo pipefail
#   . "$(cd "$(dirname "$0")" && pwd)/lib.sh"
#
# 这里不 set -e：调用方可能有意让某条命令失败（例如换源失败后回退官方版本），
# 一律在调用处显式 `|| die` / `|| warn`。
# ==============================================================================

# 仓库根目录（本文件位于 <root>/scripts/）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/config"
PATCHES_DIR="$ROOT/patches"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# GitHub Actions 会渲染成 workflow 注解；本地跑就是一行带前缀的提示
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

# 补丁必须是 LF。Windows 上 checkout 会把 .patch 转成 CRLF，打进 LF 的内核源码时
# 现象是 "context does not match"，离原因很远。
# 用 tr 逐字节数 CR：grep/awk 在 MSYS 文本模式会把 CR 吃掉，查不出来。
# check_no_crlf <文件或目录...>（目录递归）
check_no_crlf() {
	local p f n bad=""
	for p in "$@"; do
		[ -e "$p" ] || die "check_no_crlf: 路径不存在 $p"
	done
	bad="$(
		for p in "$@"; do
			if [ -d "$p" ]; then find "$p" -type f -print; else printf '%s\n' "$p"; fi
		done | while IFS= read -r f; do
			n="$(LC_ALL=C tr -cd '\r' < "$f" | wc -c)"
			[ "${n:-0}" -gt 0 ] && printf '%s(%s) ' "$f" "$n"
		done
	)"
	[ -z "$bad" ] || die "以下文件含 CRLF 行尾，需转成 LF: $bad"
}

# apply_patch_strict <补丁文件> [-p<层级>]
# 先做 fuzz=0 预检：offset 偏移可以接受（上游行号漂移是常态），fuzz 不可接受
# （fuzz>0 意味着上下文已经变了，补丁是靠猜位置打进去的）。
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

# ------------------------------------------------------------------------------
# config/devices.json —— 唯一的机器可读设备矩阵。
# jq 优先，回退 python3（GitHub runner 两者都有，本地至少有一个）。
# 原先 check-devices.sh 与 lint-config.sh 各写了一份双实现，这里收成一份。
# ------------------------------------------------------------------------------
JSON_TOOL=""

# 初始化并顺带校验 JSON 合法性，非主流程的调用方也可单独用
json_init() {
	[ -n "$JSON_TOOL" ] && return 0
	require_file "$CONFIG_DIR/devices.json"
	if command -v jq >/dev/null 2>&1; then
		JSON_TOOL=jq
	elif command -v python3 >/dev/null 2>&1; then
		JSON_TOOL=python3
	else
		die "需要 jq 或 python3 之一来读 $CONFIG_DIR/devices.json"
	fi
	case "$JSON_TOOL" in
		jq)      jq -e . "$CONFIG_DIR/devices.json" >/dev/null 2>&1 ;;
		python3) python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
		             "$CONFIG_DIR/devices.json" >/dev/null 2>&1 ;;
	esac || die "$CONFIG_DIR/devices.json 不是合法 JSON"
}

# 全部设备名，每行一个（去掉可能的 CR：Windows 上 python 会输出 CRLF）
json_devices() {
	json_init
	case "$JSON_TOOL" in
		jq)      jq -r '.[].name' "$CONFIG_DIR/devices.json" ;;
		python3) python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])):
    print(d.get("name") or "")' "$CONFIG_DIR/devices.json" ;;
	esac | tr -d '\r'
}

# json_dev_field <设备名> <字段>：取不到时输出空行
json_dev_field() {
	json_init
	case "$JSON_TOOL" in
		jq) jq -r --arg n "$1" --arg f "$2" \
				'.[] | select(.name == $n) | .[$f] // ""' "$CONFIG_DIR/devices.json" ;;
		python3) python3 -c 'import json,sys
n, f = sys.argv[2], sys.argv[3]
for d in json.load(open(sys.argv[1])):
    if d.get("name") == n:
        v = d.get(f)
        print(v if v is not None else "")
        break' "$CONFIG_DIR/devices.json" "$1" "$2" ;;
	esac | tr -d '\r'
}
