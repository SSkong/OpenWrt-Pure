#!/usr/bin/env bash
# ==============================================================================
# 编译 OpenWrt，并在失败时把「被 make 吞掉的现场」还原出来
#
# 并行 make 的出错现场经常只剩一行 `ERROR: target/linux failed to build.`，
# 失败子目录内部到底报了什么完全看不到。这里做三件事：
#   1. 编译全程每 5 分钟记一次磁盘/内存曲线（usage.log），ENOSPC / OOM 才有据可查
#   2. 失败时从日志里取「哪个子目录失败的」，只对该子目录单线程重跑（stamp 都在，
#      能直接走到出错点）；找不到就退回整体重跑
#   3. 重跑的完整输出写 retry.log，CI 里截尾部作为诊断包
#
# 重跑先 compile 后 install，两段都要看：编译错误在 compile 段，打包/安装错误在
# install 段。嵌套包目录（package/custom/<仓库>/<包>）在顶层 make 里不一定有
# install 目标，报 "No rule to make target" 时退回该目录内直接 make —— make[3]
# 本来就是这么调的，compile 规则必定存在。
#
# 用法：scripts/build.sh <openwrt目录> [日志目录（默认仓库根）]
# 退出码：0 成功 / 1 失败（日志已落在日志目录）
# ==============================================================================

set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WIN="${1:?用法: build.sh <openwrt目录> [日志目录]}"
LOG="${2:-$ROOT}"
require_dir "$WIN"
ensure_dir "$LOG"

BUILD_LOG="$LOG/build.log"
USAGE_LOG="$LOG/usage.log"
RETRY_LOG="$LOG/retry.log"
# 只保留最近一次重跑的输出，用来判断「顶层没有这个目标」这类一次性结论
STEP_LOG="$LOG/retry-step.log"
enter "$WIN"

# 资源心跳：单独写一个文件，不跟 make 抢 build.log。
# x86 的镜像阶段（vmlinux.debug + rootfs.tar.gz + root.squashfs 同时存在）是整轮
# 构建的磁盘峰值，93G 卷和 15G 内存都在这个点最紧张。
HB_PID=""
heartbeat_start() {
	(
		while :; do
			printf '%s  ' "$(date -u +%H:%M:%S)"
			df -h . | awk 'NR==2{printf "disk used %s / %s (avail %s)  ", $3, $2, $4}'
			free -m 2>/dev/null | awk 'NR==2{printf "mem %sMB / %sMB used", $3, $2}'
			printf '\n'
			sleep 300
		done
	) > "$USAGE_LOG" 2>&1 &
	HB_PID=$!
}

heartbeat_stop() { [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null; return 0; }

resources() {
	echo "----- 资源状况 -----"
	df -h || true
	free -h 2>/dev/null || true
	du -sh build_dir staging_dir dl bin 2>/dev/null || true
	echo "----- 资源曲线（末尾 10 条）-----"
	tail -10 "$USAGE_LOG" 2>/dev/null || true
}

heartbeat_start

# pipefail 已在文件头打开：不加它，tee 会把 make 的失败吞掉
if make -j$(( $(nproc) + 1 )) 2>&1 | tee "$BUILD_LOG"; then
	heartbeat_stop
	step "编译完成"
	exit 0
fi
heartbeat_stop

warn "并行编译失败，单线程重跑失败子目录以拿到完整报错"
resources

# 注意末尾的 || true：找不到匹配时 grep 退出 1，在 set -e 语义下会直接把这一步
# 结束掉，后面「有没有子目录」的分支就跑不到了。
sub_dir="$(grep -oE 'ERROR: [^ ]+ failed to build' "$BUILD_LOG" | tail -1 | awk '{print $2}' || true)"
: > "$RETRY_LOG"

# 一次重跑：输出同进 retry.log（累积）与 retry-step.log（只本次），回显尾部 200 行
retry_once() {
	: > "$STEP_LOG"
	timeout 3600 "$@" 2>&1 | tee -a "$RETRY_LOG" "$STEP_LOG" | tail -200
	return "${PIPESTATUS[0]}"
}

# 顶层目标对包目录是 <dir>/compile、<dir>/install；嵌套包目录在顶层可能没有
# install 规则，那就进目录自己 make
retry_target() {
	local t="$1"
	retry_once make -j1 V=s "$sub_dir/$t" && return 0
	if grep -q "No rule to make target" "$STEP_LOG"; then
		echo "顶层没有 $sub_dir/$t，改为在该目录内 make" | tee -a "$RETRY_LOG"
		retry_once make -C "$sub_dir" -r -j1 V=s "$t" && return 0
	fi
	return 1
}

if [ -n "$sub_dir" ]; then
	echo "失败子目录: $sub_dir"
	for t in compile install; do
		step "重跑 $sub_dir/$t"
		retry_target "$t" || break
	done
else
	echo "日志里没找到 'ERROR: <子目录> failed to build'，退回整体单线程重跑"
	retry_once make -j1 V=s
fi

echo "----- 重跑后的资源状况 -----"
df -h || true
du -sh build_dir 2>/dev/null || true
exit 1
