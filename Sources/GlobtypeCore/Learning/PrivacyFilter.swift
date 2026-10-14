import Foundation

/// 写入表达库前替换敏感信息（需求 9.3）。
/// 正确性属性 3：filter 幂等，结果中不再匹配任何规则；属性 4：普通文本保持不变。
public enum PrivacyFilter {
    public static let emailPlaceholder = "[邮箱]"
    public static let idCardPlaceholder = "[身份证号]"
    public static let bankCardPlaceholder = "[银行卡号]"
    public static let phonePlaceholder = "[手机号]"

    private static let email = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#)
    // 18 位身份证号：前后不紧邻数字
    private static let idCard = try! NSRegularExpression(
        pattern: #"(?<![0-9])[1-9][0-9]{5}(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9A-Za-z])"#)
    // 16~19 位数字，允许每 4 位用空格或短横分隔
    private static let bankCard = try! NSRegularExpression(
        pattern: #"(?<![0-9])[0-9]{4}(?:[ -]?[0-9]){12,15}(?![0-9])"#)
    private static let phone = try! NSRegularExpression(
        pattern: #"(?<![0-9])(?:\+?86[ -]?)?1[3-9][0-9](?:[ -]?[0-9]){8}(?![0-9])"#)

    public static func filter(_ text: String) -> String {
        var result = text
        result = replace(email, in: result, with: emailPlaceholder)
        result = replace(idCard, in: result, with: idCardPlaceholder)
        result = replace(bankCard, in: result, with: bankCardPlaceholder) { luhnValid($0) }
        result = replace(phone, in: result, with: phonePlaceholder)
        return result
    }

    /// 是否包含任何敏感信息（用于测试与校验）。
    public static func containsSensitive(_ text: String) -> Bool {
        filter(text) != text
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with placeholder: String,
                                where predicate: ((String) -> Bool)? = nil) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        // 从后往前替换，避免范围偏移
        for match in matches.reversed() {
            let candidate = ns.substring(with: match.range)
            if let predicate, !predicate(candidate) { continue }
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: placeholder)
            }
        }
        return result
    }

    public static func luhnValid(_ raw: String) -> Bool {
        let digits = raw.compactMap { $0.wholeNumberValue }
        guard (16...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
