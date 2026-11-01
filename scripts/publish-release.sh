#!/usr/bin/env bash
# ==============================================================================
# 把产物发布到 GitHub Release
#
# 同一版本号会被重复构建，所以这里按「覆盖发布」处理：
#   - Release 不存在 → 创建
#   - 已存在         → 更新标题，删掉这次没有产出的旧资产，再覆盖同名资产
# 不删除多余资产的话，改了配置之后再发版，Release 上会同时挂着新旧两批固件，
# 下载的人拿到哪一批全看运气。
#
# 用法：publish-release.sh <tag> <版本号> <产物目录>
# 依赖：gh CLI 已登录（GH_TOKEN）
# ==============================================================================

set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TAG="${1:?用法: publish-release.sh <tag> <版本号> <产物目录>}"
VER="${2:?用法: publish-release.sh <tag> <版本号> <产物目录>}"
DIST="${3:?用法: publish-release.sh <tag> <版本号> <产物目录>}"

require_dir "$DIST"
count=$(find "$DIST" -maxdepth 1 -type f | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || die "$DIST 里没有文件，拒绝发布空 Release"

# 产物来源的 commit 由调用方给 SOURCE_COMMIT。
# 不能用 GITHUB_SHA：它是 Actions 的保留变量，在 env: 里覆盖会被忽略，
# 结果写进去的是「跑发布这一步的那次 run 的 commit」，而不是产物对应的 commit。
notes="OpenWrt ${VER}，构建自 ${SOURCE_COMMIT:-未知}。
校验和见 sha256sums-<设备>.txt，包清单见 *.manifest。"

if gh release view "$TAG" >/dev/null 2>&1; then
	step "更新已有 Release $TAG"

	# 这次不产出的旧资产要清掉。用 -x 精确整行匹配：子串匹配会把
	# xxx.img.gz 和 xxx.img.gz.sha256 当成同一个。
	keep="$(find "$DIST" -maxdepth 1 -type f -printf '%f\n')"
	removed=0
	while read -r name; do
		[ -n "$name" ] || continue
		if ! grep -qxF "$name" <<<"$keep"; then
			echo "  删除过期资产: $name"
			gh release delete-asset "$TAG" "$name" --yes >/dev/null
			removed=$((removed + 1))
		fi
	done < <(gh release view "$TAG" --json assets --jq '.assets[].name')
	sub "清理 $removed 个过期资产"

	# 说明里带着构建来源 commit，是标签不再移动之后唯一的溯源线索，每次都要刷新
	gh release edit "$TAG" --title "OpenWrt $VER" --notes "$notes"
else
	step "创建 Release $TAG"
	# 标签由调用方提前推到本次构建的 commit，这里用 --verify-tag 明确要求它存在，
	# 避免 gh 自己从默认分支新建一个指向错误 commit 的标签
	gh release create "$TAG" --verify-tag --title "OpenWrt $VER" --notes "$notes"
fi

step "上传 $count 个文件"
# --clobber：同名资产直接覆盖，等价于 release-action 的 replacesArtifacts
gh release upload "$TAG" "$DIST"/* --clobber

step "发布完成"
# 只是展示结果，这一步失败不该把一次成功的发布判成失败
gh release view "$TAG" --json url,assets \
	--jq '"\(.url)  资产 \(.assets | length) 个"' || true
