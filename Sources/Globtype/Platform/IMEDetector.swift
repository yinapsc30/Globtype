import AppKit
import Carbon

/// 输入法组词状态的启发式检测（需求 1.3）。
///
/// macOS 没有跨 App 的公开接口能查询 marked text，这里同时满足两个条件才认为正在组词：
/// 1. 当前是中日韩输入法，且自上次"上屏类按键"（空格、回车、数字、标点、Esc）以来输入过字母
/// 2. 该输入法进程当前有可见窗口（候选窗）
/// 只用条件 2 会被常驻的输入法状态栏误判；只用条件 1 会在输入法英文模式下误判。
@MainActor
final class IMEDetector {
    private var lettersSinceCommit = 0

    /// 由事件监听在每次 keyDown 时调用。
    func noteKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            lettersSinceCommit = 0
            return
        }
        if Self.letterKeyCodes.contains(keyCode) {
            lettersSinceCommit += 1
        } else if keyCode == 51 { // Delete
            lettersSinceCommit = max(0, lettersSinceCommit - 1)
        } else {
            lettersSinceCommit = 0
        }
    }

    func noteMouseDown() {
        lettersSinceCommit = 0
    }

    func isComposing() -> Bool {
        guard lettersSinceCommit > 0, let ime = Self.currentCJKInputMethodBundleID() else { return false }
        return Self.hasVisibleWindow(bundlePrefix: ime)
    }

    /// 当前输入源若是中日韩输入法，返回其 bundle ID。
    static func currentCJKInputMethodBundleID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return nil }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        guard type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
                || type == (kTISTypeKeyboardInputMethodWithoutModes as String) else { return nil }
        if let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String] ?? []
            guard langs.contains(where: { $0.hasPrefix("zh") || $0.hasPrefix("ja") || $0.hasPrefix("ko") }) else { return nil }
        }
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }

    static func hasVisibleWindow(bundlePrefix: String) -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").hasPrefix(bundlePrefix) }
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Width"] ?? 0) > 20 && (bounds["Height"] ?? 0) > 10
        }
    }

    // a–z 的虚拟键码
    static let letterKeyCodes: Set<CGKeyCode> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46]
}
