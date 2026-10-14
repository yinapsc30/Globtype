import Foundation

/// 辅助功能接口的范围以 UTF-16 编码单元计数。这里集中处理与 Swift String 的转换，
/// 避免 emoji、中文等字符导致错位（正确性属性 8）。
public enum UTF16Range {
    public static func length(of text: String) -> Int {
        (text as NSString).length
    }

    /// 把 NSRange 转为 String 范围；越界或切在代理对中间时返回 nil。
    /// （系统的 `Range(_:in:)` 会静默向下取整到字符边界，这里显式拒绝。）
    public static func stringRange(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location + range.length <= length(of: text) else { return nil }
        let utf16 = text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: range.location)
        let upper = utf16.index(lower, offsetBy: range.length)
        guard let l = lower.samePosition(in: text.unicodeScalars),
              let u = upper.samePosition(in: text.unicodeScalars) else { return nil }
        return l..<u
    }

    /// 返回范围内的子串；范围无效时返回 nil。
    public static func substring(of text: String, range: NSRange) -> String? {
        stringRange(range, in: text).map { String(text.unicodeScalars[$0]) }
    }

    /// 用 replacement 替换范围内的内容；范围无效时返回 nil。
    public static func replacing(in text: String, range: NSRange, with replacement: String) -> String? {
        guard let r = stringRange(range, in: text) else { return nil }
        var scalars = text.unicodeScalars
        scalars.replaceSubrange(r, with: replacement.unicodeScalars)
        return String(scalars)
    }

    public static func fullRange(of text: String) -> NSRange {
        NSRange(location: 0, length: length(of: text))
    }
}
