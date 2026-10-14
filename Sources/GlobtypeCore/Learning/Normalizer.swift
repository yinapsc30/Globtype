import Foundation

/// 文本归一化，用于表达库去重（需求 9.4）。满足幂等性（正确性属性 5）。
public enum Normalizer {
    static let punctuationMap: [Character: Character] = [
        "，": ",", "。": ".", "！": "!", "？": "?", "；": ";", "：": ":",
        "（": "(", "）": ")", "【": "[", "】": "]", "、": ",",
        "“": "\"", "”": "\"", "‘": "'", "’": "'", "《": "<", "》": ">",
        "…": ".", "—": "-", "～": "~", "·": ".",
    ]

    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for ch in text {
            var c = ch
            if let mapped = punctuationMap[c] {
                c = mapped
            } else if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 {
                // 全角 ASCII（U+FF01~U+FF5E）转半角，全角空格转半角空格
                if (0xFF01...0xFF5E).contains(scalar.value), let half = Unicode.Scalar(scalar.value - 0xFEE0) {
                    c = Character(half)
                } else if scalar.value == 0x3000 {
                    c = " "
                }
            }
            if c.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 英文表达的归一化：小写、合并空白、去掉首尾标点。
    public static func normalizeExpression(_ text: String) -> String {
        let base = normalize(text).lowercased()
        let trimSet = CharacterSet.punctuationCharacters.union(.whitespaces).subtracting(CharacterSet(charactersIn: "'-"))
        return base.trimmingCharacters(in: trimSet)
    }
}
