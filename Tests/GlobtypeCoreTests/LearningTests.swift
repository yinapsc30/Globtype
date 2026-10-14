import Foundation
import Testing
@testable import GlobtypeCore

@Suite struct NormalizerTests {
    @Test func normalizes() {
        #expect(Normalizer.normalize("  你好，世界！  ") == "你好,世界!")
        #expect(Normalizer.normalize("ＡＢＣ　１２３") == "ABC 123")
        #expect(Normalizer.normalize("a \n\t b") == "a b")
    }

    /// 正确性属性 5
    @Test func idempotent() {
        let samples = ["  你好，世界！  ", "ＡＢＣ　１２３", "“引号”…——", "mixed  中文，English。", "\n\n", "😀 ！"]
        for s in samples {
            let once = Normalizer.normalize(s)
            #expect(Normalizer.normalize(once) == once)
        }
    }

    @Test func expression() {
        #expect(Normalizer.normalizeExpression(" Sync On. ") == "sync on")
        #expect(Normalizer.normalizeExpression("don't") == "don't")
    }
}

@Suite struct PrivacyFilterTests {
    @Test(arguments: [
        ("电话 13812345678 找我", "电话 [手机号] 找我"),
        ("call +86 138-1234-5678", "call [手机号]"),
        ("邮箱 zhang.san@example.com.cn", "邮箱 [邮箱]"),
        ("身份证 11010519491231002X 已提交", "身份证 [身份证号] 已提交"),
        ("卡号 4111 1111 1111 1111", "卡号 [银行卡号]"),
        ("卡号6222021234567890128", "卡号[银行卡号]"),
    ])
    func replacesSensitive(input: String, expected: String) {
        #expect(PrivacyFilter.filter(input) == expected)
    }

    /// 正确性属性 4：普通文本不被误伤
    @Test(arguments: [
        "这个需求我们下周再对一下",
        "会议定在 2026-09-28 14:30",
        "订单号 20260928001 已发货",
        "版本 v1.2.3，构建号 12345678",
        "价格 1999 元，库存 300 件",
        "Let's sync on this next week.",
        "卡号 4111 1111 1111 1112",   // Luhn 不通过
    ])
    func keepsNormalText(input: String) {
        #expect(PrivacyFilter.filter(input) == input)
    }

    /// 正确性属性 3
    @Test func idempotent() {
        let s = "联系 13812345678 或 a@b.com，卡 4111111111111111，证 11010519491231002X"
        let once = PrivacyFilter.filter(s)
        #expect(PrivacyFilter.filter(once) == once)
        #expect(!PrivacyFilter.containsSensitive(once))
    }
}

struct FakeDictionary: WordLookup {
    var entries: [String: DictEntry]
    func lookup(_ word: String) -> DictEntry? { entries[word.lowercased()] }

    static let standard = FakeDictionary(entries: [
        "good": DictEntry(word: "good", phonetic: "gud", translation: "好的", tags: ["zk", "gk"]),
        "requirement": DictEntry(word: "requirement", phonetic: "ri'kwaiəmənt", translation: "n. 需求；要求", tags: ["cet4"]),
    ])
}

@Suite struct CardSelectorTests {
    @Test func filtersAndOrders() {
        let input = [
            ExtractedExpression(en: "requirement", zh: "需求", type: .word),
            ExtractedExpression(en: "good", zh: "好", type: .word),
            ExtractedExpression(en: "sync on", zh: "对齐", type: .phrase),
            ExtractedExpression(en: "Sync on", zh: "重复", type: .phrase),
            ExtractedExpression(en: "circle back", zh: "回头再谈", type: .word), // 类型标错
            ExtractedExpression(en: "blocked phrase", zh: "", type: .phrase),
            ExtractedExpression(en: String(repeating: "x ", count: 40), zh: "", type: .phrase),
        ]
        let out = CardSelector.select(input, dictionary: FakeDictionary.standard) { $0 == "blocked phrase" }
        #expect(out.map(\.en) == ["sync on", "circle back", "requirement"])
        #expect(out[1].type == .phrase)
    }
}

@Suite struct SchedulerTests {
    let today = Day(string: "2026-09-28")

