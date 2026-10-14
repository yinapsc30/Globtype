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
if [[ ! -f "$ROOT/Sources/Globtype/Resources/dictionary.sqlite" ]]; then
  echo "✗ 缺少 dictionary.sqlite，请先运行 python3 Scripts/build_dictionary.py"
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
shasum -a 256 "$ZIP"
echo "✓ 发布包：$ZIP"
