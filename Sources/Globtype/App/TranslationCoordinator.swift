import AppKit
import Carbon
import GlobtypeCore
import os

/// 编排一次翻译会话（设计：TranslationCoordinator 状态机）。
@MainActor
final class TranslationCoordinator {
    static let maxSourceLength = 5000

    private let settings: SettingsStore
    private let bridge = TextBridge()
    private let panel: PanelController
    private let toast = ToastController()
    private let services: AppServices
    private let log = Logger(subsystem: "app.globtype", category: "coordinator")

    private var snapshot: SourceSnapshot?
    private var provider: TranslationProvider?
    private var expressions: [ExtractedExpression] = []
    private var generationTask: Task<Void, Never>?
    private var explanationTask: Task<Void, Never>?
    private var isBusy = false
    private var isAccepting = false
    private var confirmedSourceChange = false

    var isPanelVisible: Bool { panel.isVisible }

    init(settings: SettingsStore, services: AppServices) {
        self.settings = settings
        self.services = services
        panel = PanelController()
        let model = panel.model
        model.onAccept = { [weak self] in self?.accept(record: true) }
        model.onRegenerate = { [weak self] in self?.regenerate() }
        model.onToggleExplanation = { [weak self] in self?.toggleExplanation() }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onReview = { [weak self] in self?.answerReview($0) }
    }

    // MARK: - 触发

    func trigger() {
        guard settings.isEnabled else { return }
        if panel.isVisible {
            // 面板可见时再次双击 Shift：重新生成（需求 5.7）
            regenerate()
            return
        }
        guard !isBusy else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let bundleID = app.bundleIdentifier ?? ""
        guard !settings.isExcluded(bundleID) else { return }
        // 安全输入开启时不读取任何文本（需求 2.2）
        guard !IsSecureEventInputEnabled() else {
            log.info("安全输入开启，忽略")
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            await start()
        }
    }

    private func start() async {
        let snapshot: SourceSnapshot
        do {
            snapshot = try await bridge.readSource()
        } catch TextBridgeError.secureField {
            return
        } catch {
            toast.show("无法读取当前输入框")
            return
        }
        let text = snapshot.sourceText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toast.show("没有可翻译的内容", caret: snapshot.caretRect, element: snapshot.elementRect)
            return
        }
        if text.count > Self.maxSourceLength {
            toast.show("文本过长（超过 \(Self.maxSourceLength) 字），请分段翻译", caret: snapshot.caretRect, element: snapshot.elementRect)
            return
        }
        if settings.diagnosticsMode {
            await runDiagnostics(snapshot)
            return
        }

