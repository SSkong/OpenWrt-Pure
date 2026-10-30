#!/usr/bin/env bash
# ==============================================================================
# 设备矩阵 ↔ Config/<设备>.config 交叉校验（离线，几十毫秒）
#
# 背景：设备矩阵（Config/devices.json）和设备配置（Config/<name>.config）是两份
# 事实，原先任何一方漏改都要等到构建最后一步「未找到任何固件产物」才暴露——那时
# 已经烧掉两小时。这里在构建开始前就把三类错位挡掉：
#   1. devices.json 里有设备，但 Config/<name>.config 不存在
#   2. target / profile 与 Config/<name>.config 里的 CONFIG_TARGET_* 不一致
#      （target "a/b" 对应 CONFIG_TARGET_a=y + CONFIG_TARGET_a_b=y，
#       profile 对应 CONFIG_TARGET_a_b_DEVICE_<profile>=y）
#   3. Config/*.config 存在但 devices.json 里没有（反向，只警告：允许在制品）
#
# 读 JSON 用 jq，没有 jq 时回退 python3 —— 两者 GitHub runner 都有，本地至少有一个。
#
# 用法：bash Scripts/CheckDevices.sh [设备名,设备名...]   # 缺省=校验全部
# 退出码：0 通过 / 1 有阻断性错误 / 2 用法或依赖缺失
# ==============================================================================

set -uo pipefail
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_JSON="$ROOT/Config/devices.json"
CFG_DIR="$ROOT/Config"
require_file "$DEV_JSON"

# ---------- JSON 读取：jq 优先，回退 python3 ----------
if command -v jq >/dev/null 2>&1; then
	JSON=jq
elif command -v python3 >/dev/null 2>&1; then
	JSON=python3
else
	die "需要 jq 或 python3 之一来读 $DEV_JSON"
fi

json_ok() {
	case "$JSON" in
		jq) jq -e . "$DEV_JSON" >/dev/null 2>&1 ;;
		python3) python3 -c 'import json,sys
json.load(open(sys.argv[1]))' "$DEV_JSON" >/dev/null 2>&1 ;;
	esac
}
dev_names() {
	case "$JSON" in
		jq) jq -r '.[].name' "$DEV_JSON" ;;
		python3) python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])): print(d.get("name") or "")' "$DEV_JSON" ;;
	esac
}
# dev_get <name> <field>
dev_get() {
	case "$JSON" in
		jq) jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f] // ""' "$DEV_JSON" ;;
		python3) python3 -c 'import json,sys
n, f = sys.argv[2], sys.argv[3]
for d in json.load(open(sys.argv[1])):
    if d.get("name") == n:
        v = d.get(f)
        print(v if v is not None else "")
        break' "$DEV_JSON" "$1" "$2" ;;
	esac
}

json_ok || die "$DEV_JSON 不是合法 JSON"

# ---------- 待校验设备 ----------
want=()
if [ "${1:-}" = "" ]; then
	mapfile -t want < <(dev_names)
else
	IFS=',' read -r -a want <<< "$1"
fi
[ "${#want[@]}" -gt 0 ] || die "devices.json 里没有任何设备"

rc=0
for name in "${want[@]}"; do
	name="$(printf '%s' "$name" | tr -d '[:space:]')"
	[ -n "$name" ] || continue

	if [ -z "$(dev_get "$name" name)" ]; then
		printf '  ✗ %s：devices.json 里没有这个设备\n' "$name" >&2
		rc=1
		continue
	fi

	target="$(dev_get "$name" target)"
	profile="$(dev_get "$name" profile)"
	label="$(dev_get "$name" label)"
	[ -n "$label" ] || { printf '  ✗ %s：devices.json 缺 label（用于 job 名）\n' "$name" >&2; rc=1; }

	case "$target" in
		*/*) [ "${target//[^\/]/}" = "/" ] || {
			printf '  ✗ %s：target 必须是 "<subtarget>/<variant>"，现为 "%s"\n' "$name" "$target" >&2
			rc=1; continue; } ;;
		*) printf '  ✗ %s：target 必须是 "<subtarget>/<variant>"，现为 "%s"\n' "$name" "$target" >&2
			rc=1; continue ;;
	esac

	cfg="$CFG_DIR/$name.config"
	if [ ! -f "$cfg" ]; then
		printf '  ✗ %s：缺少 %s\n' "$name" "$cfg" >&2
		rc=1
		continue
	fi

	bad=0
	# target "a/b" -> CONFIG_TARGET_a=y + CONFIG_TARGET_a_b=y + ..._DEVICE_<profile>=y
	sub_t="${target%%/*}"
	var_t="${target##*/}"
	for s in "CONFIG_TARGET_${sub_t}=y" \
	         "CONFIG_TARGET_${sub_t}_${var_t}=y" \
	         "CONFIG_TARGET_${sub_t}_${var_t}_DEVICE_${profile}=y"; do
		grep -qxF "$s" "$cfg" || {
			printf '  ✗ %s：%s 里缺 %s（devices.json 声明 target=%s profile=%s）\n' \
				"$name" "$cfg" "$s" "$target" "$profile" >&2
			rc=1; bad=1
		}
	done

	# 同一设备配置里不该出现两个 *_DEVICE_* =y，否则 defconfig 只会留最后一个
	dups="$(grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_-]+=y' "$cfg" | sort -u)"
	if [ -n "$dups" ] && [ "$(printf '%s\n' "$dups" | grep -c .)" -gt 1 ]; then
		printf '  ✗ %s：%s 里有多个 *_DEVICE_* 选中：\n%s\n' "$name" "$cfg" "$dups" >&2
		rc=1; bad=1
	fi

	# 有错时上面已经逐条打印，这里不再补一个误导性的 ✓
	[ "$bad" -eq 0 ] && printf '  ✓ %-8s %-18s %s\n' "$name" "$target" "$profile"
done

# ---------- 反向：配置存在但没进矩阵（只警告，允许在制品）----------
while IFS= read -r f; do
	n="$(basename "$f" .config)"
	[ "$n" = "base" ] && continue
	[ -n "$(dev_get "$n" name)" ] ||
		warn "Config/$n.config 存在，但 devices.json 里没有对应条目（不会参与构建）"
done < <(find "$CFG_DIR" -maxdepth 1 -name '*.config' -type f | sort)

[ "$rc" -eq 0 ] || die "设备矩阵与配置不一致，见上（新增设备请按 README「新增设备 checklist」改这两处）"
step "设备矩阵校验通过"
