#!/bin/zsh
# 构建 Globtype.app（不需要 Xcode，只需要 Command Line Tools）。
#
# 用法：
#   Scripts/bundle.sh            # release 构建，输出 build/Globtype.app
#   Scripts/bundle.sh debug      # debug 构建
#
# 签名：如果钥匙串中存在名为 "Globtype Self-Signed" 的代码签名证书则使用它，
# 否则退回临时签名（ad-hoc）。临时签名每次构建都会变化，更新后需要重新授予权限，
# 详见 Scripts/create_signing_cert.md。
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Globtype.app"
IDENTITY="${GLOBTYPE_SIGN_IDENTITY:-Globtype Self-Signed}"
VERSION="${GLOBTYPE_VERSION:-0.1.0}"
BUILD_NUMBER="${GLOBTYPE_BUILD:-1}"

source "$ROOT/Scripts/swift-env.sh"

DICT="$ROOT/Sources/Globtype/Resources/dictionary.sqlite"
# 词典不入库（约 5MB，由 ECDICT 生成），首次打包时自动生成。
# 跳过：GLOBTYPE_SKIP_DICT=1（缺词典时单词卡没有音标，基础词过滤不可用，但 App 能正常运行）
if [[ ! -f "$DICT" && "${GLOBTYPE_SKIP_DICT:-0}" != "1" ]]; then
  echo "▸ 生成 dictionary.sqlite（首次需下载 ECDICT，约 65MB，已缓存则直接复用）"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠︎ 未找到 python3，跳过词典生成"
  elif ! python3 "$ROOT/Scripts/build_dictionary.py"; then
    echo "⚠︎ 词典生成失败（通常是网络问题），本次打包将不包含词典"
  fi
fi

cd "$ROOT"
if [[ "${GLOBTYPE_UNIVERSAL:-0}" == "1" ]]; then
  # 通用二进制：分别编译 Apple 芯片与 Intel 版本，再用 lipo 合并
  BIN="$ROOT/build/Globtype-universal"
  mkdir -p "$ROOT/build"
  SLICES=()
  for ARCH in arm64 x86_64; do
    echo "▸ $SWIFT build -c $CONFIG（$ARCH）"
    "$SWIFT" build -c "$CONFIG" --product Globtype --triple "$ARCH-apple-macosx15.0"
    SLICES+=("$("$SWIFT" build -c "$CONFIG" --triple "$ARCH-apple-macosx15.0" --show-bin-path)/Globtype")
  done
  lipo -create "${SLICES[@]}" -output "$BIN"
  echo "  架构：$(lipo -archs "$BIN")"
else
  echo "▸ $SWIFT build -c $CONFIG"
  "$SWIFT" build -c "$CONFIG" --product Globtype
  BIN="$("$SWIFT" build -c "$CONFIG" --show-bin-path)/Globtype"
fi

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Globtype"
cp "$ROOT/Sources/Globtype/Resources/providers.json" "$APP/Contents/Resources/"
cp "$ROOT/Sources/Globtype/Resources/AppIcon.icns" "$APP/Contents/Resources/"
if [[ -f "$DICT" ]]; then
  cp "$DICT" "$APP/Contents/Resources/"
else
  echo "⚠︎ 未找到 dictionary.sqlite，单词卡将没有音标，基础词过滤不可用。运行 Scripts/build_dictionary.py 生成。"
fi
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$ROOT/Sources/Globtype/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ 签名"
# 自签名证书不受系统信任，find-identity -v 会把它隐藏，因此用 find-certificate 查找；codesign 可以正常使用它
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
  echo "  使用证书：$IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "⚠︎ 未找到证书 \"$IDENTITY\"，已使用临时签名。更新后需要重新授予辅助功能与输入监控权限。"
fi
codesign --verify --deep --strict "$APP"
echo "✓ 完成：$APP"
