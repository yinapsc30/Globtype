import Foundation

/// 本地日期（yyyy-MM-dd），用于复习到期判断。
public struct Day: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let string: String

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        string = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public init(string: String) {
        self.string = string
    }

    public func adding(days: Int, calendar: Calendar = .current) -> Day {
        let date = self.date(calendar: calendar)
        return Day(calendar.date(byAdding: .day, value: days, to: date) ?? date, calendar: calendar)
    }

    public func date(calendar: Calendar = .current) -> Date {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = parts.count > 0 ? parts[0] : 1970
        c.month = parts.count > 1 ? parts[1] : 1
        c.day = parts.count > 2 ? parts[2] : 1
        c.hour = 12
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    public static func < (a: Day, b: Day) -> Bool { a.string < b.string }
    public var description: String { string }
}

public enum ReviewAnswer: String, Sendable {
    case remembered, forgot, tooEasy
}

/// 简化 SM-2（需求 12.1）。正确性属性 6：连续"记得"间隔为 1, 2, 4, 8…，最长 365 天；
/// "忘了"后间隔归 0、当天再次到期（排在当天队列末尾，见 `LearningService.dueCards`）。
public enum Scheduler {
    /// 间隔上限（天）。
    public static let maxIntervalDays = 365

    public struct State: Equatable, Sendable {
        public var intervalDays: Int
        public var due: Day

        public init(intervalDays: Int, due: Day) {
            self.intervalDays = intervalDays
            self.due = due
        }
    }

    /// 新卡片当天到期。
    public static func initial(today: Day) -> State {
        State(intervalDays: 0, due: today)
    }

    /// 返回 nil 表示卡片被屏蔽（太简单）。
    public static func next(_ state: State, answer: ReviewAnswer, today: Day) -> State? {
        switch answer {
        case .remembered:
            let interval = min(maxIntervalDays, max(1, state.intervalDays * 2))
            return State(intervalDays: interval, due: today.adding(days: interval))
        case .forgot:
            // 当天再考一次；之后答"记得"从 1 天重新开始
            return State(intervalDays: 0, due: today)
        case .tooEasy:
            return nil
        }
    }
}
