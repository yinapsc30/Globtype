import AppKit
import GlobtypeCore
import os

/// 应用级服务容器：数据库、学习服务、服务商预设。
@MainActor
final class AppServices: ObservableObject {
    let settings: SettingsStore
    let learning: LearningService?
    let usage: UsageStore?
    let presets: [ProviderPreset]
    let dictionaryAvailable: Bool
    /// 数据库打开或写入失败时给出提示（设计：错误处理）
    @Published var storageError: String?
    /// 学习数据变化时递增，界面据此刷新
    @Published private(set) var revision = 0

    private let log = Logger(subsystem: "app.globtype", category: "services")

    init(settings: SettingsStore) {
        self.settings = settings
        presets = Self.loadPresets()

        let dictionary: WordLookup
        if let path = Bundle.main.path(forResource: "dictionary", ofType: "sqlite"),
           let dict = try? ECDictionary(path: path) {
            dictionary = dict
            dictionaryAvailable = true
        } else {
            dictionary = EmptyDictionary()
            dictionaryAvailable = false
        }

        do {
            let db = try AppDatabase(path: AppDatabase.defaultPath())
            learning = LearningService(database: db, dictionary: dictionary)
            usage = UsageStore(database: db)
        } catch {
            learning = nil
            usage = nil
            storageError = "无法打开本地数据库，表达库与复习暂不可用"
            log.error("数据库打开失败")
        }
        applySettings()
    }

    func applySettings() {
        learning?.noRecordBundleIDs = Set(settings.noRecordBundleIDs)
        learning?.dailyNewLimit = settings.dailyNewLimit
    }

    static func loadPresets() -> [ProviderPreset] {
        guard let url = Bundle.main.url(forResource: "providers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? ProviderPreset.load(from: data) else { return [] }
        return presets
    }

    /// 当前服务商；未配置时使用 Apple 翻译（需求 7.5）。
    func makeProvider() -> TranslationProvider {
        guard let config = settings.provider else { return AppleTranslationProvider() }
        let usage = self.usage
        return LLMProvider(config: config, apiKey: KeychainStore.key(for: config.presetID)) { id, p, c in
            usage?.record(providerID: id, promptTokens: p, completionTokens: c)
        }
    }

    // MARK: - 学习

    func record(_ input: RecordInput) {
        guard let learning else { return }
        applySettings()
        do {
            try learning.record(input)
            revision += 1
        } catch {
            // 写入失败不影响回填（需求：错误处理）
            storageError = "保存到表达库失败"
            log.error("记录写入失败")
        }
    }

    func nextReviewCard() -> Card? {
        applySettings()
        return (try? learning?.dueCards(limit: 1))?.first
    }

    func dueCount() -> Int {
        applySettings()
        return learning?.dueCount() ?? 0
    }

    func review(cardID: Int64, answer: ReviewAnswer) {
        try? learning?.review(cardID: cardID, answer: answer)
        revision += 1
    }

    /// 查询次数达到阈值的表达，返回提示文案（需求 12.8）。
    func frequentHint(for expressions: [ExtractedExpression]) -> String? {
        guard let learning else { return nil }
        let counts = expressions.map { ($0.en, learning.usageCount(for: $0.en)) }
        // 本次尚未记录，所以已有次数 + 1 才是算上这次的总次数
        guard let top = counts.max(by: { $0.1 < $1.1 }), top.1 + 1 >= LearningService.frequentThreshold else { return nil }
        return "“\(top.0)”你已经查过 \(top.1 + 1) 次了，试试自己写？"
    }

    func notifyChanged() {
        revision += 1
    }
}
