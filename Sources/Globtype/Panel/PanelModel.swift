import Combine
import Foundation
import GlobtypeCore

/// 悬浮面板的界面状态。
@MainActor
final class PanelModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case streaming
        case ready
        case failed(String)
        /// 生成期间原文被修改，等待用户确认（需求 6.7）
        case confirmSourceChanged
    }

    enum ExplanationState: Equatable {
        case hidden
        case loading
        case shown
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var mode: TranslationMode = .translate
    @Published var providerName = ""
    @Published var translation = ""
    @Published var capabilities: ProviderCapabilities = .full
    @Published var notice: String?
    @Published var explanationState: ExplanationState = .hidden
    @Published var explanation = ""
    @Published var frequentHint: String?
    @Published var reviewCard: Card?
    @Published var reviewExpanded = false

    /// 界面操作回调（由 Coordinator 设置）
    var onAccept: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onToggleExplanation: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onReview: ((ReviewAnswer) -> Void)?

    var isReady: Bool { phase == .ready }

    func reset(mode: TranslationMode, providerName: String, capabilities: ProviderCapabilities) {
        phase = .loading
        self.mode = mode
        self.providerName = providerName
        self.capabilities = capabilities
        translation = ""
        notice = capabilities.explanation ? nil : "配置 API Key 可解锁换个说法、讲解与学习卡片"
        explanationState = .hidden
        explanation = ""
        frequentHint = nil
        reviewExpanded = false
    }
}