        self.snapshot = snapshot
        confirmedSourceChange = false
        expressions = []
        let provider = services.makeProvider()
        self.provider = provider
        let mode = ModeDetector.detect(text)
        panel.model.reset(mode: mode, providerName: provider.displayName, capabilities: provider.capabilities)
        panel.model.reviewCard = services.nextReviewCard()
        panel.show(caret: snapshot.caretRect, element: snapshot.elementRect)
        generate(previous: nil)
    }

    private func generate(previous: String?) {
        guard let snapshot, let provider else { return }
        generationTask?.cancel()
        explanationTask?.cancel()
        let model = panel.model
        let request = TranslateRequest(sourceText: snapshot.sourceText, mode: model.mode, previousTranslation: previous)
        model.phase = .loading
        model.translation = ""
        model.explanation = ""
        model.explanationState = .hidden
        model.frequentHint = nil
        expressions = []
        generationTask = Task { [weak self] in
            do {
                for try await event in provider.translate(request) {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .translationDelta(let delta):
                        model.translation += delta
                        model.phase = .streaming
                    case .translationDone(let text):
                        model.translation = text
                        model.phase = .ready
                    case .expressions(let list):
                        self.expressions = list
                        model.frequentHint = self.services.frequentHint(for: list)
                    case .usage:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? ProviderError)?.message ?? "翻译失败"
                model.phase = .failed(message)
            }
        }
    }

    // MARK: - 面板操作

    /// 面板可见时由事件监听同步调用；返回 true 表示吞掉按键（需求 5.10）。
    func handlePanelKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard panel.isVisible else { return false }
        let model = panel.model
        let hasCommand = flags.contains(.maskCommand)
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        switch keyCode {
        case 36, 76: // Return / 小键盘 Enter
            if model.phase == .confirmSourceChanged {
                confirmedSourceChange = true
                accept(record: !hasOption)
            } else if model.isReady {
                accept(record: !hasOption)
            }
            // 未完成时也吞掉，避免聊天软件把原文直接发出去
            return true
        case 53: // Esc
            dismiss()
            return true
        case 48 where !hasCommand && !hasControl: // Tab
            if model.isReady { toggleExplanation() }
            return true
        case 15 where !hasCommand && !hasOption && !hasControl: // R
            regenerate()
            return true
        case 8 where hasCommand: // ⌘C
            if model.isReady {
                ClipboardService.writePersistent(model.translation)
                dismiss()
            }
            return true
        default:
            // 其他按键：关闭面板并照常传给目标 App
            dismiss()
            return false
        }
    }

    func handleMouseDown(at point: NSPoint) {
        guard panel.isVisible, !panel.frame.contains(point) else { return }
        dismiss()
    }

    func regenerate() {
        guard panel.isVisible, let provider else { return }
        let model = panel.model
        switch model.phase {
        case .failed:
            generate(previous: nil)
        case .ready, .streaming:
            guard provider.capabilities.regenerate else { return }
            generate(previous: model.translation.isEmpty ? nil : model.translation)
        default:
            break
        }
    }

    func toggleExplanation() {
        guard let provider, provider.capabilities.explanation, let snapshot else { return }
        let model = panel.model
        switch model.explanationState {
        case .hidden:
            if !model.explanation.isEmpty {
                model.explanationState = .shown
                return
            }
            model.explanationState = .loading
            // 讲解只在按 Tab 后请求（需求 11.2）
            let request = ExplainRequest(sourceText: snapshot.sourceText, translation: model.translation, mode: model.mode)
            explanationTask = Task {
                do {
                    for try await chunk in provider.explain(request) {
                        guard !Task.isCancelled else { return }
                        model.explanation += chunk
                    }
                    if model.explanationState == .loading { model.explanationState = .shown }
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled else { return }
                    model.explanation = ""
                    model.explanationState = .failed((error as? ProviderError)?.message ?? "讲解生成失败")
                }
            }
        case .loading, .shown, .failed:
            model.explanationState = .hidden
        }
    }

    func accept(record: Bool) {
        guard let snapshot, panel.isVisible else { return }
        let model = panel.model
        guard model.isReady || model.phase == .confirmSourceChanged, !isAccepting else { return }
        // 在"原文已变化"提示下确认（Enter 或点击按钮）即视为用户同意替换
        if model.phase == .confirmSourceChanged { confirmedSourceChange = true }
        isAccepting = true
        let translation = model.translation
        let explanation = model.explanation.isEmpty || model.explanationState == .loading ? nil : model.explanation
        let mode = model.mode
        let expressions = self.expressions
        Task {
            defer { isAccepting = false }
            if !confirmedSourceChange, await bridge.hasChanged(since: snapshot) {
                model.phase = .confirmSourceChanged
                return
            }
            finishSession(hidePanel: true)
            let result = await bridge.replace(snapshot, with: translation)
            if result == .fallbackCopied {
                toast.show("已复制到剪贴板，请手动粘贴", caret: snapshot.caretRect, element: snapshot.elementRect)
            }
            guard record else { return }
            services.record(RecordInput(sourceText: snapshot.sourceText, translation: translation, mode: mode,
                                        appBundleID: snapshot.appBundleID, appName: snapshot.appName,
                                        expressions: expressions, explanation: explanation))
        }
    }

    func dismiss() {
        finishSession(hidePanel: true)
    }

    private func finishSession(hidePanel: Bool) {
        generationTask?.cancel()
        explanationTask?.cancel()
        generationTask = nil
        explanationTask = nil
        if hidePanel { panel.hide() }
        snapshot = nil
        provider = nil
        confirmedSourceChange = false
    }

    private func answerReview(_ answer: ReviewAnswer) {
        guard let card = panel.model.reviewCard else { return }
        services.review(cardID: card.id, answer: answer)
        panel.model.reviewCard = nil
    }

    // MARK: - 诊断模式（任务 3.6）

    private func runDiagnostics(_ snapshot: SourceSnapshot) async {
        let result = await bridge.replace(snapshot, with: "[GT] " + snapshot.sourceText)
        let resultText: String
        switch result {
        case .verified(let m): resultText = "已校验（\(m.rawValue)）"
        case .unverified(let m): resultText = "未校验（\(m.rawValue)）"
        case .fallbackCopied: resultText = "失败，已复制到剪贴板"
        }
        DiagnosticsLog.shared.add(.init(app: snapshot.appName, bundleID: snapshot.appBundleID,
                                        readMethod: snapshot.method.rawValue, scope: snapshot.scope.rawValue,
                                        sourceLength: snapshot.sourceText.count, caretAvailable: snapshot.caretRect != nil,
                                        elementRectAvailable: snapshot.elementRect != nil, replaceResult: resultText,
                                        manualAccessibility: snapshot.enabledManualAccessibility))
        toast.show("诊断：\(snapshot.method.rawValue) · \(resultText)", caret: snapshot.caretRect, element: snapshot.elementRect)
    }
}
