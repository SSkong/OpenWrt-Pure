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
#     包目录一重建就丢。
#
# 目前只改 Go 那一处，用 golang 原生支持的方式：写 .config 的
# CONFIG_GOLANG_BUILD_CACHE_DIR（Config.in 里有定义的 kconfig string），defconfig 会保留。
#
# Rust 这边**不能用 CARGO_TARGET_DIR**（曾经试过，已回退）：
#   设成外部目录后，产物不再落在包目录下的 target/，而不少 Rust 包的 Makefile 把
#   相对路径写死了 —— 例如 smartdns-ui 的 plugin/smartdns-ui/Makefile 里就是
#     cp target/$(CARGO_BUILD_TARGET)/release/libsmartdns_ui.so target/smartdns_ui.so
#   改了 CARGO_TARGET_DIR 之后 cargo 照样成功，但紧接着这行 cp 找不到文件，
#   在编译 4 个多小时后失败（run 41108533638，X86）。
#   真要缓存 Rust，应走 CONFIG_RUST_SCCACHE（RUSTC_WRAPPER=sccache，
#   不动 target 目录，对包 Makefile 完全透明），代价是 runner 上要先装 sccache。
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
mkdir -p "$go_cache" || { echo "ERROR: 无法创建缓存子目录" >&2; exit 1; }

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

# ---------- Rust：不改 CARGO_TARGET_DIR（原因见文件头）----------
# 这里只做一次确认性提示：rust-values.mk 在 feeds 里存在，说明有 Rust 包会被编译，
# 但它们必须用包目录内的默认 target/，缓存只能靠 sccache，本脚本不介入。
if [ -f "$ow/feeds/packages/lang/rust/rust-values.mk" ]; then
  sub "rust: 保持默认 CARGO_TARGET_DIR（改动会破坏写死 target/ 相对路径的包）"
fi

# ---------- 复用到已有缓存时打印体量，便于判断配额压力 ----------
for d in "$go_cache"; do
  n=$(find "$d" -mindepth 1 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && echo "   $(basename "$d"): 已恢复 $n 个条目，$(du -sh "$d" | cut -f1)"
done

echo "==> 缓存目录准备完成"
