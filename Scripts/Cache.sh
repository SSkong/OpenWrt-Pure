#!/usr/bin/env bash
# ==============================================================================
# 把 Go / Rust 的编译缓存挪出「每次都会被丢掉的位置」，交给 actions/cache 复用
#
# openwrt-25.12 / packages openwrt-25.12 里的真实定义（本脚本的依据）：
#
#   lang/golang/golang-values.mk
#     GO_BUILD_CACHE_DIR := $(or $(CONFIG_GOLANG_BUILD_CACHE_DIR), $(TMP_DIR)/go-build)
#     GO_MOD_CACHE_DIR   := $(DL_DIR)/go-mod-cache
#   lang/golang/golang-package.mk
#     GO_PKG_BUILD_VARS  = GOPATH=... GOCACHE="$(GO_BUILD_CACHE_DIR)" GOMODCACHE=...
#
#   lang/rust/rust-values.mk
#     CARGO_HOME := $(DL_DIR)/cargo
#     CARGO_PKG_CONFIG_VARS = ... （里面没有 CARGO_TARGET_DIR）
#
# 也就是说默认情况下：
#   - Go 构建缓存落在 openwrt/tmp/go-build：CI 每次都是全新 runner，tmp 恒为空，
#     二十来个 Go 包（mihomo / sing-box / xray / dae / daed / mosdns / openlist ...）
#     每一轮都要从零重新编译所有依赖；
#   - Rust 没有设 CARGO_TARGET_DIR，cargo 用缺省的 $(PKG_BUILD_DIR)/target，
#     包目录一重建就丢，smartdns-ui / easytier / bindgen-cli 的上百个 crate 每轮重编。
#
# 本脚本只改这两个位置，各自用「原生支持的方式」改，不动任何构建逻辑：
#   1. CONFIG_GOLANG_BUILD_CACHE_DIR —— golang 自带的 kconfig string（Config.in 里
#      有定义），写进 .config，defconfig 会保留。
#   2. CARGO_TARGET_DIR —— 追加到 CARGO_PKG_CONFIG_VARS（而不是设成全局变量），
#      这样只作用于「目标包」的 cargo 调用，不会污染 rust/host 的引导构建
#      （rust/host 用的是 CARGO_HOST_CONFIG_VARS，那边的目标目录必须留在 build_dir 内）。
#
# 注意：不缓存 dl/。源码 tarball 重新下载只需几分钟，缓存它反而挤占配额。
#       Go 模块缓存与 cargo registry 虽然也在 dl/ 下，但二者都是内容寻址的，
#       不缓存不会让本脚本的缓存失效（重新下载得到的字节完全一致，命中同样的哈希）。
#
# 用法：bash Scripts/Cache.sh <openwrt目录> [缓存根目录]
#   缓存根目录缺省为 <openwrt目录>/../.build-cache
#   必须在 make defconfig 之前跑（要往 .config 里写符号）
#
# 退出码：0 成功 / 2 参数或 .config 缺失
# ==============================================================================

set -euo pipefail

ow="${1:-}"
if [ -z "$ow" ]; then
  echo "用法: bash Scripts/Cache.sh <openwrt目录> [缓存根目录]" >&2
  exit 2
fi
ow="${ow%/}"
[ -d "$ow" ] || { echo "ERROR: openwrt 目录不存在: $ow" >&2; exit 2; }

cfg="$ow/.config"
[ -f "$cfg" ] || { echo "ERROR: 未找到 $cfg，请先合并 base.config + 设备 config" >&2; exit 2; }

root="${2:-}"
[ -n "$root" ] || root="$ow/../.build-cache"
mkdir -p "$root" || { echo "ERROR: 无法创建缓存根目录 $root" >&2; exit 1; }
root="$(cd "$root" && pwd)"

go_cache="$root/go-build"
rs_cache="$root/cargo-target"
mkdir -p "$go_cache" "$rs_cache" || { echo "ERROR: 无法创建缓存子目录" >&2; exit 1; }

echo "==> 编译缓存目录：$root"

# ---------- Go：CONFIG_GOLANG_BUILD_CACHE_DIR ----------
# 符号来自 lang/golang/golang/Config.in。Packages.sh 会把官方 golang 换成 sbwml 27.x，
# 那份 fork 里同样有这个符号；万一换源失败或目录缺失，defconfig 只会静默丢掉这一行，
# 不会报错，所以这里只提示、不失败。
if grep -rqE '^[[:space:]]*config[[:space:]]+GOLANG_BUILD_CACHE_DIR' "$ow/feeds/packages/lang/golang" 2>/dev/null; then
  sed -i '/^CONFIG_GOLANG_BUILD_CACHE_DIR=/d' "$cfg" || { echo "ERROR: 改写 .config 失败" >&2; exit 1; }
  printf 'CONFIG_GOLANG_BUILD_CACHE_DIR="%s"\n' "$go_cache" >> "$cfg" || { echo "ERROR: 写入 .config 失败" >&2; exit 1; }
  echo "   go:   GOCACHE -> $go_cache"
else
  echo "::warning::feeds 里没有 GOLANG_BUILD_CACHE_DIR，Go 构建缓存仍将落在 \$(TMP_DIR)/go-build"
fi

# ---------- Rust：CARGO_TARGET_DIR ----------
rv="$ow/feeds/packages/lang/rust/rust-values.mk"
if [ -f "$rv" ]; then
  if grep -q 'CARGO_TARGET_DIR' "$rv"; then
    echo "   rust: rust-values.mk 已含 CARGO_TARGET_DIR，跳过（幂等）"
  else
    # ?= 不用在这里：CARGO_PKG_CONFIG_VARS 是递归展开变量，用 += 追加即可，
    # 且递归变量在真正执行 recipe 时才展开，此时 RUSTC_TARGET_ARCH 等都已就绪。
    printf '\n# 由 Scripts/Cache.sh 注入：跨构建复用 Rust 编译产物（仅目标包，不影响 rust/host）\nCARGO_PKG_CONFIG_VARS+= CARGO_TARGET_DIR=%s\n' \
      "$rs_cache" >> "$rv" || { echo "ERROR: 写入 $rv 失败" >&2; exit 1; }
    echo "   rust: CARGO_TARGET_DIR -> $rs_cache"
  fi
else
  echo "::warning::未找到 $rv，Rust 编译缓存未启用"
fi

# ---------- 复用到已有缓存时打印体量，便于判断配额压力 ----------
for d in "$go_cache" "$rs_cache"; do
  n=$(find "$d" -mindepth 1 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && echo "   $(basename "$d"): 已恢复 $n 个条目，$(du -sh "$d" | cut -f1)"
done

echo "==> 缓存目录准备完成"
