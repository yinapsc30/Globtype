import Foundation

/// 送入双击 Shift 状态机的按键事件。
public enum KeyInput: Equatable, Sendable {
    case shiftDown(timestamp: TimeInterval)
    case shiftUp(timestamp: TimeInterval)
    /// 任意非 Shift 的按键或修饰键变化
    case otherKey
}

/// 识别"两次无干扰的 Shift 单击"的纯状态机。
///
/// 规则（需求 1.1、1.2）：
/// - 一次单击 = Shift 按下后，中间没有其他按键就松开
/// - 第二次单击松开的时刻距第一次单击按下的时刻不超过 `threshold` 时触发
/// - 期间出现任何其他按键则重置
public struct DoubleShiftDetector: Sendable {
    public var threshold: TimeInterval

    private enum State: Sendable {
        case idle
        case firstDown(start: TimeInterval)
        case firstTapped(start: TimeInterval)
        case secondDown(start: TimeInterval)
    }

    private var state: State = .idle

    public init(threshold: TimeInterval = 0.4) {
        self.threshold = threshold
    }

    /// 送入一个事件，返回 true 表示本次事件完成了一次双击。
    public mutating func feed(_ input: KeyInput) -> Bool {
        switch (state, input) {
        case (_, .otherKey):
            state = .idle
            return false

        case (.idle, .shiftDown(let t)):
            state = .firstDown(start: t)
            return false

        case (.firstDown(let start), .shiftUp(let t)):
            state = t - start <= threshold ? .firstTapped(start: start) : .idle
            return false

        case (.firstTapped(let start), .shiftDown(let t)):
            if t - start <= threshold {
                state = .secondDown(start: start)
            } else {
                // 已超时，本次按下当作新的第一次
                state = .firstDown(start: t)
            }
            return false

        case (.secondDown(let start), .shiftUp(let t)):
            state = .idle
            return t - start <= threshold

        case (.firstDown, .shiftDown(let t)), (.secondDown, .shiftDown(let t)):
            // 左右 Shift 同时按下等异常序列：从这次按下重新开始
            state = .firstDown(start: t)
            return false

        case (.idle, .shiftUp), (.firstTapped, .shiftUp):
            state = .idle
            return false
        }
    }

    public mutating func reset() {
        state = .idle
    }
}
