import AppKit
import GlobtypeCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var services: AppServices

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ProviderSettingsView(settings: settings, services: services)
                .tabItem { Label("翻译服务商", systemImage: "network") }
            LearningSettingsView(settings: settings, services: services)
                .tabItem { Label("学习", systemImage: "book") }
            DataSettingsView(services: services)
                .tabItem { Label("数据", systemImage: "externaldrive") }
            AboutView(services: services)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
        .padding()
    }
}

// MARK: - 通用

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("唤起方式") {
                Toggle("双击 Shift 唤起", isOn: $settings.useDoubleShift)
                HotkeyRecorder(hotkey: $settings.customHotkey)
                Text("如果你的输入法用 Shift 切换中英文，双击 Shift 通常会切换两次回到原状态。若发现状态不一致，建议关闭双击 Shift，改用自定义快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("不响应唤起的 App") {
                AppListEditor(bundleIDs: $settings.excludedBundleIDs,
                              footnote: "支持以 .* 结尾的前缀匹配，默认排除 JetBrains 系列（它们自身使用双击 Shift）")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// 录制自定义快捷键：必须包含 ⌘ / ⌥ / ⌃ 中至少一个修饰键。
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("自定义快捷键")
            Spacer()
            Button(recording ? "请按下快捷键…" : (hotkey?.display ?? "点击录制")) {
                recording ? stop() : start()
            }
            .accessibilityLabel("自定义快捷键，当前为 \(hotkey?.display ?? "未设置")")
            if hotkey != nil {
                Button("清除") { hotkey = nil }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc 取消
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
            var cg: CGEventFlags = []
            if flags.contains(.command) { cg.insert(.maskCommand) }
            if flags.contains(.option) { cg.insert(.maskAlternate) }
            if flags.contains(.control) { cg.insert(.maskControl) }
            if flags.contains(.shift) { cg.insert(.maskShift) }
            let key = Self.keyName(event)
            let display = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
            hotkey = Hotkey(keyCode: event.keyCode, modifiers: cg.rawValue, display: display)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↵"
        case 48: return "Tab"
        case 51: return "⌫"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// 编辑 bundle ID 列表：从"应用程序"中选择 App 添加。
struct AppListEditor: View {
    @Binding var bundleIDs: [String]
    var footnote: String?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(bundleIDs, id: \.self, selection: $selection) { id in
                HStack {
                    Text(Self.displayName(for: id))
                    Spacer()
                    Text(id).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 90, maxHeight: 140)
            HStack {
                Button("添加 App…", action: add)
                Button("移除") {
                    if let selection { bundleIDs.removeAll { $0 == selection } }
                    selection = nil
                }
                .disabled(selection == nil)
            }
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(id) {
                bundleIDs.append(id)
            }
        }
    }

    static func displayName(for bundleID: String) -> String {
        if bundleID.hasSuffix(".*") { return bundleID.hasPrefix("com.jetbrains") ? "JetBrains 系列" : bundleID }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - 翻译服务商

struct ProviderSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var services: AppServices

    @State private var presetID = "apple"
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var requiresKey = true
    @State private var testResult: String?
    @State private var testing = false
    @State private var saved = false

    private var preset: ProviderPreset? { services.presets.first { $0.id == presetID } }

    var body: some View {
        Form {
            Section {
                Picker("服务商", selection: $presetID) {
                    Text("Apple 翻译（免 Key，仅直译）").tag("apple")
                    ForEach(services.presets) { Text($0.name).tag($0.id) }
                }
                .onChange(of: presetID) { _, id in loadPreset(id) }
                if let note = preset?.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            if presetID != "apple" {
                Section("连接") {
                    TextField("接口地址", text: $baseURL)
                    TextField("模型", text: $model)
                    SecureField(requiresKey ? "API Key" : "API Key（可选）", text: $apiKey)
                    HStack {
                        Button(testing ? "测试中…" : "测试连接", action: test).disabled(testing)
                        if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("API Key 保存在 macOS 钥匙串中。源文本只会发送到上面的接口地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("Apple 翻译在本机完成，需要 macOS 15 及以上，首次使用可能需要下载语言包。它只提供直译，不支持润色、换个说法、讲解与学习卡片。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("保存", action: save).keyboardShortcut(.defaultAction)
                    if saved { Text("已保存").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("本月用量") {
                let u = services.usage?.usage() ?? .init(requests: 0, promptTokens: 0, completionTokens: 0)
                LabeledContent("调用次数", value: "\(u.requests)")
                LabeledContent("估算 token", value: "\(u.totalTokens)（输入 \(u.promptTokens) · 输出 \(u.completionTokens)）")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadCurrent)
    }

    private func loadCurrent() {
        guard let config = settings.provider else {
            presetID = "apple"
            return
        }
        presetID = config.presetID
        baseURL = config.baseURL
        model = config.model
        requiresKey = config.requiresKey
        apiKey = KeychainStore.key(for: config.presetID) ?? ""
    }

    private func loadPreset(_ id: String) {
        testResult = nil
        saved = false
        guard let preset = services.presets.first(where: { $0.id == id }) else { return }
        if settings.provider?.presetID == id, let config = settings.provider {
            baseURL = config.baseURL
            model = config.model
        } else {
            baseURL = preset.baseURL
            model = preset.model
        }
        requiresKey = preset.requiresKey
        apiKey = KeychainStore.key(for: id) ?? ""
    }

    private var draftConfig: ProviderConfig? {
        guard let preset else { return nil }
        // 自定义服务商填写了 Key 时视为需要 Key
        let needsKey = preset.requiresKey || (preset.id == "custom" && !apiKey.isEmpty)
        return ProviderConfig(presetID: preset.id, name: preset.name, baseURL: baseURL, model: model,
                              protocol: preset.protocol, requiresKey: needsKey)
    }

    private func save() {
        if presetID == "apple" {
            settings.provider = nil
        } else if let config = draftConfig {
            KeychainStore.setKey(apiKey.isEmpty ? nil : apiKey, for: config.presetID)
            settings.provider = config
        }
        saved = true
    }

    private func test() {
        guard let config = draftConfig else { return }
        testing = true
        testResult = nil
        let provider = LLMProvider(config: config, apiKey: apiKey.isEmpty ? nil : apiKey)
        Task {
            do {
                try await provider.testConnection()
                testResult = "连接成功"
            } catch {
                testResult = "失败：" + ((error as? ProviderError)?.message ?? error.localizedDescription)
            }
            testing = false
        }
    }
}

// MARK: - 学习

struct LearningSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var services: AppServices

    var body: some View {
        Form {
            Section("复习") {
                Stepper("每日新卡上限：\(settings.dailyNewLimit)", value: $settings.dailyNewLimit, in: 0...100)
                    .onChange(of: settings.dailyNewLimit) { _, _ in services.applySettings() }
                Text("每次翻译最多提取 3 个值得学的表达。超出当日上限的会排队，之后每天按顺序补入。")
                    .font(.caption).foregroundStyle(.secondary)
                if !services.dictionaryAvailable {
                    Text("未找到本地词典，单词卡不显示音标，基础词过滤暂不可用。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("不记录的 App") {
                AppListEditor(bundleIDs: $settings.noRecordBundleIDs,
                              footnote: "在这些 App 中的翻译不会写入表达库。按 ⌥Enter 替换也可以跳过单次记录。")
                    .onChange(of: settings.noRecordBundleIDs) { _, _ in services.applySettings() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 数据

struct DataSettingsView: View {
    @ObservedObject var services: AppServices
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var confirmRange = false
    @State private var confirmAll = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("表达库") {
                LabeledContent("记录数", value: "\(services.learning?.recordCount ?? 0)")
                Text("所有数据只保存在本机：~/Library/Application Support/Globtype/")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("按时间段删除") {
                DatePicker("从", selection: $from, displayedComponents: .date)
                DatePicker("到", selection: $to, displayedComponents: .date)
                Button("删除这段时间的记录…") { confirmRange = true }
            }
            Section {
                Button("清空全部记录与复习卡片…", role: .destructive) { confirmAll = true }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("删除所选时间段内的记录？此操作无法撤销。", isPresented: $confirmRange) {
            Button("删除", role: .destructive) {
                let start = Calendar.current.startOfDay(for: from)
                let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
                do {
                    try services.learning?.deleteRecords(from: start, to: end)
                    message = "已删除"
                } catch { message = "删除失败" }
                services.notifyChanged()
            }
        }
        .confirmationDialog("清空全部记录与复习卡片？此操作无法撤销。", isPresented: $confirmAll) {
            Button("清空", role: .destructive) {
                do {
                    try services.learning?.deleteAll()
                    message = "已清空"
                } catch { message = "清空失败" }
                services.notifyChanged()
            }
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Globtype").font(.title2.weight(.semibold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                .foregroundStyle(.secondary)
            Text("在任意输入框用中文写，双击 Shift 变成地道英文，并把每次翻译沉淀为学习素材。")
            Divider()
            Text("开源许可").font(.headline)
            Text("Globtype 以 MIT 许可发布。本地词典数据来自 ECDICT（MIT 许可）。")
                .font(.callout)
            Text("隐私：没有账号、没有统计上报。源文本只发送给你配置的翻译服务商，其余数据只保存在本机。")
                .font(.callout).foregroundStyle(.secondary)
            if let error = services.storageError {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