    /// 正确性属性 6
    @Test func intervalsDouble() {
        var state = Scheduler.initial(today: today)
        #expect(state.due == today)
        var intervals: [Int] = []
        for _ in 0..<5 {
            state = Scheduler.next(state, answer: .remembered, today: today)!
            intervals.append(state.intervalDays)
        }
        #expect(intervals == [1, 2, 4, 8, 16])
        // 忘了：间隔归 0，当天再次到期
        state = Scheduler.next(state, answer: .forgot, today: today)!
        #expect(state.intervalDays == 0)
        #expect(state.due == today)
        // 忘了之后再答记得，从 1 天重新开始
        state = Scheduler.next(state, answer: .remembered, today: today)!
        #expect(state.intervalDays == 1)
        #expect(state.due == Day(string: "2026-09-29"))
        #expect(Scheduler.next(state, answer: .tooEasy, today: today) == nil)
    }

    /// 正确性属性 6：间隔不超过上限，达到上限后保持不变
    @Test func intervalCapped() {
        var state = Scheduler.initial(today: today)
        var intervals: [Int] = []
        for _ in 0..<12 {
            state = Scheduler.next(state, answer: .remembered, today: today)!
            intervals.append(state.intervalDays)
        }
        #expect(intervals == [1, 2, 4, 8, 16, 32, 64, 128, 256, 365, 365, 365])
        #expect(state.due == today.adding(days: Scheduler.maxIntervalDays))
        // 从超过上限的旧数据继续也会被收回到上限
        let legacy = Scheduler.State(intervalDays: 500, due: today)
        #expect(Scheduler.next(legacy, answer: .remembered, today: today)?.intervalDays == Scheduler.maxIntervalDays)
    }

    /// 正确性属性 6：任意作答序列下，间隔始终在 [0, 上限] 内；"忘了"后恒为 0 且当天到期
    @Test func randomAnswerSequences() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var state = Scheduler.initial(today: today)
            for _ in 0..<30 {
                let answer: ReviewAnswer = Bool.random(using: &rng) ? .remembered : .forgot
                let previous = state.intervalDays
                state = Scheduler.next(state, answer: answer, today: today)!
                #expect((0...Scheduler.maxIntervalDays).contains(state.intervalDays))
                if answer == .forgot {
                    #expect(state.intervalDays == 0 && state.due == today)
                } else {
                    #expect(state.intervalDays == min(Scheduler.maxIntervalDays, max(1, previous * 2)))
                }
            }
        }
    }

    @Test func dayArithmeticAcrossMonths() {
        #expect(Day(string: "2026-09-30").adding(days: 1) == Day(string: "2026-10-01"))
        #expect(Day(string: "2026-12-31").adding(days: 1) == Day(string: "2027-01-01"))
    }
}

@Suite struct LearningServiceTests {
    func makeService(limit: Int = 10) throws -> LearningService {
        let s = LearningService(database: try AppDatabase(path: nil), dictionary: FakeDictionary.standard)
        s.dailyNewLimit = limit
        return s
    }

    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func input(_ source: String, _ exprs: [String], app: String = "com.tencent.xinWeChat") -> RecordInput {
        RecordInput(sourceText: source, translation: "EN: " + source, mode: .translate, appBundleID: app,
                    appName: "微信", expressions: exprs.map { ExtractedExpression(en: $0, zh: "释义", type: $0.contains(" ") ? .phrase : .word) })
    }

    @Test func recordsAndDeduplicates() throws {
        let s = try makeService()
        let a = try s.record(input("这个需求我们下周再对一下", ["sync on"]), now: now)
        let b = try s.record(input("这个需求我们下周再对一下 ", ["sync on"]), now: now)
        guard case .recorded(let id1, 1, 0) = a, case .recorded(let id2, 0, 0) = b else {
            Issue.record("结果不符：\(a) \(b)")
            return
        }
        #expect(id1 == id2)
        #expect(s.recordCount == 1)
        #expect(try s.search(RecordQuery()).first?.useCount == 2)
    }

    @Test func skipsExcludedApps() throws {
        let s = try makeService()
        s.noRecordBundleIDs = ["com.bank"]
        #expect(try s.record(input("转账", [], app: "com.bank")) == .skipped)
        #expect(s.recordCount == 0)
    }

    @Test func filtersPrivacyBeforeWriting() throws {
        let s = try makeService()
        try s.record(input("我的手机 13812345678", []), now: now)
        let rec = try s.search(RecordQuery()).first!
        #expect(rec.sourceText == "我的手机 [手机号]")
        #expect(!rec.translation.contains("13812345678"))
    }

    /// 正确性属性 7
    @Test func dailyLimitAndPendingRefill() throws {
        let s = try makeService(limit: 2)
        let today = Day(now)
        try s.record(input("一", ["phrase one", "phrase two", "phrase three"]), now: now)
        try s.record(input("二", ["phrase four"]), now: now)
        #expect(try s.dueCards(limit: 10, today: today).count == 2)
        #expect(try s.activatedCount(on: today) == 2)
        let tomorrow = today.adding(days: 1)
        let due = try s.dueCards(limit: 10, today: tomorrow)
        // 明天补入 2 张待加入卡片，今天的 2 张仍到期（未复习）
        #expect(due.count == 4)
        #expect(try s.activatedCount(on: tomorrow) == 2)
    }

