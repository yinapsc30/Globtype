import AppKit
import ApplicationServices
import Combine

/// 辅助功能与输入监控权限（需求 8.1~8.3）。
@MainActor
final class PermissionService: ObservableObject {
    static let shared = PermissionService()

    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false

    var allGranted: Bool { accessibility && inputMonitoring }

    private var timer: Timer?

    private init() {
        refresh()
        // 每秒轮询一次，授予后界面自动更新（需求 8.2）
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let im = CGPreflightListenEventAccess()
        if ax != accessibility { accessibility = ax }
        if im != inputMonitoring { inputMonitoring = im }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(anchor: "Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        if !CGRequestListenEventAccess() {
            openSettings(anchor: "Privacy_ListenEvent")
        }
    }

    func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
