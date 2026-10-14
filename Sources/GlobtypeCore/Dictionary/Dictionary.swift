import Foundation

public struct DictEntry: Equatable, Sendable {
    public var word: String
    public var phonetic: String?
    public var translation: String
    /// ECDICT 考试标签，如 zk gk cet4 cet6 ky toefl ielts gre
    public var tags: Set<String>

    public init(word: String, phonetic: String?, translation: String, tags: Set<String>) {
        self.word = word
        self.phonetic = phonetic
        self.translation = translation
        self.tags = tags
    }

    /// 中考或高考词汇视为基础词（需求 10.3）。
    public var isBasic: Bool { tags.contains("zk") || tags.contains("gk") }
}

public protocol WordLookup: Sendable {
    func lookup(_ word: String) -> DictEntry?
}

/// 基于 ECDICT 精简版 SQLite 的只读词典（由 Scripts/build_dictionary.py 生成）。
/// 表结构：dict(word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, tag TEXT, frq INTEGER)
public final class ECDictionary: WordLookup, @unchecked Sendable {
    private let db: SQLiteConnection

    public init(path: String) throws {
        db = try SQLiteConnection(readOnlyPath: path)
    }

    public func lookup(_ word: String) -> DictEntry? {
        let key = Self.normalizeKey(word)
        guard !key.isEmpty,
              let row = try? db.queryOne("SELECT word, phonetic, translation, tag FROM dict WHERE word = ? COLLATE NOCASE LIMIT 1", [key])
        else { return nil }
        let phonetic = row.optionalString("phonetic").flatMap { $0.isEmpty ? nil : $0 }
        let tags = Set(row.string("tag").split(separator: " ").map(String.init))
        return DictEntry(word: row.string("word"), phonetic: phonetic,
                         translation: Self.cleanTranslation(row.string("translation")), tags: tags)
    }

    static func normalizeKey(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// ECDICT 的释义用 \n 分隔多行，这里合并为一行并限制长度。
    static func cleanTranslation(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\\n", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.prefix(3).joined(separator: "；")
        return joined.count > 80 ? String(joined.prefix(80)) + "…" : joined
    }
}

/// 词典文件缺失时的降级实现：查不到任何词，基础词过滤失效（设计：错误处理）。
public struct EmptyDictionary: WordLookup {
    public init() {}
    public func lookup(_ word: String) -> DictEntry? { nil }
}
