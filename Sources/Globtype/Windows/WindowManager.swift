import AppKit
import SwiftUI

/// 管理学习中心、设置、引导、诊断窗口。
/// 有任一窗口打开时在程序坞显示图标，全部关闭后隐藏（需求 15.4）。
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    var settings: SettingsStore!
    var services: AppServices!
    let learningCenter = LearningCenterState()

    private var windows: [String: NSWindow] = [:]

    // MARK: - 学习中心（需求 15.2）

    func showLearningCenter(_ section: LearningCenterState.Section? = nil) {
        if let section { learningCenter.open(section) }
        show(id: "learning", title: "Globtype 学习中心", resizable: true, autosave: "LearningCenter") {
            LearningCenterView(state: self.learningCenter, services: self.services)
        }
    }

    func showReview() { showLearningCenter(.review) }
    func showLibrary() { showLearningCenter(.library) }

    // MARK: - 其他窗口

    func showSettings() {
        show(id: "settings", title: "Globtype 设置") {
            SettingsView(settings: self.settings, services: self.services)
        }
    }

    func showOnboarding() {
        show(id: "onboarding", title: "欢迎使用 Globtype") {
            OnboardingView(settings: self.settings, services: self.services) { [weak self] in
                self?.windows["onboarding"]?.close()
                self?.showLearningCenter(.overview)
            }
        }
    }

    func showDiagnostics() {
        show(id: "diagnostics", title: "诊断", resizable: true) {
            DiagnosticsView(settings: self.settings)
        }
    }

    // MARK: -

    private func show<Content: View>(id: String, title: String, resizable: Bool = false, autosave: String? = nil,
                                     @ViewBuilder content: () -> Content) {
        updateDockVisibility(forceVisible: true)
        if let window = windows[id] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        if id == "learning" { style.insert(.fullSizeContentView) }
        window.styleMask = style
        window.isReleasedWhenClosed = false
        if let autosave, window.setFrameUsingName(autosave) {
            window.setFrameAutosaveName(autosave)
        } else {
            window.center()
            if let autosave { window.setFrameAutosaveName(autosave) }
        }
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows[id] = nil
                self?.updateDockVisibility(forceVisible: false)
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateDockVisibility(forceVisible: Bool) {
        let wanted: NSApplication.ActivationPolicy = (forceVisible || !windows.isEmpty) ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate() }
    }
}
