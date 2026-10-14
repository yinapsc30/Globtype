import AppKit
import CoreGraphics

/// 模拟按键（用于剪贴板降级方案）。合成事件带有标记，事件监听会忽略它们。
enum KeySynth {
    /// 写入 eventSourceUserData 的标记值
    static let marker: Int64 = 0x474C_4F42 // "GLOB"

    enum Key: CGKeyCode {
        case a = 0
        case c = 8
        case v = 9
    }

    static func commandKey(_ key: Key) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
