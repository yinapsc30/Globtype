#!/bin/zsh
# 发布构建：打包 Globtype.app 并压缩为 zip，用于上传到 GitHub Releases。
#
# 用法：GLOBTYPE_VERSION=0.1.0 GLOBTYPE_BUILD=1 Scripts/release.sh
#
# 发布版本必须使用固定的自签名证书（见 Scripts/create_signing_cert.md），
# 这样用户升级后辅助功能与输入监控权限仍然有效（需求 8.7）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${GLOBTYPE_SIGN_IDENTITY:-Globtype Self-Signed}"
VERSION="${GLOBTYPE_VERSION:-0.1.0}"

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "✗ 未找到代码签名证书 \"$IDENTITY\"。发布版本不能使用临时签名，请先按 Scripts/create_signing_cert.md 创建或导入证书。"
  exit 1
fi
DICT="$ROOT/Sources/Globtype/Resources/dictionary.sqlite"
if [[ ! -f "$DICT" ]]; then
  echo "▸ 生成 dictionary.sqlite（首次需下载 ECDICT，约 65MB，已缓存则直接复用）"
  python3 "$ROOT/Scripts/build_dictionary.py"
fi
if [[ ! -f "$DICT" ]]; then
  echo "✗ 缺少 dictionary.sqlite，发布版本必须包含词典"
  exit 1
fi

source "$ROOT/Scripts/swift-env.sh"
cd "$ROOT"
"$SWIFT" test
# 发布版本为通用二进制，同时支持 Apple 芯片与 Intel Mac
GLOBTYPE_UNIVERSAL=1 GLOBTYPE_VERSION="$VERSION" "$ROOT/Scripts/bundle.sh" release

ZIP="$ROOT/build/Globtype-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/build/Globtype.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHA  $(basename "$ZIP")"
echo "✓ 发布包：$ZIP"

# 发布到 GitHub Releases 需要显式开启，避免误发布：
#   GLOBTYPE_VERSION=0.1.1 GLOBTYPE_PUBLISH=1 Scripts/release.sh
# 认证二选一：已登录的 gh（brew install gh && gh auth login），或环境变量 GITHUB_TOKEN（需要 repo 权限）
if [[ "${GLOBTYPE_PUBLISH:-0}" != "1" ]]; then
  echo "提示：加 GLOBTYPE_PUBLISH=1 可自动创建 GitHub Release 并上传该 zip"
  exit 0
fi

TAG="v$VERSION"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "✗ 工作区有未提交的改动。标签会指向当前提交，请先提交。"
  exit 1
fi
if git -C "$ROOT" ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "✗ 远程已存在标签 $TAG，请提升 GLOBTYPE_VERSION"
  exit 1
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
NOTES="安装方式见 [docs/distribution.md](https://github.com/$REPO/blob/main/docs/distribution.md)。

首次打开会被系统拦截（本项目未使用付费 Apple 开发者账号签名），请到 系统设置 → 隐私与安全性 底部点「仍要打开」。

\`Globtype-$VERSION.zip\` SHA-256：
\`\`\`
$SHA
\`\`\`"

echo "▸ 发布 $TAG → $COMMIT"
if command -v gh >/dev/null 2>&1; then
  gh release create "$TAG" "$ZIP" --target "$COMMIT" --title "Globtype $VERSION" --notes "$NOTES"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"target_commitish":sys.argv[2],"name":sys.argv[3],"body":sys.argv[4]}))' \
    "$TAG" "$COMMIT" "Globtype $VERSION" "$NOTES")"
  RELEASE_ID="$(curl -fsS -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases" -d "$PAYLOAD" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  curl -fsS -o /dev/null -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Content-Type: application/zip" \
    --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$ZIP")"
  echo "✓ 已发布：https://github.com/$REPO/releases/tag/$TAG"
else
  echo "✗ 自动发布需要认证，二选一："
  echo "  1) brew install gh && gh auth login"
  echo "  2) export GITHUB_TOKEN=<有 repo 权限的 token>（https://github.com/settings/tokens）"
  exit 1
fi
