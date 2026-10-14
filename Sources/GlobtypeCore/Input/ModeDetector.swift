import Foundation

/// 翻译模式（需求 4.1~4.3）。
public enum TranslationMode: String, Codable, Sendable {
    /// 中文或中英混写 → 英文
    case translate
    /// 英文 → 润色后的英文
    case polish

    public var displayName: String {
        switch self {
        case .translate: return "翻译"
        case .polish: return "润色"
        }
    }
}

public enum ModeDetector {
    /// CJK 字符占"CJK + 拉丁字母"的比例达到该值即判为翻译模式。
    public static let cjkRatioThreshold = 0.1

    // 这些片段不参与判定：URL、邮箱、@提及、#话题、反引号代码
    private static let ignoredPatterns: [NSRegularExpression] = [
        #"`[^`]*`"#,
        #"https?://\S+"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"@[\w.-]+"#,
        #"#[\w-]+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func detect(_ text: String) -> TranslationMode {
        let cleaned = stripIgnored(text)
        var cjk = 0
        var latin = 0
        for scalar in cleaned.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                latin += 1
            }
        }
        let total = cjk + latin
        // 没有任何文字（只有链接、数字、符号）时按翻译处理，模型会原样保留
        guard total > 0 else { return .translate }
        return Double(cjk) / Double(total) >= cjkRatioThreshold ? .translate : .polish
    }

    static func stripIgnored(_ text: String) -> String {
        var result = text
        for regex in ignoredPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        return result
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF,   // 基本区
             0x3400...0x4DBF,   // 扩展 A
             0x20000...0x2A6DF, // 扩展 B
             0xF900...0xFAFF:   // 兼容区
            return true
        default:
            return false
        }
    }
}
