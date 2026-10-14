import Foundation

/// 学习概览统计（需求 16）。
public struct LearningStats: Equatable, Sendable {
    public var dueToday: Int
    public var active: Int
    public var pending: Int
    public var mastered: Int
    public var blocked: Int
    public var totalExpressions: Int
    public var records: Int
    public var streakDays: Int
    public var reviewedToday: Int
}

public struct DayActivity: Equatable, Identifiable, Sendable {
    public var day: Day
    public var translations: Int
    public var reviews: Int
    public var id: String { day.string }
}

/// 表达的学习状态（由卡片状态与复习间隔推导，需求 17.1）。
public enum ExpressionStatus: String, CaseIterable, Sendable {
    case reviewing, pending, mastered, blocked

    public var displayName: String {
        switch self {
        case .reviewing: return "复习中"
        case .pending: return "排队中"
        case .mastered: return "已掌握"
        case .blocked: return "太简单"
        }
    }

    static func from(cardStatus: String?, interval: Int) -> ExpressionStatus? {
        switch cardStatus {
        case "active": return interval >= LearningService.masteredInterval ? .mastered : .reviewing
        case "pending": return .pending
        case "blocked": return .blocked
        default: return nil
        }
    }
}

public struct ExpressionSummary: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var english: String
    public var chinese: String
    public var type: ExtractedExpression.Kind
    public var phonetic: String?
    public var status: ExpressionStatus?
    public var intervalDays: Int
    public var due: Day?
    public var useCount: Int
}

public struct ExpressionQuery: Sendable {
    public enum Sort: Sendable { case newest, mostUsed }
    public var keyword: String
    public var status: ExpressionStatus?
    public var sort: Sort
    public var limit: Int

    public init(keyword: String = "", status: ExpressionStatus? = nil, sort: Sort = .newest, limit: Int = 500) {
        self.keyword = keyword
        self.status = status
        self.sort = sort
        self.limit = limit
    }
}

public struct ExpressionContext: Equatable, Identifiable, Sendable {
    public var recordID: Int64
    public var chinese: String
    public var english: String
    public var appName: String
    public var date: Date
    public var id: Int64 { recordID }
}

extension LearningService {
    /// 复习间隔达到该天数视为已掌握（需求 16.3）
    public static let masteredInterval = 21

    public func stats(today: Day = Day(Date())) throws -> LearningStats {
        try refillPending(today: today)
        func count(_ sql: String, _ args: [SQLBindable] = []) throws -> Int {
            Int(try db.queryOne(sql, args)?.int("n") ?? 0)
        }
        let reviewedToday = try count("SELECT COALESCE(SUM(reviews),0) AS n FROM daily_stats WHERE day = ?", [today.string])
        return LearningStats(
            dueToday: try count("SELECT COUNT(*) AS n FROM cards WHERE status = 'active' AND due_date <= ?", [today.string]),
            active: try count("SELECT COUNT(*) AS n FROM cards WHERE status = 'active'"),
            pending: try count("SELECT COUNT(*) AS n FROM cards WHERE status = 'pending'"),
            mastered: try count("SELECT COUNT(*) AS n FROM cards WHERE status = 'active' AND interval_days >= ?", [Self.masteredInterval]),
            blocked: try count("SELECT COUNT(*) AS n FROM cards WHERE status = 'blocked'"),
            totalExpressions: try count("SELECT COUNT(*) AS n FROM expressions"),
            records: try count("SELECT COUNT(*) AS n FROM records"),
            streakDays: Self.streak(activeDays: try activeDays(), today: today),
            reviewedToday: reviewedToday)
    }

    func activeDays() throws -> Set<Day> {
        Set(try db.query("SELECT day FROM daily_stats WHERE translations + reviews > 0").map { Day(string: $0.string("day")) })
    }

    /// 连续学习天数：今天有活动从今天数，否则从昨天数（需求 16.2）。
    public static func streak(activeDays: Set<Day>, today: Day) -> Int {
        var day = activeDays.contains(today) ? today : today.adding(days: -1)
        var n = 0
        while activeDays.contains(day) {
            n += 1
            day = day.adding(days: -1)
        }
        return n
    }

    /// 最近 N 天（含今天）的翻译与复习次数，缺失日期补 0，按日期升序（需求 16.4）。
    public func dailyActivity(days: Int, today: Day = Day(Date())) throws -> [DayActivity] {
        let start = today.adding(days: -(days - 1))
        let rows = try db.query("SELECT day, translations, reviews FROM daily_stats WHERE day >= ? AND day <= ?",
                                [start.string, today.string])
        var map: [String: (Int, Int)] = [:]
        for r in rows { map[r.string("day")] = (Int(r.int("translations")), Int(r.int("reviews"))) }
        return (0..<days).map { offset in
            let day = start.adding(days: offset)
            let v = map[day.string] ?? (0, 0)
            return DayActivity(day: day, translations: v.0, reviews: v.1)
        }
    }

