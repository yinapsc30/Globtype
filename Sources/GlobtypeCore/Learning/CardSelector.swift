import Foundation

/// 从模型返回的表达中筛选候选复习卡片（需求 10.1~10.3、10.5）。
public enum CardSelector {
    public static let maxPerRecord = 3
    public static let maxLength = 60

    public static func select(_ expressions: [ExtractedExpression],
                              dictionary: WordLookup,
                              isBlocked: (String) -> Bool) -> [ExtractedExpression] {
        var seen = Set<String>()
        var result: [ExtractedExpression] = []
        for item in expressions {
            let key = Normalizer.normalizeExpression(item.en)
            guard !key.isEmpty, key.count <= maxLength, !seen.contains(key), !isBlocked(key) else { continue }
            // 单词且是中考/高考词汇：跳过
            let isSingleWord = !key.contains(" ")
            if isSingleWord, let entry = dictionary.lookup(key), entry.isBasic { continue }
            seen.insert(key)
            // 模型标错类型时按实际是否含空格纠正
            var fixed = item
            fixed.type = isSingleWord ? .word : .phrase
            result.append(fixed)
        }
        // 短语优先，保持原有相对顺序
        let phrases = result.filter { $0.type == .phrase }
        let words = result.filter { $0.type == .word }
        return Array((phrases + words).prefix(maxPerRecord))
    }
}
