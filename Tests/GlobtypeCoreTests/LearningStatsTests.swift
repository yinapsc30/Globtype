import Foundation
import Testing
@testable import GlobtypeCore

@Suite struct LearningStatsTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func makeService(limit: Int = 10) throws -> LearningService {
        let s = LearningService(database: try AppDatabase(path: nil), dictionary: FakeDictionary.standard)
        s.dailyNewLimit = limit
        return s
    }

    func input(_ source: String, _ exprs: [String]) -> RecordInput {
        RecordInput(sourceText: source, translation: "EN " + source, mode: .translate, appBundleID: "app", appName: "App",
                    expressions: exprs.map { ExtractedExpression(en: $0, zh: "释义 \($0)", type: .phrase) })
    }

    /// 正确性属性 9：与朴素的逐日检查一致
    @Test func streakMatchesNaive() {
        let today = Day(string: "2026-09-30")
        for _ in 0..<300 {
            var days = Set<Day>()
            for offset in 0..<20 where Bool.random() { days.insert(today.adding(days: -offset)) }
            var naive = 0
            var d = days.contains(today) ? today : today.adding(days: -1)
            while days.contains(d) { naive += 1; d = d.adding(days: -1) }
            #expect(LearningService.streak(activeDays: days, today: today) == naive)
        }
        #expect(LearningService.streak(activeDays: [], today: today) == 0)
        #expect(LearningService.streak(activeDays: [today.adding(days: -1), today.adding(days: -2)], today: today) == 2)
        #expect(LearningService.streak(activeDays: [today.adding(days: -2)], today: today) == 0)
    }

    /// 正确性属性 10
    @Test func statsAreConsistent() throws {
        let s = try makeService(limit: 2)
        let today = Day(now)
        try s.record(input("一", ["alpha one", "beta two", "gamma three"]), now: now)
        let due = try s.dueCards(limit: 10, today: today)
        try s.review(cardID: due[0].id, answer: .tooEasy, today: today)
        let st = try s.stats(today: today)
        #expect(st.active == 1 && st.pending == 1 && st.blocked == 1)
        #expect(st.active + st.pending + st.blocked == 3)
        #expect(st.mastered <= st.active)
        #expect(st.totalExpressions == 3)
        #expect(st.records == 1)
        #expect(st.reviewedToday == 1)
        #expect(st.streakDays == 1)
        #expect(st.dueToday == 1)
    }

    @Test func masteredAfterLongInterval() throws {
        let s = try makeService()
        var today = Day(now)
        try s.record(input("一", ["alpha one"]), now: now)
        // 1, 2, 4, 8, 16, 32 → 第 6 次"记得"后间隔 ≥ 21
        for _ in 0..<6 {
            let card = try #require(try s.dueCards(limit: 1, today: today).first)
            try s.review(cardID: card.id, answer: .remembered, today: today)
            today = today.adding(days: card.intervalDays == 0 ? 1 : card.intervalDays * 2)
        }
        let st = try s.stats(today: today)
        #expect(st.mastered == 1)
        #expect(try s.expressions(ExpressionQuery(status: .mastered)).count == 1)
        #expect(try s.expressions(ExpressionQuery(status: .reviewing)).isEmpty)
    }

    @Test func dailyActivityFillsGaps() throws {
        let s = try makeService()
        let today = Day(now)
        try s.record(input("一", []), now: now)
        try s.record(input("二", []), now: now)
        try s.record(input("三", []), now: now.addingTimeInterval(-2 * 86400))
        let act = try s.dailyActivity(days: 5, today: today)
        #expect(act.count == 5)
        #expect(act.last?.day == today && act.last?.translations == 2)
        #expect(act[2].translations == 1)
        #expect(act[0].translations == 0 && act[1].translations == 0)
    }

    @Test func expressionQueriesAndContexts() throws {
        let s = try makeService(limit: 1)
        try s.record(input("第一句", ["sync on", "circle back"]), now: now)
        try s.record(input("第二句", ["sync on"]), now: now.addingTimeInterval(10))
        let all = try s.expressions(ExpressionQuery())
        #expect(all.count == 2)
        let mostUsed = try s.expressions(ExpressionQuery(sort: .mostUsed))
        #expect(mostUsed.first?.english == "sync on" && mostUsed.first?.useCount == 2)
        #expect(try s.expressions(ExpressionQuery(keyword: "释义 circle")).map(\.english) == ["circle back"])
        #expect(try s.expressions(ExpressionQuery(status: .pending)).map(\.english) == ["circle back"])
        #expect(try s.expressions(ExpressionQuery(keyword: "50%")).isEmpty)
        let sync = try #require(all.first { $0.english == "sync on" })
        let ctx = try s.contexts(expressionID: sync.id)
        #expect(ctx.map(\.chinese) == ["第二句", "第一句"])
    }

    @Test func stopAndRestore() throws {
        let s = try makeService(limit: 0)
        let today = Day(now)
        try s.record(input("一", ["sync on"]), now: now)
        let e = try #require(try s.expressions(ExpressionQuery()).first)
        #expect(e.status == .pending)
        try s.stopReviewing(expressionID: e.id, now: now)
        #expect(try s.expressions(ExpressionQuery()).first?.status == .blocked)
        // 屏蔽后再次出现不会加入
        try s.record(input("二", ["sync on"]), now: now)
        #expect(try s.dueCards(limit: 10, today: today).isEmpty)
        // 恢复后当天到期，且上限为 0 时也生效
        try s.restoreReview(expressionID: e.id, today: today, now: now)
        #expect(try s.expressions(ExpressionQuery()).first?.status == .reviewing)
        #expect(try s.dueCards(limit: 10, today: today).map(\.english) == ["sync on"])
    }

    @Test func deleteAllClearsStats() throws {
        let s = try makeService()
        try s.record(input("一", []), now: now)
        try s.deleteAll()
        #expect(try s.stats(today: Day(now)).streakDays == 0)
        #expect(try s.dailyActivity(days: 1, today: Day(now)).first?.translations == 0)
    }

    @Test func migratesFromV1() throws {
        let path = NSTemporaryDirectory() + "gt-v1-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let conn = try SQLiteConnection(path: path)
        try conn.execute(AppDatabase.migrations[0])
        try conn.execute("PRAGMA user_version = 1")
        let db = try AppDatabase(path: path)
        #expect(db.schemaVersion == AppDatabase.migrations.count)
        #expect(try db.db.queryOne("SELECT COUNT(*) AS n FROM daily_stats")?.int("n") == 0)
    }

    /// v2 → v3：已有卡片保留，新增的 last_reviewed_at 为空，照常出现在到期队列
    @Test func migratesFromV2KeepsCards() throws {
        let path = NSTemporaryDirectory() + "gt-v2-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let conn = try SQLiteConnection(path: path)
        try conn.execute(AppDatabase.migrations[0])
        try conn.execute(AppDatabase.migrations[1])
        try conn.execute("PRAGMA user_version = 2")
        let today = Day(now)
        try conn.execute("""
            INSERT INTO expressions(english_normalized, english, chinese, type, created_at)
                VALUES ('sync on', 'sync on', '对一下', 'phrase', 0);
            INSERT INTO cards(expression_id, status, interval_days, due_date, review_count, created_at)
                VALUES (1, 'active', 4, '\(today.string)', 3, 0);
            """)
        let db = try AppDatabase(path: path)
        #expect(db.schemaVersion == AppDatabase.migrations.count)
        let row = try #require(try db.db.queryOne("SELECT interval_days, last_reviewed_at FROM cards"))
        #expect(row.int("interval_days") == 4)
        #expect(row["last_reviewed_at"].int == nil)
        let s = LearningService(database: db, dictionary: FakeDictionary.standard)
        #expect(try s.dueCards(limit: 10, today: today).map(\.english) == ["sync on"])
    }
}