    public func expressions(_ q: ExpressionQuery) throws -> [ExpressionSummary] {
        var conditions: [String] = []
        var args: [SQLBindable] = []
        let keyword = q.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let escaped = keyword.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            conditions.append("(e.english LIKE ? ESCAPE '\\' OR e.chinese LIKE ? ESCAPE '\\')")
            args += ["%\(escaped)%", "%\(escaped)%"]
        }
        switch q.status {
        case .reviewing?:
            conditions.append("c.status = 'active' AND c.interval_days < ?")
            args.append(Self.masteredInterval)
        case .mastered?:
            conditions.append("c.status = 'active' AND c.interval_days >= ?")
            args.append(Self.masteredInterval)
        case .pending?: conditions.append("c.status = 'pending'")
        case .blocked?: conditions.append("c.status = 'blocked'")
        case nil: break
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let order = q.sort == .newest ? "e.created_at DESC, e.id DESC" : "use_count DESC, e.id DESC"
        args.append(q.limit)
        return try db.query("""
            SELECT e.id, e.english, e.chinese, e.type, e.phonetic, c.status, c.interval_days, c.due_date,
                (SELECT COUNT(*) FROM record_expressions re WHERE re.expression_id = e.id) AS use_count
            FROM expressions e LEFT JOIN cards c ON c.expression_id = e.id
            \(whereClause) ORDER BY \(order) LIMIT ?
            """, args).map { row in
            let interval = Int(row.int("interval_days"))
            return ExpressionSummary(
                id: row.int("id"), english: row.string("english"), chinese: row.string("chinese"),
                type: ExtractedExpression.Kind(rawValue: row.string("type")) ?? .phrase,
                phonetic: row.optionalString("phonetic").flatMap { $0.isEmpty ? nil : $0 },
                status: ExpressionStatus.from(cardStatus: row.optionalString("status"), interval: interval),
                intervalDays: interval, due: row.optionalString("due_date").map(Day.init(string:)),
                useCount: Int(row.int("use_count")))
        }
    }

    public func contexts(expressionID: Int64) throws -> [ExpressionContext] {
        try db.query("""
            SELECT r.id, re.context_zh, re.context_en, r.app_name, r.updated_at FROM record_expressions re
            JOIN records r ON r.id = re.record_id WHERE re.expression_id = ? ORDER BY r.updated_at DESC
            """, [expressionID]).map {
            ExpressionContext(recordID: $0.int("id"), chinese: $0.string("context_zh"), english: $0.string("context_en"),
                              appName: $0.string("app_name"),
                              date: Date(timeIntervalSince1970: TimeInterval($0.int("updated_at"))))
        }
    }

    /// 恢复复习：移出屏蔽列表、当天到期，不占每日上限（需求 17.4）。
    public func restoreReview(expressionID: Int64, today: Day = Day(Date()), now: Date = Date()) throws {
        guard let row = try db.queryOne("SELECT english_normalized FROM expressions WHERE id = ?", [expressionID]) else { return }
        try db.transaction {
            try db.run("DELETE FROM blocked_expressions WHERE english_normalized = ?", [row.string("english_normalized")])
            if try db.queryOne("SELECT id FROM cards WHERE expression_id = ?", [expressionID]) != nil {
                try db.run("""
                    UPDATE cards SET status = 'active', interval_days = 0, due_date = ?, activated_date = ?, manual = 1
                    WHERE expression_id = ?
                    """, [today.string, today.string, expressionID])
            } else {
                try db.run("""
                    INSERT INTO cards(expression_id, status, interval_days, due_date, review_count, activated_date, manual, created_at)
                    VALUES (?, 'active', 0, ?, 0, ?, 1, ?)
                    """, [expressionID, today.string, today.string, Int64(now.timeIntervalSince1970)])
            }
        }
    }

    /// 不再复习：等同"太简单"（需求 17.5）。
    public func stopReviewing(expressionID: Int64, now: Date = Date()) throws {
        guard let row = try db.queryOne("SELECT english_normalized FROM expressions WHERE id = ?", [expressionID]) else { return }
        try db.transaction {
            try db.run("UPDATE cards SET status = 'blocked' WHERE expression_id = ?", [expressionID])
            try db.run("INSERT OR IGNORE INTO blocked_expressions(english_normalized, created_at) VALUES (?, ?)",
                       [row.string("english_normalized"), Int64(now.timeIntervalSince1970)])
        }
    }
}
