#!/usr/bin/env bash
# ==============================================================================
# 一键静态自检 —— 本地与 CI 共用同一入口
#
# 这里跑的都是「几十秒能出结果」的检查。它们挡掉的那些错误，如果漏到构建阶段，
# 要烧掉几个小时才会以「未找到任何固件产物」「包未生效」这种远距离症状出现。
#
# 用法：scripts/doctor.sh
# 退出码：0 全过 / 1 有阻断性问题
# ==============================================================================

set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# ---------- 1. Shell 语法 ----------
step "1/5 Shell 语法"
n=0
for f in "$ROOT/scripts"/*.sh; do
	bash -n "$f" || die "语法错误: $f"
	n=$((n + 1))
done
sub "$n 个脚本语法通过"

# ---------- 2. 设备矩阵 ----------
step "2/5 config/devices.json"
json_init   # 内部完成合法性校验，非法直接 die
sub "设备: $(json_devices | tr '\n' ' ')"

# ---------- 3. 设备矩阵 ↔ 设备配置 ----------
step "3/5 设备矩阵 ↔ 设备配置"
bash "$ROOT/scripts/check-devices.sh" || exit 1

# ---------- 4. 配置 lint ----------
step "4/5 配置 lint"
bash "$ROOT/scripts/lint-config.sh" || exit 1

# ---------- 5. 补丁行尾 ----------
# CRLF 的补丁打进 LF 的内核源码时报 "context does not match"，现象离原因很远。
# .gitattributes 已强制 LF，这里是防止有人绕过它直接传文件。
# 用 tr 逐字节数 CR：grep/awk 在部分环境（MSYS 文本模式）会把 CR 吃掉。
step "5/5 补丁行尾必须是 LF"
check_no_crlf "$PATCHES_DIR"
sub "$(find "$PATCHES_DIR" -type f | wc -l | tr -d ' ') 个补丁文件均为 LF"

# ---------- 摘要 ----------
sources="$(grep -cE '^[[:space:]]*clone_pkg[[:space:]]' "$ROOT/scripts/fetch-packages.sh" | tr -d ' ')"
pkgs="$(grep -cE '^CONFIG_PACKAGE_' "$CONFIG_DIR/base.config" | tr -d ' ')"
step "自检通过（上游源 ${sources} 个 / base.config 选中包 ${pkgs} 个）"
