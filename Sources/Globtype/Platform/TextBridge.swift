import AppKit
import ApplicationServices
import GlobtypeCore
import os

enum SourceScope: String { case selection, fullText }
enum ReadMethod: String { case accessibility, clipboard }
enum ReplaceMethod: String { case accessibility, paste, clipboardPaste }

enum ReplaceResult: Equatable {
    case verified(ReplaceMethod)
    case unverified(ReplaceMethod)
    case fallbackCopied
}

enum TextBridgeError: Error {
    case secureField
    case noFrontApp
    case readFailed
}

/// 一次唤起时从目标输入框读取到的全部信息（设计：TextBridge）。
struct SourceSnapshot {
    let appBundleID: String
    let appName: String
    let pid: pid_t
    let element: AXUIElement?
    let fullText: String?
    let selectedRange: NSRange?
    let sourceText: String
    let scope: SourceScope
    let method: ReadMethod
    /// Cocoa 屏幕坐标
    let caretRect: CGRect?
    let elementRect: CGRect?
    /// 是否为本次读取临时启用了 Electron / Chromium 辅助功能
    var enabledManualAccessibility = false
}

/// 读取与回填其他 App 输入框中的文本（需求 3、6）。
@MainActor
final class TextBridge {
    private let log = Logger(subsystem: "app.globtype", category: "textbridge")
    private let axQueue = DispatchQueue(label: "app.globtype.ax", qos: .userInitiated)
    private var enabledPIDs = Set<pid_t>()

    /// 强制使用剪贴板方式的 App（根据 M0 兼容性测试结果维护）
    static let clipboardOnlyBundleIDs: Set<String> = []

    // MARK: - 读取

    func readSource() async throws -> SourceSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw TextBridgeError.noFrontApp }
        let bundleID = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? bundleID
        let pid = app.processIdentifier

        AXReader.primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        if !Self.clipboardOnlyBundleIDs.contains(bundleID) {
            var result = await runAX { AXReader.read(pid: pid) }
            var enabled = false
            if case .unavailable = result, Self.needsManualAccessibility(app), !enabledPIDs.contains(pid) {
                // Electron / Chromium 默认不暴露辅助功能树，启用后重试一次（需求 3.4）
                await runAX { AXReader.enableManualAccessibility(pid: pid, chromium: Self.isChromium(bundleID)) }
                enabledPIDs.insert(pid)
                enabled = true
                try? await Task.sleep(nanoseconds: 100_000_000)
                result = await runAX { AXReader.read(pid: pid) }
            }
            switch result {
            case .secure:
                throw TextBridgeError.secureField
            case .ok(let r):
                log.info("AX 读取成功，范围=\(r.scope.rawValue)")
                var snapshot = SourceSnapshot(appBundleID: bundleID, appName: name, pid: pid, element: r.element,
                                              fullText: r.fullText, selectedRange: r.selectedRange, sourceText: r.sourceText,
                                              scope: r.scope, method: .accessibility, caretRect: r.caretRect,
                                              elementRect: r.elementRect)
                snapshot.enabledManualAccessibility = enabled
                return snapshot
            case .unavailable:
                break
            }
        }
        log.info("AX 读取失败，改用剪贴板方式")
        return try await readViaClipboard(bundleID: bundleID, name: name, pid: pid)
    }

    private func readViaClipboard(bundleID: String, name: String, pid: pid_t) async throws -> SourceSnapshot {
        let backup = ClipboardService.backup()
        var scope = SourceScope.selection
        let before = ClipboardService.pasteboard.changeCount
        KeySynth.commandKey(.c)
        var changed = await ClipboardService.waitForChange(from: before)
        if !changed {
            // 没有选区时 ⌘C 不会改变剪贴板：全选后再复制
            scope = .fullText
            KeySynth.commandKey(.a)
            try? await Task.sleep(nanoseconds: 60_000_000)
            let beforeAll = ClipboardService.pasteboard.changeCount
            KeySynth.commandKey(.c)
            changed = await ClipboardService.waitForChange(from: beforeAll)
        }
        let text = changed ? (ClipboardService.pasteboard.string(forType: .string) ?? "") : ""
        if changed {
            ClipboardService.restore(backup, ifUnchangedSince: ClipboardService.pasteboard.changeCount)
        }
        // 复制后剪贴板仍没有变化：输入框为空，或 App 不支持复制，都按空文本处理
        return SourceSnapshot(appBundleID: bundleID, appName: name, pid: pid, element: nil, fullText: nil,
                              selectedRange: nil, sourceText: text, scope: scope, method: .clipboard,
                              caretRect: nil, elementRect: nil)
    }

    // MARK: - 变化检测（需求 6.7）

    func hasChanged(since snapshot: SourceSnapshot) async -> Bool {
        guard snapshot.method == .accessibility, let element = snapshot.element, let original = snapshot.fullText else { return false }
        let current = await runAX { AXReader.string(element, kAXValueAttribute) }
        return current != nil && current != original
    }

    // MARK: - 回填（需求 6.1~6.6）

    func replace(_ snapshot: SourceSnapshot, with text: String) async -> ReplaceResult {
        if snapshot.method == .accessibility, let element = snapshot.element {
            let before = await runAX { AXReader.string(element, kAXValueAttribute) }
            let range: NSRange? = {
                if snapshot.scope == .fullText { return UTF16Range.fullRange(of: before ?? snapshot.fullText ?? "") }
                return snapshot.selectedRange
            }()
            let written = await runAX { () -> Bool in
                if let range { AXReader.setSelectedRange(element, range) }
                return AXReader.setSelectedText(element, text)
            }
            if written {
                try? await Task.sleep(nanoseconds: 120_000_000)
                let after = await runAX { AXReader.string(element, kAXValueAttribute) }
                if Self.contains(after, text) { return .verified(.accessibility) }
                // 值已变化但校验不通过（如 App 自动改写了格式）：不重复粘贴，避免插入两次
                if after != before { return .unverified(.accessibility) }
                log.info("AX 写入未生效，改用粘贴")
            }
            // AX 写入失败：选区已设置好，直接粘贴
            if let range { _ = await runAX { AXReader.setSelectedRange(element, range) } }
            await paste(text)
            try? await Task.sleep(nanoseconds: 150_000_000)
            let after = await runAX { AXReader.string(element, kAXValueAttribute) }
            if Self.contains(after, text) { return .verified(.paste) }
            if after != nil && after != before { return .unverified(.paste) }
            ClipboardService.writePersistent(text)
            return .fallbackCopied
        }
        // 剪贴板读取方式：读取时的选区（或 ⌘A 全选）仍然有效，直接粘贴
        await paste(text)
        return .unverified(.clipboardPaste)
    }

    private func paste(_ text: String) async {
        let backup = ClipboardService.backup()
        let count = ClipboardService.writeTransient(text)
        KeySynth.commandKey(.v)
        // 等目标 App 读取剪贴板后再恢复
        try? await Task.sleep(nanoseconds: 300_000_000)
        ClipboardService.restore(backup, ifUnchangedSince: count)
    }

    /// 忽略空白差异后，判断 value 是否包含译文开头部分。
    static func contains(_ value: String?, _ text: String) -> Bool {
        guard let value else { return false }
        let strip: (String) -> String = { $0.filter { !$0.isWhitespace } }
        let needle = String(strip(text).prefix(30))
        return needle.isEmpty || strip(value).contains(needle)
    }

    // MARK: - App 识别

    static func needsManualAccessibility(_ app: NSRunningApplication) -> Bool {
        if isChromium(app.bundleIdentifier ?? "") { return true }
        guard let url = app.bundleURL else { return false }
        let electron = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electron.path)
    }

    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    static func isChromium(_ bundleID: String) -> Bool { chromiumBundleIDs.contains(bundleID) }

    // MARK: - 后台执行 AX 调用

    private func runAX<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            axQueue.async { continuation.resume(returning: work()) }
        }
    }
}

