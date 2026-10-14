import AppKit
import CoreGraphics
import GlobtypeCore
import os

/// 全局事件监听（需求 1）：双击 Shift、自定义快捷键、面板按键拦截、面板外点击。
@MainActor
final class HotkeyMonitor {
    /// 双击 Shift 或自定义快捷键触发
    var onTrigger: (() -> Void)?
    /// 面板可见时处理按键，返回 true 表示吞掉该事件
    var panelKeyHandler: ((CGKeyCode, CGEventFlags) -> Bool)?
    /// 鼠标按下（Cocoa 屏幕坐标）
    var mouseDownHandler: ((NSPoint) -> Void)?

    private let settings: SettingsStore
    private let ime = IMEDetector()
    private var detector = DoubleShiftDetector()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var composingAtShiftDown: [Bool] = []
    private var consecutiveDisables = 0
    private let log = Logger(subsystem: "app.globtype", category: "hotkey")

    var isRunning: Bool { tap != nil }
    var onRepeatedFailure: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// 创建事件监听；权限不足时返回 false。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: userInfo) else {
            log.error("event tap 创建失败，可能缺少权限")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("event tap 已启动")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// 在事件监听回调中同步调用（主线程），必须保持轻量。
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 被系统停用时立即重新启用；连续多次失败则提示用户
            consecutiveDisables += 1
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.error("event tap 被停用，已重新启用（第 \(self.consecutiveDisables) 次）")
            if consecutiveDisables >= 3 { onRepeatedFailure?() }
            return false
        default:
            consecutiveDisables = 0
        }

        if KeySynth.isSynthetic(event) { return false }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
            return false

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            _ = detector.feed(.otherKey)
            ime.noteKeyDown(keyCode: keyCode, flags: flags)
            if let panelKeyHandler, panelKeyHandler(keyCode, flags) { return true }
            if settings.isEnabled, let hotkey = settings.customHotkey, hotkey.matches(keyCode: keyCode, flags: flags),
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
                return true
            }
            return false

        case .leftMouseDown, .rightMouseDown:
            _ = detector.feed(.otherKey)
            ime.noteMouseDown()
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in self?.mouseDownHandler?(location) }
            return false

        default:
            return false
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        let isShiftKey = keyCode == 56 || keyCode == 60
        let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn]
        guard isShiftKey, flags.intersection(otherModifiers).isEmpty else {
            _ = detector.feed(.otherKey)
            return
        }
        if flags.contains(.maskShift) {
            // 记录每次 Shift 按下时是否处于组词状态，只保留最近两次
            composingAtShiftDown.append(ime.isComposing())
            if composingAtShiftDown.count > 2 { composingAtShiftDown.removeFirst() }
            _ = detector.feed(.shiftDown(timestamp: timestamp))
        } else if detector.feed(.shiftUp(timestamp: timestamp)) {
            let composing = composingAtShiftDown.contains(true)
            composingAtShiftDown.removeAll()
            guard settings.isEnabled, settings.useDoubleShift, !composing else {
                if composing { log.info("组词状态下忽略双击 Shift") }
                return
            }
            DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    // 回调运行在主线程的 run loop 上
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