    @Test func manualCardIgnoresLimit() throws {
        let s = try makeService(limit: 0)
        guard case .recorded(let id, 0, 1) = try s.record(input("三", ["phrase x"]), now: now) else {
            Issue.record("应进入待加入")
            return
        }
        try s.addManualCard(recordID: id, english: "EN: 三", now: now)
        try s.addManualCard(recordID: id, english: "phrase x", now: now)
        let due = try s.dueCards(limit: 10, today: Day(now))
        #expect(Set(due.map(\.english)) == ["EN: 三", "phrase x"])
    }

    @Test func reviewFlowAndTooEasy() throws {
        let s = try makeService()
        let today = Day(now)
        try s.record(input("四", ["circle back", "requirement", "good"]), now: now)
        var due = try s.dueCards(limit: 10, today: today)
        #expect(due.map(\.english) == ["circle back", "requirement"])  // good 是基础词
        let word = due.first { $0.english == "requirement" }!
        #expect(word.phonetic == "ri'kwaiəmənt")
        #expect(word.chinese == "n. 需求；要求")
        #expect(word.contextZh == "四")

        try s.review(cardID: due[0].id, answer: .remembered, today: today)
        try s.review(cardID: word.id, answer: .tooEasy, today: today)
        due = try s.dueCards(limit: 10, today: today)
        #expect(due.isEmpty)
        #expect(try s.dueCards(limit: 10, today: today.adding(days: 1)).map(\.english) == ["circle back"])

        // 被屏蔽的表达以后不再加入
        try s.record(input("五", ["requirement"]), now: now)
        #expect(try s.dueCards(limit: 10, today: today.adding(days: 1)).map(\.english) == ["circle back"])
    }

    /// 需求 12.1："忘了"的卡片当天重新到期，排在今天其他到期卡片之后，多张按作答先后排列
    @Test func forgottenCardReturnsLaterToday() throws {
        let s = try makeService()
        let today = Day(now)
        try s.record(input("一", ["phrase one", "phrase two", "phrase three"]), now: now)
        var due = try s.dueCards(limit: 10, today: today)
        #expect(due.map(\.english) == ["phrase one", "phrase two", "phrase three"])

        try s.review(cardID: due[1].id, answer: .forgot, today: today, now: now)
        try s.review(cardID: due[0].id, answer: .forgot, today: today, now: now.addingTimeInterval(60))
        due = try s.dueCards(limit: 10, today: today)
        #expect(due.map(\.english) == ["phrase three", "phrase two", "phrase one"])
        #expect(due.allSatisfy { $0.intervalDays == 0 && $0.due == today })
        // 面板底部只取一张时，优先给还没答过的卡片
        #expect(try s.dueCards(limit: 1, today: today).first?.english == "phrase three")

        // 再答"记得"后从 1 天重新开始
        try s.review(cardID: due[1].id, answer: .remembered, today: today, now: now.addingTimeInterval(120))
        #expect(try s.dueCards(limit: 10, today: today).map(\.english) == ["phrase three", "phrase one"])
        #expect(try s.dueCards(limit: 10, today: today.adding(days: 1)).map(\.english).contains("phrase two"))

        // 昨天答过、今天没答的卡片不受影响：第二天回到正常顺序
        let tomorrow = today.adding(days: 1)
        #expect(try s.dueCards(limit: 10, today: tomorrow).map(\.english) == ["phrase one", "phrase three", "phrase two"])
    }

    @Test func frequentExpressionMovesUp() throws {
        let s = try makeService()
        let today = Day(now)
        try s.record(input("a1", ["sync on"]), now: now)
        let card = try s.dueCards(limit: 1, today: today)[0]
        try s.review(cardID: card.id, answer: .remembered, today: today)
        #expect(try s.dueCards(limit: 10, today: today).isEmpty)
        try s.record(input("a2", ["sync on"]), now: now)
        try s.record(input("a3", ["sync on"]), now: now)
        #expect(s.usageCount(for: "Sync on") == 3)
        #expect(try s.dueCards(limit: 10, today: today).first?.english == "sync on")
    }

