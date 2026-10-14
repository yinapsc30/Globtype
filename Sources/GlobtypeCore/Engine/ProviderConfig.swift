import Foundation

public enum ProviderProtocol: String, Codable, Sendable {
    case openAICompatible = "openai"
    case anthropic
}

/// 随 App 打包的服务商预设（providers.json）。
public struct ProviderPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var `protocol`: ProviderProtocol
    /// 本地模型不需要 Key
    public var requiresKey: Bool
    public var note: String?

    public init(id: String, name: String, baseURL: String, model: String,
                protocol: ProviderProtocol, requiresKey: Bool, note: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.protocol = `protocol`
        self.requiresKey = requiresKey
        self.note = note
    }

    public static func load(from data: Data) throws -> [ProviderPreset] {
        try JSONDecoder().decode([ProviderPreset].self, from: data)
    }
}

/// 用户当前的服务商配置（API Key 单独存钥匙串）。
public struct ProviderConfig: Codable, Equatable, Sendable {
    public var presetID: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var `protocol`: ProviderProtocol
    public var requiresKey: Bool

    public init(presetID: String, name: String, baseURL: String, model: String,
                protocol: ProviderProtocol, requiresKey: Bool) {
        self.presetID = presetID
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.protocol = `protocol`
        self.requiresKey = requiresKey
    }

    public init(preset: ProviderPreset) {
        self.init(presetID: preset.id, name: preset.name, baseURL: preset.baseURL,
                  model: preset.model, protocol: preset.protocol, requiresKey: preset.requiresKey)
    }

    /// 拼接接口地址，容忍用户填写时多带或少带末尾斜杠。
    public func endpoint(path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http", url.host != nil else {
            throw ProviderError.invalidConfiguration("接口地址无效")
        }
        return url
    }
}
