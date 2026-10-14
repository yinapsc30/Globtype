import Foundation

/// 应用数据库：建表与迁移。时间统一存 Unix 秒，复习日期存本地日期字符串 yyyy-MM-dd。
public final class AppDatabase: @unchecked Sendable {
    public let db: SQLiteConnection

    public init(path: String?) throws {
        db = try SQLiteConnection(path: path)
        try migrate()
    }

    /// 默认位置：~/Library/Application Support/Globtype/globtype.sqlite
    public static func defaultPath() throws -> String {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Globtype", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("globtype.sqlite").path
    }

    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_text TEXT NOT NULL,
            source_normalized TEXT NOT NULL UNIQUE,
            translation TEXT NOT NULL,
            mode TEXT NOT NULL,
            explanation TEXT,
            app_bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX records_updated ON records(updated_at);
        CREATE INDEX records_app ON records(app_bundle_id);

        CREATE TABLE expressions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            english_normalized TEXT NOT NULL UNIQUE,
            english TEXT NOT NULL,
            chinese TEXT NOT NULL,
            type TEXT NOT NULL,
            phonetic TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE record_expressions (
            record_id INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE,
            expression_id INTEGER NOT NULL REFERENCES expressions(id) ON DELETE CASCADE,
            context_zh TEXT NOT NULL,
            context_en TEXT NOT NULL,
            PRIMARY KEY (record_id, expression_id)
        );

        CREATE TABLE cards (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            expression_id INTEGER NOT NULL UNIQUE REFERENCES expressions(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            interval_days INTEGER NOT NULL DEFAULT 0,
            due_date TEXT NOT NULL,
            review_count INTEGER NOT NULL DEFAULT 0,
            activated_date TEXT,
            manual INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX cards_status_due ON cards(status, due_date);

        CREATE TABLE blocked_expressions (
            english_normalized TEXT PRIMARY KEY,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE usage_stats (
            month TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            request_count INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (month, provider_id)
        );

        CREATE VIRTUAL TABLE records_fts USING fts5(
            source_text, translation, content='records', content_rowid='id', tokenize='trigram'
        );
        CREATE TRIGGER records_ai AFTER INSERT ON records BEGIN
            INSERT INTO records_fts(rowid, source_text, translation) VALUES (new.id, new.source_text, new.translation);
        END;
        CREATE TRIGGER records_ad AFTER DELETE ON records BEGIN
            INSERT INTO records_fts(records_fts, rowid, source_text, translation) VALUES ('delete', old.id, old.source_text, old.translation);
        END;
        CREATE TRIGGER records_au AFTER UPDATE ON records BEGIN
            INSERT INTO records_fts(records_fts, rowid, source_text, translation) VALUES ('delete', old.id, old.source_text, old.translation);
            INSERT INTO records_fts(rowid, source_text, translation) VALUES (new.id, new.source_text, new.translation);
        END;
        """,
        // v2：按天统计，只记次数不含文本（需求 16.7）
        """
        CREATE TABLE daily_stats (
            day TEXT PRIMARY KEY,
            translations INTEGER NOT NULL DEFAULT 0,
            reviews INTEGER NOT NULL DEFAULT 0,
            new_cards INTEGER NOT NULL DEFAULT 0
        );
        """,
        // v3：最后一次复习时间，用于把当天"忘了"的卡片排到队列末尾（需求 12.1）
        """
        ALTER TABLE cards ADD COLUMN last_reviewed_at INTEGER;
        """,
    ]

    func migrate() throws {
        let current = Int(try db.queryOne("PRAGMA user_version")?.int("user_version") ?? 0)
        guard current < Self.migrations.count else { return }
        for version in current..<Self.migrations.count {
            try db.transaction {
                try db.execute(Self.migrations[version])
                try db.execute("PRAGMA user_version = \(version + 1)")
            }
        }
    }

    public var schemaVersion: Int {
        Int((try? db.queryOne("PRAGMA user_version")?.int("user_version")) ?? 0)
    }
}

/// 用量统计（需求 7.8）。
public final class UsageStore: @unchecked Sendable {
    let db: SQLiteConnection

    public init(database: AppDatabase) {
        db = database.db
    }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public func record(providerID: String, promptTokens: Int, completionTokens: Int, date: Date = Date()) {
        _ = try? db.run("""
            INSERT INTO usage_stats(month, provider_id, request_count, prompt_tokens, completion_tokens)
            VALUES (?, ?, 1, ?, ?)
            ON CONFLICT(month, provider_id) DO UPDATE SET
                request_count = request_count + 1,
                prompt_tokens = prompt_tokens + excluded.prompt_tokens,
                completion_tokens = completion_tokens + excluded.completion_tokens
            """, [Self.monthKey(for: date), providerID, promptTokens, completionTokens])
    }

    public struct MonthlyUsage: Equatable, Sendable {
        public var requests: Int
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int { promptTokens + completionTokens }

        public init(requests: Int, promptTokens: Int, completionTokens: Int) {
            self.requests = requests
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
        }
    }

    /// 本月全部服务商的合计。
    public func usage(for date: Date = Date()) -> MonthlyUsage {
        let row = try? db.queryOne("""
            SELECT COALESCE(SUM(request_count),0) AS r, COALESCE(SUM(prompt_tokens),0) AS p,
                   COALESCE(SUM(completion_tokens),0) AS c FROM usage_stats WHERE month = ?
            """, [Self.monthKey(for: date)])
        return MonthlyUsage(requests: Int(row?.int("r") ?? 0), promptTokens: Int(row?.int("p") ?? 0),
                            completionTokens: Int(row?.int("c") ?? 0))
    }
}
