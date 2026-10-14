import Foundation

/// 模型从一次翻译中提取的学习表达。
public struct ExtractedExpression: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case phrase, word }

    public var en: String
    public var zh: String
    public var type: Kind

    public init(en: String, zh: String, type: Kind) {
        self.en = en
        self.zh = zh
        self.type = type
    }

    private enum CodingKeys: String, CodingKey { case en, zh, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        en = try c.decode(String.self, forKey: .en)
        zh = (try? c.decode(String.self, forKey: .zh)) ?? ""
        let raw = (try? c.decode(String.self, forKey: .type)) ?? ""
        // 模型偶尔不给 type，按是否含空格推断
        type = Kind(rawValue: raw) ?? (en.contains(" ") ? .phrase : .word)
    }
}

public struct ProviderCapabilities: Equatable, Sendable {
    public var streaming: Bool
    public var regenerate: Bool
    public var explanation: Bool
    public var expressions: Bool
    public var polish: Bool

    public static let full = ProviderCapabilities(streaming: true, regenerate: true, explanation: true, expressions: true, polish: true)
    public static let translationOnly = ProviderCapabilities(streaming: false, regenerate: false, explanation: false, expressions: false, polish: false)
}

public struct TranslateRequest: Sendable {
    public var sourceText: String
    public var mode: TranslationMode
    /// 重新生成时传入上一版译文，要求给出不同表述
    public var previousTranslation: String?

    public init(sourceText: String, mode: TranslationMode, previousTranslation: String? = nil) {
        self.sourceText = sourceText
        self.mode = mode
        self.previousTranslation = previousTranslation
    }
}

public struct ExplainRequest: Sendable {
    public var sourceText: String
    public var translation: String
    public var mode: TranslationMode

    public init(sourceText: String, translation: String, mode: TranslationMode) {
        self.sourceText = sourceText
        self.translation = translation
        self.mode = mode
    }
}

public enum TranslateEvent: Equatable, Sendable {
    case translationDelta(String)
    case translationDone(String)
    case expressions([ExtractedExpression])
    case usage(promptTokens: Int, completionTokens: Int)
}

public protocol TranslationProvider: Sendable {
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    func translate(_ request: TranslateRequest) -> AsyncThrowingStream<TranslateEvent, Error>
    func explain(_ request: ExplainRequest) -> AsyncThrowingStream<String, Error>
    func testConnection() async throws
}

/// 翻译服务商错误，`message` 为面向用户的中文说明（需求 4.9）。
public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case invalidKey
    case insufficientBalance
    case rateLimited
    case notFound
    case serverUnavailable(Int)
    case httpStatus(Int)
    case network
    case timeout
    case missingAPIKey
    case invalidConfiguration(String)
    case emptyResponse
    case unsupported(String)

    public var message: String {
        switch self {
        case .invalidKey: return "API Key 无效或无权限"
        case .insufficientBalance: return "账户余额不足"
        case .rateLimited: return "请求太频繁，请稍后重试"
        case .notFound: return "接口地址或模型名不正确"
        case .serverUnavailable(let code): return "服务商暂时不可用（\(code)）"
        case .httpStatus(let code): return "请求失败（HTTP \(code)）"
        case .network: return "网络不可达，请检查网络或代理"
        case .timeout: return "请求超时"
        case .missingAPIKey: return "尚未填写 API Key"
        case .invalidConfiguration(let s): return "配置有误：\(s)"
        case .emptyResponse: return "服务商没有返回内容"
        case .unsupported(let s): return s
        }
    }

    public var errorDescription: String? { message }

    /// 按设计文档的错误映射表，把 HTTP 状态码和响应体映射为错误。
    public static func from(status: Int, body: String) -> ProviderError {
        let lower = body.lowercased()
        if status == 402 || lower.contains("insufficient") || lower.contains("balance") || lower.contains("quota") {
            return .insufficientBalance
        }
        switch status {
        case 401, 403: return .invalidKey
        case 404: return .notFound
        case 429: return .rateLimited
        case 500...599: return .serverUnavailable(status)
        default: return .httpStatus(status)
        }
    }

    public static func from(urlError: Error) -> ProviderError {
        if let e = urlError as? ProviderError { return e }
        if let e = urlError as? URLError {
            if e.code == .timedOut { return .timeout }
            return .network
        }
        return .network
    }
}
