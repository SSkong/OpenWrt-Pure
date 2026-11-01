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

# ---------- 1/6 Shell 语法 ----------
step "1/6 Shell 语法"
n=0
for f in "$ROOT/scripts"/*.sh; do
	bash -n "$f" || die "语法错误: $f"
	n=$((n + 1))
done
sub "$n 个脚本语法通过"

# ---------- 2/6 设备矩阵 ----------
step "2/6 config/devices.json"
json_init   # 内部完成合法性校验，非法直接 die
sub "设备: $(json_devices | tr '\n' ' ')"

# ---------- 3/6 设备矩阵 ↔ 设备配置 ----------
step "3/6 设备矩阵 ↔ 设备配置"
bash "$ROOT/scripts/check-devices.sh" || exit 1

# ---------- 4/6 配置 lint ----------
step "4/6 配置 lint"
bash "$ROOT/scripts/lint-config.sh" || exit 1

# ---------- 5/6 补丁行尾 ----------
# CRLF 的补丁打进 LF 的内核源码时报 "context does not match"，现象离原因很远。
# .gitattributes 已强制 LF，这里是防止有人绕过它直接传文件。
# 用 tr 逐字节数 CR：grep/awk 在部分环境（MSYS 文本模式）会把 CR 吃掉。
step "5/6 补丁行尾必须是 LF"
check_no_crlf "$PATCHES_DIR"
sub "$(find "$PATCHES_DIR" -type f | wc -l | tr -d ' ') 个补丁文件均为 LF"

# ---------- 6/6 ccache ----------
# 两个静默失败点，都只在几小时后才暴露：
#   1. ccache 挂在开发者菜单下（prompt if DEVEL），没有 CONFIG_DEVEL=y 时
#      CONFIG_CCACHE=y 会被 defconfig 直接丢弃，缓存永远为空。
#   2. 配置开了但 runner 没装 ccache 二进制，第一次调用编译器才报 not found。
# 排除整行注释再找，否则 build.yml 里的说明文字会把第 2 项蒙混过关。
step "6/6 ccache"
WF="$ROOT/.github/workflows/build.yml"
if grep -qE '^CONFIG_CCACHE=y' "$CONFIG_DIR/base.config"; then
	grep -qE '^CONFIG_DEVEL=y' "$CONFIG_DIR/base.config" \
		|| die "CONFIG_CCACHE=y 需要 CONFIG_DEVEL=y，否则被 defconfig 丢弃"

	# 只在 apt 安装块里找：整个文件搜会被 run 块里的提示文案（"已清理 … 的旧
	# ccache 条目"）蒙过去，这种"关键词恰好出现在别处"的假阴性比不检查更糟。
	# apt 命令是续行写法，从 install 那行起，读到不以 \ 结尾的行为止。
	apt_block="$(awk '/apt-get .*install/{f=1} f{print} f&&!/\\[[:space:]]*$/{exit}' "$WF")"
	grep -qE 'ccache' <<<"$apt_block" \
		|| die "base.config 开了 ccache，但 build.yml 的 apt 安装块里没有 ccache"

	# 上限不在这里写死，从 workflow 读，避免两处漂移
	cap="$(grep -oE 'CCACHE_MAXSIZE:[[:space:]]*[0-9]+[GM]' "$WF" | head -n1 | sed 's/.*[[:space:]]//')"
	sub "已启用（openwrt/.ccache，上限 ${cap:-未设置}）"
else
	sub "未启用"
fi

# ---------- 摘要 ----------
sources="$(grep -cE '^[[:space:]]*clone_pkg[[:space:]]' "$ROOT/scripts/fetch-packages.sh" | tr -d ' ')"
pkgs="$(grep -cE '^CONFIG_PACKAGE_' "$CONFIG_DIR/base.config" | tr -d ' ')"
step "自检通过（上游源 ${sources} 个 / base.config 选中包 ${pkgs} 个）"
