import AppKit
import Combine
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var services: AppServices!
    private var hotkeys: HotkeyMonitor!
    private var coordinator: TranslationCoordinator!
    private var menuBar: MenuBarController!
    private var cancellables = Set<AnyCancellable>()
    private var launchedAsLoginItem = false
    private let log = Logger(subsystem: "app.globtype", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 启动时的 Apple Event 只在此刻可读：作为登录项启动时不弹窗（需求 15.5）
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        settings = SettingsStore.shared
        services = AppServices(settings: settings)
        WindowManager.shared.settings = settings
        WindowManager.shared.services = services

        coordinator = TranslationCoordinator(settings: settings, services: services)
        hotkeys = HotkeyMonitor(settings: settings)
        hotkeys.onTrigger = { [weak self] in self?.coordinator.trigger() }
        hotkeys.panelKeyHandler = { [weak self] keyCode, flags in
            self?.coordinator.handlePanelKey(keyCode: keyCode, flags: flags) ?? false
        }
        hotkeys.mouseDownHandler = { [weak self] point in self?.coordinator.handleMouseDown(at: point) }
        hotkeys.onRepeatedFailure = {
            let alert = NSAlert()
            alert.messageText = "全局按键监听多次被系统停用"
            alert.informativeText = "请退出并重新打开 Globtype。"
            alert.runModal()
        }

        menuBar = MenuBarController(settings: settings, services: services)
        menuBar.onFixPermissions = { WindowManager.shared.showOnboarding() }

        let permissions = PermissionService.shared
        permissions.$accessibility.combineLatest(permissions.$inputMonitoring)
            .sink { [weak self] ax, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // 权限变化后重建事件监听：在输入监控授权前创建的监听可能收不到键盘事件
                    self.hotkeys.stop()
                    if ax { self.hotkeys.start() }
                }
            }
            .store(in: &cancellables)

        if !settings.onboardingCompleted || !permissions.allGranted {
            WindowManager.shared.showOnboarding()
        } else if !launchedAsLoginItem {
            WindowManager.shared.showLearningCenter()
        }
        log.info("Globtype 已启动，登录项启动=\(self.launchedAsLoginItem)")
    }

    /// 已在运行时再次从访达、启动台、Spotlight 或程序坞打开（需求 15.3）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showLearningCenter()
        return true
    }

    /// 关闭窗口后继续在菜单栏运行。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 程序坞图标可见时需要标准菜单：文本框里的 ⌘C / ⌘V / ⌘A 依赖"编辑"菜单。
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Globtype", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Globtype", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Globtype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Globtype"))

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "编辑"))

        let learn = NSMenu(title: "学习")
        learn.addItem(withTitle: "概览", action: #selector(AppDelegate.openOverview), keyEquivalent: "1")
        learn.addItem(withTitle: "复习", action: #selector(AppDelegate.openReviewPage), keyEquivalent: "2")
        learn.addItem(withTitle: "表达库", action: #selector(AppDelegate.openLibraryPage), keyEquivalent: "3")
        learn.addItem(withTitle: "我的表达", action: #selector(AppDelegate.openExpressionsPage), keyEquivalent: "4")
        main.addItem(submenu(learn, title: "学习"))

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(window, title: "窗口"))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc func openSettings() { WindowManager.shared.showSettings() }
    @objc func openOverview() { WindowManager.shared.showLearningCenter(.overview) }
    @objc func openReviewPage() { WindowManager.shared.showLearningCenter(.review) }
    @objc func openLibraryPage() { WindowManager.shared.showLearningCenter(.library) }
    @objc func openExpressionsPage() { WindowManager.shared.showLearningCenter(.expressions) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
