import AppKit
import Combine
import GlobtypeCore

/// 自定义快捷键（需求 1.5）。
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    /// 仅包含 command / option / control / shift 四种修饰键的 CGEventFlags 原始值
    var modifiers: UInt64
    var display: String

    static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.relevantFlags).rawValue == modifiers
    }
}

/// 所有用户设置，基于 UserDefaults 持久化。API Key 不在这里，见 KeychainStore。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "isEnabled") } }
    @Published var useDoubleShift: Bool { didSet { defaults.set(useDoubleShift, forKey: "useDoubleShift") } }
    @Published var customHotkey: Hotkey? { didSet { save(customHotkey, key: "customHotkey") } }
    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published var noRecordBundleIDs: [String] { didSet { defaults.set(noRecordBundleIDs, forKey: "noRecordBundleIDs") } }
    @Published var dailyNewLimit: Int { didSet { defaults.set(dailyNewLimit, forKey: "dailyNewLimit") } }
    /// nil 表示使用 Apple 翻译
    @Published var provider: ProviderConfig? { didSet { save(provider, key: "provider") } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    /// 诊断模式只在本次运行有效，不持久化
    @Published var diagnosticsMode = false

    static let defaultExcluded = ["com.jetbrains.*", "com.google.android.studio"]

    private init() {
        defaults.register(defaults: [
            "isEnabled": true,
            "useDoubleShift": true,
            "dailyNewLimit": 10,
            "excludedBundleIDs": Self.defaultExcluded,
            "noRecordBundleIDs": [String](),
            "onboardingCompleted": false,
        ])
        isEnabled = defaults.bool(forKey: "isEnabled")
        useDoubleShift = defaults.bool(forKey: "useDoubleShift")
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? Self.defaultExcluded
        noRecordBundleIDs = defaults.stringArray(forKey: "noRecordBundleIDs") ?? []
        dailyNewLimit = max(0, defaults.integer(forKey: "dailyNewLimit"))
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        customHotkey = Self.load(Hotkey.self, key: "customHotkey", from: defaults)
        provider = Self.load(ProviderConfig.self, key: "provider", from: defaults)
    }

    private func save<T: Encodable>(_ value: T?, key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 支持以 `.*` 结尾的前缀通配。
    static func matches(_ bundleID: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            if pattern.hasSuffix(".*") {
                return bundleID.hasPrefix(String(pattern.dropLast(1)))
            }
            return pattern == bundleID
        }
    }

    func isExcluded(_ bundleID: String) -> Bool {
        Self.matches(bundleID, patterns: excludedBundleIDs)
    }
}
