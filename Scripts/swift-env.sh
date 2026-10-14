# 选择 Swift 工具链（由其他脚本 source）。
# 优先级：$GLOBTYPE_SWIFT → ~/Library/Developer/Toolchains/swift-latest.xctoolchain → PATH 中的 swift
# 需要 Swift 6.0 及以上，且 PackageDescription 支持 macOS 15 平台声明。
if [[ -n "${GLOBTYPE_SWIFT:-}" ]]; then
  SWIFT="$GLOBTYPE_SWIFT"
elif [[ -x "$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" ]]; then
  SWIFT="$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift"
  export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
else
  SWIFT="$(command -v swift)"
fi
