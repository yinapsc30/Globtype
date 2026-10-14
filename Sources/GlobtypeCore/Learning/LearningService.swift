import Foundation

public struct RecordInput: Sendable {
    public var sourceText: String
    public var translation: String
    public var mode: TranslationMode
    public var appBundleID: String
    public var appName: String
    public var expressions: [ExtractedExpression]
    public var explanation: String?

    public init(sourceText: String, translation: String, mode: TranslationMode, appBundleID: String,
                appName: String, expressions: [ExtractedExpression], explanation: String? = nil) {
        self.sourceText = sourceText
        self.translation = translation
        self.mode = mode
        self.appBundleID = appBundleID
        self.appName = appName
        self.expressions = expressions
        self.explanation = explanation
    }
}

public enum RecordOutcome: Equatable, Sendable {
    case skipped
    case recorded(recordID: Int64, newActiveCards: Int, newPendingCards: Int)
}

public struct Card: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var expressionID: Int64
    public var english: String
    public var chinese: String
    public var type: ExtractedExpression.Kind
    public var phonetic: String?
    public var contextZh: String
    public var contextEn: String
    public var intervalDays: Int
    public var due: Day
    public var useCount: Int
}

public struct RecordSummary: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var sourceText: String
    public var translation: String
    public var mode: TranslationMode
    public var appName: String
    public var appBundleID: String
    public var useCount: Int
    public var updatedAt: Date
}

public struct RecordDetail: Equatable, Sendable {
    public struct LinkedExpression: Equatable, Identifiable, Sendable {
        public var id: Int64
        public var english: String
        public var chinese: String
        public var cardStatus: String?
    }

    public var summary: RecordSummary
    public var explanation: String?
    public var expressions: [LinkedExpression]
}

public struct RecordQuery: Sendable {
    public var keyword: String
    public var appBundleID: String?
    public var from: Date?
    public var to: Date?
    public var limit: Int

    public init(keyword: String = "", appBundleID: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 200) {
        self.keyword = keyword
        self.appBundleID = appBundleID
        self.from = from
        self.to = to
        self.limit = limit
    }
}

/// 表达库与复习队列（需求 9、10、12）。
public final class LearningService: @unchecked Sendable {
    let db: SQLiteConnection
    let dictionary: WordLookup

    /// 不记录的 App（需求 9.2）
    public var noRecordBundleIDs: Set<String> = []
    /// 每日新卡上限（需求 10.6）
    public var dailyNewLimit: Int = 10
    /// 使用次数达到该值时提示并提前复习（需求 12.8）
    public static let frequentThreshold = 3

    public init(database: AppDatabase, dictionary: WordLookup) {
        db = database.db
        self.dictionary = dictionary
    }

    // MARK: - 记录

    @discardableResult
    public func record(_ input: RecordInput, now: Date = Date(), calendar: Calendar = .current) throws -> RecordOutcome {
        if noRecordBundleIDs.contains(input.appBundleID) { return .skipped }

        let source = PrivacyFilter.filter(input.sourceText)
        let translation = PrivacyFilter.filter(input.translation)
        let explanation = input.explanation.map(PrivacyFilter.filter)
        let normalized = Normalizer.normalize(source)
        guard !normalized.isEmpty, !translation.isEmpty else { return .skipped }
        let today = Day(now, calendar: calendar)
        let timestamp = Int64(now.timeIntervalSince1970)

        return try db.transaction {
            let recordID: Int64
            if let existing = try db.queryOne("SELECT id FROM records WHERE source_normalized = ?", [normalized]) {
                recordID = existing.int("id")
                try db.run("""
                    UPDATE records SET source_text = ?, translation = ?, mode = ?, explanation = ?,
                        app_bundle_id = ?, app_name = ?, use_count = use_count + 1, updated_at = ?
                    WHERE id = ?
                    """, [source, translation, input.mode.rawValue, explanation, input.appBundleID,
                          input.appName, timestamp, recordID])
            } else {
                try db.run("""
                    INSERT INTO records(source_text, source_normalized, translation, mode, explanation,
                        app_bundle_id, app_name, use_count, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                    """, [source, normalized, translation, input.mode.rawValue, explanation,
                          input.appBundleID, input.appName, timestamp, timestamp])
                recordID = db.lastInsertRowID
            }

            let candidates = CardSelector.select(input.expressions, dictionary: dictionary) { key in
                (try? self.isBlocked(key)) ?? false
            }
            var active = 0
            var pending = 0
            for item in candidates {
                let result = try linkExpression(item, recordID: recordID, contextZh: source,
                                                contextEn: translation, today: today, timestamp: timestamp)
                switch result {
                case .newActive: active += 1
                case .newPending: pending += 1
                case .existing: break
                }
            }
            try bumpDaily(today, translations: 1, newCards: active + pending)
            return .recorded(recordID: recordID, newActiveCards: active, newPendingCards: pending)
        }
    }

