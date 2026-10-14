// swift-tools-version:6.0
import PackageDescription

// Globtype 使用纯 SwiftPM 构建，不依赖 Xcode 和任何第三方库。
// - GlobtypeCore：与系统 UI 无关的核心逻辑，可用 `swift test` 测试
// - Globtype：菜单栏 App 可执行文件，由 Scripts/bundle.sh 打包成 .app
let package = Package(
    name: "Globtype",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Globtype", targets: ["Globtype"]),
        .library(name: "GlobtypeCore", targets: ["GlobtypeCore"]),
    ],
    targets: [
        .target(
            name: "GlobtypeCore",
            path: "Sources/GlobtypeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Globtype",
            dependencies: ["GlobtypeCore"],
            path: "Sources/Globtype",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "GlobtypeCoreTests",
            dependencies: ["GlobtypeCore"],
            path: "Tests/GlobtypeCoreTests"
        ),
    ],
    // 使用 Swift 5 语言模式：AX / CGEvent 等 C 回调接口在严格并发检查下噪音过大
    swiftLanguageModes: [.v5]
)
