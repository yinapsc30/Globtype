import AppKit
import SwiftUI

/// 首次启动引导（需求 8.1~8.6、1.4）。
struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var services: AppServices
    @ObservedObject var permissions = PermissionService.shared
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, accessibility, inputMonitoring, hotkey, provider, privacy, done
    }

    @State private var step = Step.welcome
    @State private var suggestions: [(id: String, name: String)] = []
    @State private var chosen = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                .accessibilityLabel("引导进度")
            content
            Spacer()
            HStack {
                if step != .welcome && step != .done {
                    Button("上一步") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                nextButton
            }
        }
        .padding(28)
        .frame(width: 560, height: 440)
        .onChange(of: permissions.accessibility) { _, granted in
            if granted && step == .accessibility { step = .inputMonitoring }
        }
        .onChange(of: permissions.inputMonitoring) { _, granted in
            if granted && step == .inputMonitoring { step = .hotkey }
        }
        .onAppear(perform: loadSuggestions)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            Text("欢迎使用 Globtype").font(.largeTitle.weight(.semibold))
            Text("在任意 App 的输入框里用中文写完，双击 Shift，就能看到地道的英文译文，按 Enter 直接替换。每次翻译会自动保存，并挑出值得学的表达帮你复习。")
            Text("接下来需要授予两项系统权限，并做几项简单设置。").foregroundStyle(.secondary)
        case .accessibility:
            permissionStep(title: "授予辅助功能权限",
                           detail: "用于读取当前输入框里的文字、把译文填回去，以及拦截面板上的按键。Globtype 会自动跳过密码框。",
                           granted: permissions.accessibility,
                           action: permissions.requestAccessibility)
        case .inputMonitoring:
            permissionStep(title: "授予输入监控权限",
                           detail: "用于识别双击 Shift 和自定义快捷键。Globtype 不记录你的按键内容。",
                           granted: permissions.inputMonitoring,
                           action: permissions.requestInputMonitoring)
        case .hotkey:
            Text("选择唤起方式").font(.title2.weight(.semibold))
            Toggle("双击 Shift 唤起", isOn: $settings.useDoubleShift)
            HotkeyRecorder(hotkey: $settings.customHotkey)
            Text("系统拼音、搜狗、微信输入法都用 Shift 切换中英文。双击 Shift 会切换两次，通常回到原状态；如果你发现切换后状态不对，请关闭双击 Shift 并设置一个自定义快捷键（如 ⌥Space）。")
                .font(.callout).foregroundStyle(.secondary)
        case .provider:
            Text("配置翻译服务商").font(.title2.weight(.semibold))
            Text("推荐使用 DeepSeek 等国内可直连的服务，自带 API Key，费用由你直接支付给服务商。也可以先跳过，使用免费的 Apple 翻译（仅直译，不含润色与学习功能）。")
                .foregroundStyle(.secondary)
            Button("打开服务商设置…") { WindowManager.shared.showSettings() }
            Text(settings.provider.map { "当前：\($0.name)" } ?? "当前：Apple 翻译")
                .font(.callout)
        case .privacy:
            Text("不记录的 App").font(.title2.weight(.semibold))
            Text("在这些 App 中的翻译不会保存到表达库。以后可以在 设置 → 学习 中修改。").foregroundStyle(.secondary)
            if suggestions.isEmpty {
                Text("未在本机发现常见的密码管理器或银行 App。").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(suggestions, id: \.id) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { chosen.contains(app.id) },
                        set: { if $0 { chosen.insert(app.id) } else { chosen.remove(app.id) } }))
                }
            }
        case .done:
            Text("准备就绪").font(.largeTitle.weight(.semibold))
            Text("试试看：在任意输入框写一句中文，然后\(settings.useDoubleShift ? "双击 Shift" : "按 \(settings.customHotkey?.display ?? "自定义快捷键")")。")
            Text("面板上：Enter 替换 · ⌥Enter 替换但不记录 · R 换个说法 · Tab 讲解 · Esc 关闭")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func permissionStep(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail)
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
                Text(granted ? "已授予" : "未授予")
            }
            if !granted {
                Button("打开系统设置", action: action)
                Text("在系统设置中打开 Globtype 的开关后，这里会自动进入下一步。如果列表中没有 Globtype，请点“+”手动添加。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var nextButton: some View {
        switch step {
        case .done:
            Button("开始使用") {
                settings.onboardingCompleted = true
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
        case .provider:
            Button(settings.provider == nil ? "跳过，使用 Apple 翻译" : "下一步") { step = .privacy }
                .keyboardShortcut(.defaultAction)
        case .privacy:
            Button("下一步") {
                for id in chosen where !settings.noRecordBundleIDs.contains(id) {
                    settings.noRecordBundleIDs.append(id)
                }
                services.applySettings()
                step = .done
            }
            .keyboardShortcut(.defaultAction)
        case .accessibility, .inputMonitoring:
            Button("下一步") { step = Step(rawValue: step.rawValue + 1)! }
                .keyboardShortcut(.defaultAction)
        default:
            Button("下一步") { step = Step(rawValue: step.rawValue + 1)! }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// 常见的密码管理器与银行类 App，只展示本机已安装的。
    static let sensitiveApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.lastpass.LastPass", "in.sinew.Enpass-Desktop", "com.apple.keychainaccess", "com.dashlane.dashlanephonefinal",
        "com.icbc.mac", "com.cmbchina.mac", "com.alipay.macos",
    ]

    private func loadSuggestions() {
        suggestions = Self.sensitiveApps.compactMap { id in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return nil }
            return (id, AppListEditor.displayName(for: id))
        }
        chosen = Set(suggestions.map(\.id))
    }
}
