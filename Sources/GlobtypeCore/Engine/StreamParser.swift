import Foundation

/// 解析模型的流式输出：分隔符之前是译文，之后是表达 JSON。
///
/// ```
/// Let's sync on this requirement next week.
/// <<<GLOBTYPE_EXPRESSIONS>>>
/// [{"en":"sync on","zh":"对齐","type":"phrase"}]
/// ```
///
/// 正确性属性 2：无论输入如何切分，拼接出的译文与一次性解析的结果相同，且不含分隔符。
public struct StreamParser: Sendable {
    public static let separator = "<<<GLOBTYPE_EXPRESSIONS>>>"

    private var pending = ""          // 尚未确认不是分隔符前缀的尾部
    private var emitted = ""          // 已作为增量发出的原始译文
    private var tail = ""             // 分隔符之后的内容
    private var foundSeparator = false
    private var emittedLeadingContent = false

    public init() {}

    /// 送入一段模型输出，返回可以立即显示的译文增量（可能为空）。
    public mutating func feed(_ chunk: String) -> String {
        if foundSeparator {
            tail += chunk
            return ""
        }
        pending += chunk
        if let r = pending.range(of: Self.separator) {
            let before = String(pending[..<r.lowerBound])
            tail = String(pending[r.upperBound...])
            pending = ""
            foundSeparator = true
            return emit(before)
        }
        // 保留末尾可能是分隔符前缀的部分
        let keep = Self.longestSeparatorPrefixSuffix(of: pending)
        let splitIndex = pending.index(pending.endIndex, offsetBy: -keep)
        let ready = String(pending[..<splitIndex])
        pending = String(pending[splitIndex...])
        return emit(ready)
    }

    /// 流结束时调用，返回最终译文和表达列表。
    public mutating func finish() -> (translation: String, expressions: [ExtractedExpression]) {
        if !foundSeparator {
            emitted += pending
            pending = ""
        }
        let translation = Self.cleanTranslation(emitted)
        let expressions = Self.parseExpressions(tail)
        return (translation, expressions)
    }

    /// 流式显示时去掉开头的空白与代码块标记，避免面板顶部出现空行。
    private mutating func emit(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        emitted += s
        if emittedLeadingContent { return s }
        // 在出现首个非空白内容之前，逐步从已发出的内容中计算可显示部分
        let stripped = Self.stripLeadingFence(emitted)
        let trimmed = String(stripped.drop(while: { $0.isWhitespace }))
        if trimmed.isEmpty { return "" }
        emittedLeadingContent = true
        return trimmed
    }

    static func longestSeparatorPrefixSuffix(of s: String) -> Int {
        let sep = Array(separator)
        let chars = Array(s.suffix(sep.count - 1))
        var best = 0
        for len in stride(from: min(chars.count, sep.count - 1), through: 1, by: -1) {
            if Array(chars.suffix(len)) == Array(sep.prefix(len)) {
                best = len
                break
            }
        }
        return best
    }

    static func stripLeadingFence(_ s: String) -> String {
        let trimmed = s.drop(while: { $0.isWhitespace })
        guard trimmed.hasPrefix("```") else { return s }
        // 去掉 ``` 或 ```text 这一整行；如果这一行还没收完，暂时视为空
        guard let newline = trimmed.firstIndex(of: "\n") else { return "" }
        return String(trimmed[trimmed.index(after: newline)...])
    }

    public static func cleanTranslation(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let newline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: newline)...])
            } else {
                s = ""
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseExpressions(_ raw: String) -> [ExtractedExpression] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 容忍 ```json 包裹或前后多余文字：截取第一个 [ 到最后一个 ]
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end else { return [] }
        s = String(s[start...end])
        guard let data = s.data(using: .utf8),
              let list = try? JSONDecoder().decode([ExtractedExpression].self, from: data) else { return [] }
        return list
            .map { ExtractedExpression(en: $0.en.trimmingCharacters(in: .whitespacesAndNewlines),
                                       zh: $0.zh.trimmingCharacters(in: .whitespacesAndNewlines),
                                       type: $0.type) }
            .filter { !$0.en.isEmpty }
    }
}