/// 同步的 AX 调用集合，只在 TextBridge 的后台队列中执行。
enum AXReader {
    struct Result {
        let element: AXUIElement
        let fullText: String
        let selectedRange: NSRange?
        let sourceText: String
        let scope: SourceScope
        let caretRect: CGRect?
        let elementRect: CGRect?
    }

    enum Outcome {
        case ok(Result)
        case secure
        case unavailable
    }

    static let messagingTimeout: Float = 0.5

    static func read(pid: pid_t) -> Outcome {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var focusedRef: CFTypeRef?
        var focused: AXUIElement?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            focused = (ref as! AXUIElement)
        } else {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, messagingTimeout)
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
                focused = (ref as! AXUIElement)
            }
        }
        guard let element = focused else { return .unavailable }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        // 密码框：不读取任何内容（需求 2.1）
        if string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField" {
            return .secure
        }

        guard let value = string(element, kAXValueAttribute), !value.isEmpty else { return .unavailable }
        let selectedRange = range(element, kAXSelectedTextRangeAttribute)
        var sourceText = value
        var scope = SourceScope.fullText
        if let r = selectedRange, r.length > 0 {
            let selected = string(element, kAXSelectedTextAttribute) ?? UTF16Range.substring(of: value, range: r)
            if let selected, !selected.isEmpty {
                sourceText = selected
                scope = .selection
            }
        }
        return .ok(Result(element: element, fullText: value, selectedRange: selectedRange, sourceText: sourceText,
                          scope: scope, caretRect: caretRect(element, selectedRange), elementRect: frame(element)))
    }

    static func enableManualAccessibility(pid: pid_t, chromium: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let attribute = chromium ? "AXEnhancedUserInterface" : "AXManualAccessibility"
        AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &cfRange) else { return nil }
        return NSRange(location: cfRange.location, length: cfRange.length)
    }

    @discardableResult
    static func setSelectedRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    static func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return toCocoa(CGRect(origin: point, size: size))
    }

    /// 选区（或光标前一个字符）的屏幕矩形。
    static func caretRect(_ element: AXUIElement, _ selection: NSRange?) -> CGRect? {
        guard let selection else { return nil }
        var candidates = [CFRange(location: selection.location + selection.length, length: 0)]
        if selection.length > 0 {
            candidates.insert(CFRange(location: selection.location + selection.length - 1, length: 1), at: 0)
        } else if selection.location > 0 {
            candidates.append(CFRange(location: selection.location - 1, length: 1))
        }
        for var r in candidates {
            guard let param = AXValueCreate(.cfRange, &r) else { continue }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             param, &ref) == .success,
                  let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero else { continue }
            return toCocoa(rect)
        }
        return nil
    }

    /// AX 坐标以主屏左上角为原点，转换为 Cocoa 的左下角原点。
    static func toCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    /// 主屏高度，由主线程在每次读取前更新（NSScreen 只能在主线程访问）
    nonisolated(unsafe) static var primaryScreenHeight: CGFloat = 0
}
