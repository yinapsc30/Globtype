import AppKit
import Combine

/// 菜单栏图标与菜单（需求 13、8.3、12.5）。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: SettingsStore
    private let services: AppServices
    private let permissions = PermissionService.shared
    private var cancellables = Set<AnyCancellable>()
    var onFixPermissions: (() -> Void)?

    init(settings: SettingsStore, services: AppServices) {
        self.settings = settings
        self.services = services
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        permissions.$accessibility.merge(with: permissions.$inputMonitoring)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        settings.$isEnabled
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let name: String
        let description: String
        if !permissions.allGranted {
            name = "exclamationmark.triangle"
            description = "Globtype：缺少权限"
        } else if !settings.isEnabled {
            name = "character.bubble"
            description = "Globtype：已停用"
        } else {
            name = "character.bubble.fill"
            description = "Globtype"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !settings.isEnabled
        statusItem.button?.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !permissions.allGranted {
            menu.addItem(item("修复权限…", #selector(fixPermissions)))
            menu.addItem(.separator())
        }
        let toggle = item("启用 Globtype", #selector(toggleEnabled))
        toggle.state = settings.isEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(item("打开学习中心", #selector(openLearningCenter), key: "l"))
        let due = services.dueCount()
        menu.addItem(item(due > 0 ? "今日复习（\(due)）" : "今日复习", #selector(openReview)))
        menu.addItem(item("打开表达库", #selector(openLibrary)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), key: ","))
        let diagnostics = item("诊断…", #selector(openDiagnostics))
        if settings.diagnosticsMode { diagnostics.title = "诊断…（诊断模式已开启）" }
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        menu.addItem(item("退出 Globtype", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { settings.isEnabled.toggle() }
    @objc private func openLearningCenter() { WindowManager.shared.showLearningCenter() }
    @objc private func openReview() { WindowManager.shared.showReview() }
    @objc private func openLibrary() { WindowManager.shared.showLibrary() }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
    @objc private func openDiagnostics() { WindowManager.shared.showDiagnostics() }
    @objc private func fixPermissions() { onFixPermissions?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