    @Test func searchFTSAndLike() throws {
        let s = try makeService()
        try s.record(input("这个需求我们下周再对一下", []), now: now)
        try s.record(input("明天开会", [], app: "com.lark"), now: now)
        #expect(try s.search(RecordQuery(keyword: "下周再")).count == 1)
        #expect(try s.search(RecordQuery(keyword: "开会")).count == 1)       // 少于 3 字符走 LIKE
        #expect(try s.search(RecordQuery(keyword: "EN:")).count == 2)
        #expect(try s.search(RecordQuery(keyword: "100%")).isEmpty)
        #expect(try s.search(RecordQuery(appBundleID: "com.lark")).count == 1)
        #expect(try s.search(RecordQuery(from: now.addingTimeInterval(10))).isEmpty)
        #expect(try s.apps().count == 2)
    }

    @Test func deletion() throws {
        let s = try makeService()
        guard case .recorded(let id, _, _) = try s.record(input("删我", ["phrase del"]), now: now) else { return }
        try s.record(input("留着", ["phrase keep"]), now: now.addingTimeInterval(1000))
        try s.deleteRecord(id: id)
        #expect(s.recordCount == 1)
        #expect(try s.dueCards(limit: 10, today: Day(now)).map(\.english) == ["phrase keep"])
        #expect(try s.search(RecordQuery(keyword: "删我")).isEmpty)
        try s.deleteAll()
        #expect(s.recordCount == 0)
        #expect(try s.dueCards(limit: 10, today: Day(now)).isEmpty)
    }

    @Test func deleteRange() throws {
        let s = try makeService()
        try s.record(input("早", []), now: now)
        try s.record(input("晚", []), now: now.addingTimeInterval(86400))
        try s.deleteRecords(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        #expect(try s.search(RecordQuery()).map(\.sourceText) == ["晚"])
    }

    @Test func explanationAndDetail() throws {
        let s = try makeService()
        guard case .recorded(let id, _, _) = try s.record(input("六", ["sync on"]), now: now) else { return }
        try s.attachExplanation(recordID: id, markdown: "- 要点 13812345678")
        let d = try s.detail(recordID: id)!
        #expect(d.explanation == "- 要点 [手机号]")
        #expect(d.expressions.map(\.english) == ["sync on"])
        #expect(d.expressions.first?.cardStatus == "active")
    }

    @Test func transactionRollsBack() throws {
        let db = try AppDatabase(path: nil)
        #expect(throws: (any Error).self) {
            try db.db.transaction {
                try db.db.run("INSERT INTO blocked_expressions VALUES ('x', 1)")
                try db.db.run("INSERT INTO blocked_expressions VALUES ('x', 1)")
            }
        }
        #expect(try db.db.queryOne("SELECT COUNT(*) AS n FROM blocked_expressions")?.int("n") == 0)
    }
}

@Suite struct StorageTests {
    @Test func migratesOnce() throws {
        let path = NSTemporaryDirectory() + "gt-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try AppDatabase(path: path)
        #expect(first.schemaVersion == AppDatabase.migrations.count)
        let second = try AppDatabase(path: path)
        #expect(second.schemaVersion == AppDatabase.migrations.count)
    }

    @Test func usageStats() throws {
        let store = UsageStore(database: try AppDatabase(path: nil))
        let date = Date()
        store.record(providerID: "a", promptTokens: 10, completionTokens: 5, date: date)
        store.record(providerID: "a", promptTokens: 1, completionTokens: 1, date: date)
        store.record(providerID: "b", promptTokens: 2, completionTokens: 2, date: date)
        let u = store.usage(for: date)
        #expect(u.requests == 3)
        #expect(u.totalTokens == 21)
    }
}

@Suite struct ContextSnippetTests {
    @Test func picksSentence() {
        let text = "第一句话。This is where we sync on it. 最后一句"
        #expect(ContextSnippet.sentence(containing: "sync on", in: text) == "This is where we sync on it.")
        #expect(ContextSnippet.sentence(containing: "none", in: "短文本") == "短文本")
    }
}

@Suite struct DictionaryTests {
    @Test func readsSQLiteDictionary() throws {
        let path = NSTemporaryDirectory() + "dict-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let conn = try SQLiteConnection(path: path)
        try conn.execute("CREATE TABLE dict(word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, tag TEXT, frq INTEGER)")
        try conn.run("INSERT INTO dict VALUES (?, ?, ?, ?, ?)", ["apple", "'æpl", "n. 苹果\\nn. 苹果公司", "zk gk", 100])
        let dict = try ECDictionary(path: path)
        let entry = dict.lookup("Apple.")
        #expect(entry?.translation == "n. 苹果；n. 苹果公司")
        #expect(entry?.isBasic == true)
        #expect(dict.lookup("zzz") == nil)
    }
}
