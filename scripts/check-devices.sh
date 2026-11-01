#!/usr/bin/env bash
# ==============================================================================
# 设备矩阵 ↔ config/<设备>.config 交叉校验（离线，几十毫秒）
#
# 背景：设备矩阵（config/devices.json）和设备配置（config/<name>.config）是两份
# 事实，原先任何一方漏改都要等到构建最后一步「未找到任何固件产物」才暴露——那时
# 已经烧掉两小时。这里在构建开始前就把三类错位挡掉：
#   1. devices.json 里有设备，但 config/<name>.config 不存在
#   2. target / profile 与 config/<name>.config 里的 CONFIG_TARGET_* 不一致
#      （target "a/b" 对应 CONFIG_TARGET_a=y + CONFIG_TARGET_a_b=y，
#       profile 对应 CONFIG_TARGET_a_b_DEVICE_<profile>=y）
#   3. config/*.config 存在但 devices.json 里没有（反向，只警告：允许在制品）
#
# 用法：scripts/check-devices.sh [设备名,设备名...]   # 缺省=校验全部
# 退出码：0 通过 / 1 有阻断性错误 / 2 用法或依赖缺失
# ==============================================================================

set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# ---------- 待校验设备 ----------
want=()
if [ "${1:-}" = "" ]; then
	mapfile -t want < <(json_devices)
else
	IFS=',' read -r -a want <<< "$1"
fi
[ "${#want[@]}" -gt 0 ] || die "config/devices.json 里没有任何设备"

rc=0
for name in "${want[@]}"; do
	name="$(printf '%s' "$name" | tr -d '[:space:]')"
	[ -n "$name" ] || continue

	if [ -z "$(json_dev_field "$name" name)" ]; then
		printf '  ✗ %s：devices.json 里没有这个设备\n' "$name" >&2
		rc=1
		continue
	fi

	target="$(json_dev_field "$name" target)"
	profile="$(json_dev_field "$name" profile)"
	label="$(json_dev_field "$name" label)"
	[ -n "$label" ] || { printf '  ✗ %s：devices.json 缺 label（用于 job 名）\n' "$name" >&2; rc=1; }

	case "$target" in
		*/*) [ "${target//[^\/]/}" = "/" ] || {
			printf '  ✗ %s：target 必须是 "<subtarget>/<variant>"，现为 "%s"\n' "$name" "$target" >&2
			rc=1; continue; } ;;
		*) printf '  ✗ %s：target 必须是 "<subtarget>/<variant>"，现为 "%s"\n' "$name" "$target" >&2
			rc=1; continue ;;
	esac

	cfg="$CONFIG_DIR/$name.config"
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
	[ -n "$(json_dev_field "$n" name)" ] ||
		warn "config/$n.config 存在，但 devices.json 里没有对应条目（不会参与构建）"
done < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.config' -type f | sort)

[ "$rc" -eq 0 ] || die "设备矩阵与配置不一致，见上（新增设备按 README「新增设备」一节改这两处）"
step "设备矩阵校验通过"