    enum LinkResult { case newActive, newPending, existing }

    private func linkExpression(_ item: ExtractedExpression, recordID: Int64, contextZh: String, contextEn: String,
                                today: Day, timestamp: Int64, manual: Bool = false) throws -> LinkResult {
        let key = Normalizer.normalizeExpression(item.en)
        let expressionID: Int64
        if let row = try db.queryOne("SELECT id FROM expressions WHERE english_normalized = ?", [key]) {
            expressionID = row.int("id")
        } else {
            // 单词卡的音标和释义来自本地词典（需求 10.8），短语用模型释义（需求 10.9）
            var chinese = item.zh
            var phonetic: String?
            if item.type == .word, let entry = dictionary.lookup(key) {
                phonetic = entry.phonetic
                if !entry.translation.isEmpty { chinese = entry.translation }
            }
            try db.run("""
                INSERT INTO expressions(english_normalized, english, chinese, type, phonetic, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [key, item.en, chinese, item.type.rawValue, phonetic, timestamp])
            expressionID = db.lastInsertRowID
        }
        try db.run("""
            INSERT INTO record_expressions(record_id, expression_id, context_zh, context_en) VALUES (?, ?, ?, ?)
            ON CONFLICT(record_id, expression_id) DO UPDATE SET context_zh = excluded.context_zh, context_en = excluded.context_en
            """, [recordID, expressionID, contextZh, contextEn])

        if let card = try db.queryOne("SELECT id, status FROM cards WHERE expression_id = ?", [expressionID]) {
            // 已有卡片：查询次数达到阈值时把到期日提前到今天（需求 12.8）
            let status = card.string("status")
            if manual, status != "active" {
                // 手动加入：待加入或已屏蔽的卡片直接激活
                try db.run("""
                    UPDATE cards SET status = 'active', activated_date = ?, due_date = ?, interval_days = 0, manual = 1
                    WHERE id = ?
                    """, [today.string, today.string, card.int("id")])
            } else if status == "active", try usageCount(expressionID: expressionID) >= Self.frequentThreshold {
                try db.run("UPDATE cards SET due_date = MIN(due_date, ?) WHERE id = ?", [today.string, card.int("id")])
            }
            return .existing
        }

        let status: String
        let activated: String?
        let activatedToday = try activatedCount(on: today)
        if manual || activatedToday < dailyNewLimit {
            status = "active"
            activated = today.string
        } else {
            status = "pending"
            activated = nil
        }
        try db.run("""
            INSERT INTO cards(expression_id, status, interval_days, due_date, review_count, activated_date, manual, created_at)
            VALUES (?, ?, 0, ?, 0, ?, ?, ?)
            """, [expressionID, status, today.string, activated, manual, timestamp])
        return status == "active" ? .newActive : .newPending
    }

    public func attachExplanation(recordID: Int64, markdown: String) throws {
        try db.run("UPDATE records SET explanation = ? WHERE id = ?", [PrivacyFilter.filter(markdown), recordID])
    }

    /// 手动把一段英文加入复习，不受每日上限限制（需求 10.11）。
    public func addManualCard(recordID: Int64, english: String, chinese: String = "", now: Date = Date()) throws {
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let record = try db.queryOne("SELECT source_text, translation FROM records WHERE id = ?", [recordID]) else { return }
        let key = Normalizer.normalizeExpression(text)
        try db.transaction {
            try db.run("DELETE FROM blocked_expressions WHERE english_normalized = ?", [key])
            let item = ExtractedExpression(en: text, zh: chinese, type: key.contains(" ") ? .phrase : .word)
            _ = try linkExpression(item, recordID: recordID, contextZh: record.string("source_text"),
                                   contextEn: record.string("translation"), today: Day(now),
                                   timestamp: Int64(now.timeIntervalSince1970), manual: true)
        }
    }

    // MARK: - 使用次数

    func usageCount(expressionID: Int64) throws -> Int {
        Int(try db.queryOne("SELECT COUNT(*) AS n FROM record_expressions WHERE expression_id = ?", [expressionID])?.int("n") ?? 0)
    }

    /// 表达被多少条记录使用过（需求 12.8）。
    public func usageCount(for english: String) -> Int {
        let key = Normalizer.normalizeExpression(english)
        let row = try? db.queryOne("""
            SELECT COUNT(*) AS n FROM record_expressions re JOIN expressions e ON e.id = re.expression_id
            WHERE e.english_normalized = ?
            """, [key])
        return Int(row?.int("n") ?? 0)
    }

    func isBlocked(_ key: String) throws -> Bool {
        try db.queryOne("SELECT 1 AS x FROM blocked_expressions WHERE english_normalized = ?", [key]) != nil
    }

    // MARK: - 复习

    func activatedCount(on day: Day) throws -> Int {
        Int(try db.queryOne("SELECT COUNT(*) AS n FROM cards WHERE activated_date = ? AND manual = 0",
                            [day.string])?.int("n") ?? 0)
    }

    /// 把待加入的卡片按创建时间补入，直到达到当日上限（需求 10.7）。
    public func refillPending(today: Day) throws {
        let room = dailyNewLimit - (try activatedCount(on: today))
        guard room > 0 else { return }
        try db.run("""
            UPDATE cards SET status = 'active', activated_date = ?, due_date = ?
            WHERE id IN (SELECT id FROM cards WHERE status = 'pending' ORDER BY created_at, id LIMIT ?)
            """, [today.string, today.string, room])
    }

    public func dueCount(today: Day = Day(Date())) -> Int {
        try? refillPending(today: today)
        return Int((try? db.queryOne("SELECT COUNT(*) AS n FROM cards WHERE status = 'active' AND due_date <= ?",
                                     [today.string]))?.int("n") ?? 0)
    }

    /// 到期卡片。排序：到期日升序；今天已答过（即"忘了"后重新到期）的排在最后，并按作答先后排列；
    /// 其余卡片中使用次数 ≥ 3 的在前（需求 12.1、12.8）。
    public func dueCards(limit: Int, today: Day = Day(Date())) throws -> [Card] {
        try refillPending(today: today)
        let startOfToday = Int64(Calendar.current.startOfDay(for: today.date()).timeIntervalSince1970)
        let rows = try db.query("""
            SELECT c.id, c.expression_id, c.interval_days, c.due_date, e.english, e.chinese, e.type, e.phonetic,
                (SELECT COUNT(*) FROM record_expressions re WHERE re.expression_id = e.id) AS use_count,
                (SELECT context_zh FROM record_expressions re JOIN records r ON r.id = re.record_id
                    WHERE re.expression_id = e.id ORDER BY r.updated_at DESC LIMIT 1) AS context_zh,
                (SELECT context_en FROM record_expressions re JOIN records r ON r.id = re.record_id
                    WHERE re.expression_id = e.id ORDER BY r.updated_at DESC LIMIT 1) AS context_en
            FROM cards c JOIN expressions e ON e.id = c.expression_id
            WHERE c.status = 'active' AND c.due_date <= ?
            ORDER BY c.due_date ASC,
                CASE WHEN c.last_reviewed_at >= ? THEN c.last_reviewed_at ELSE 0 END ASC,
                (use_count >= ?) DESC, c.id ASC
            LIMIT ?
            """, [today.string, startOfToday, Self.frequentThreshold, limit])
        return rows.map(Self.card(from:))
    }

    static func card(from row: Row) -> Card {
        Card(id: row.int("id"), expressionID: row.int("expression_id"), english: row.string("english"),
             chinese: row.string("chinese"), type: ExtractedExpression.Kind(rawValue: row.string("type")) ?? .phrase,
             phonetic: row.optionalString("phonetic"), contextZh: row.string("context_zh"),
             contextEn: row.string("context_en"), intervalDays: Int(row.int("interval_days")),
             due: Day(string: row.string("due_date")), useCount: Int(row.int("use_count")))
    }

    public func review(cardID: Int64, answer: ReviewAnswer, today: Day = Day(Date()), now: Date = Date()) throws {
        guard let row = try db.queryOne("""
            SELECT c.interval_days, c.due_date, e.english_normalized FROM cards c
            JOIN expressions e ON e.id = c.expression_id WHERE c.id = ?
            """, [cardID]) else { return }
        let state = Scheduler.State(intervalDays: Int(row.int("interval_days")), due: Day(string: row.string("due_date")))
        try db.transaction {
            if let next = Scheduler.next(state, answer: answer, today: today) {
                try db.run("""
                    UPDATE cards SET interval_days = ?, due_date = ?, review_count = review_count + 1,
                        last_reviewed_at = ? WHERE id = ?
                    """, [next.intervalDays, next.due.string, Int64(now.timeIntervalSince1970), cardID])
            } else {
                // 太简单：屏蔽并不再加入（需求 10.5）
                try db.run("UPDATE cards SET status = 'blocked' WHERE id = ?", [cardID])
                try db.run("INSERT OR IGNORE INTO blocked_expressions(english_normalized, created_at) VALUES (?, ?)",
                           [row.string("english_normalized"), Int64(now.timeIntervalSince1970)])
            }
            try bumpDaily(today, reviews: 1)
        }
    }

    func bumpDaily(_ day: Day, translations: Int = 0, reviews: Int = 0, newCards: Int = 0) throws {
        try db.run("""
            INSERT INTO daily_stats(day, translations, reviews, new_cards) VALUES (?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET translations = translations + excluded.translations,
                reviews = reviews + excluded.reviews, new_cards = new_cards + excluded.new_cards
            """, [day.string, translations, reviews, newCards])
    }

    // MARK: - 表达库查询（需求 9.5）

    public func search(_ q: RecordQuery) throws -> [RecordSummary] {
        var conditions: [String] = []
        var args: [SQLBindable] = []
        let keyword = q.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            if keyword.count >= 3 {
                // trigram 分词需要至少 3 个字符；用双引号包裹作为短语，转义内部引号
                conditions.append("r.id IN (SELECT rowid FROM records_fts WHERE records_fts MATCH ?)")
                args.append("\"" + keyword.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            } else {
                conditions.append("(r.source_text LIKE ? ESCAPE '\\' OR r.translation LIKE ? ESCAPE '\\')")
                let escaped = keyword.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                args.append("%\(escaped)%")
                args.append("%\(escaped)%")
            }
        }
        if let app = q.appBundleID {
            conditions.append("r.app_bundle_id = ?")
            args.append(app)
        }
        if let from = q.from {
            conditions.append("r.updated_at >= ?")
            args.append(Int64(from.timeIntervalSince1970))
        }
        if let to = q.to {
            conditions.append("r.updated_at < ?")
            args.append(Int64(to.timeIntervalSince1970))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        args.append(q.limit)
        return try db.query("""
            SELECT r.id, r.source_text, r.translation, r.mode, r.app_name, r.app_bundle_id, r.use_count, r.updated_at
            FROM records r \(whereClause) ORDER BY r.updated_at DESC, r.id DESC LIMIT ?
            """, args).map(Self.summary(from:))
    }

    static func summary(from row: Row) -> RecordSummary {
        RecordSummary(id: row.int("id"), sourceText: row.string("source_text"), translation: row.string("translation"),
                      mode: TranslationMode(rawValue: row.string("mode")) ?? .translate, appName: row.string("app_name"),
                      appBundleID: row.string("app_bundle_id"), useCount: Int(row.int("use_count")),
                      updatedAt: Date(timeIntervalSince1970: TimeInterval(row.int("updated_at"))))
    }

    public func detail(recordID: Int64) throws -> RecordDetail? {
        guard let row = try db.queryOne("""
            SELECT id, source_text, translation, mode, app_name, app_bundle_id, use_count, updated_at, explanation
            FROM records WHERE id = ?
            """, [recordID]) else { return nil }
        let expressions = try db.query("""
            SELECT e.id, e.english, e.chinese, c.status FROM record_expressions re
            JOIN expressions e ON e.id = re.expression_id LEFT JOIN cards c ON c.expression_id = e.id
            WHERE re.record_id = ? ORDER BY e.id
            """, [recordID]).map {
            RecordDetail.LinkedExpression(id: $0.int("id"), english: $0.string("english"),
                                          chinese: $0.string("chinese"), cardStatus: $0.optionalString("status"))
        }
        return RecordDetail(summary: Self.summary(from: row), explanation: row.optionalString("explanation"),
                            expressions: expressions)
    }

    /// 表达库中出现过的 App（用于筛选）。
    public func apps() throws -> [(bundleID: String, name: String)] {
        try db.query("SELECT app_bundle_id, MAX(app_name) AS app_name FROM records GROUP BY app_bundle_id ORDER BY app_name")
            .map { ($0.string("app_bundle_id"), $0.string("app_name")) }
    }

    public var recordCount: Int {
        Int((try? db.queryOne("SELECT COUNT(*) AS n FROM records"))?.int("n") ?? 0)
    }

    // MARK: - 删除（需求 9.6）

    public func deleteRecord(id: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM records WHERE id = ?", [id])
            try deleteOrphanExpressions()
        }
    }

    public func deleteRecords(from: Date, to: Date) throws {
        try db.transaction {
            try db.run("DELETE FROM records WHERE updated_at >= ? AND updated_at < ?",
                       [Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)])
            try deleteOrphanExpressions()
        }
    }

    /// 清空全部记录及其派生的表达和卡片（保留"太简单"屏蔽列表）。
    public func deleteAll() throws {
        try db.transaction {
            try db.run("DELETE FROM records")
            try db.run("DELETE FROM expressions")
            try db.run("DELETE FROM daily_stats")
        }
    }

    /// 没有任何记录引用的表达连同其卡片一起删除，避免保留已删除文本的上下文。
    private func deleteOrphanExpressions() throws {
        try db.run("DELETE FROM expressions WHERE id NOT IN (SELECT DISTINCT expression_id FROM record_expressions)")
    }
}

/// 从整段上下文中取出包含表达的那一句（设计：数据模型 · 上下文）。
public enum ContextSnippet {
    public static func sentence(containing needle: String, in text: String, maxLength: Int = 160) -> String {
        let separators = CharacterSet(charactersIn: "。！？!?\n.；;")
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch.unicodeScalars.allSatisfy({ separators.contains($0) }) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        let lower = needle.lowercased()
        let hit = sentences.first { $0.lowercased().contains(lower) } ?? text
        let trimmed = hit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "…" : trimmed
    }
}
