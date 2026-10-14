import AppKit
import SwiftUI

/// 诊断窗口（任务 3.6）：用于 M0 兼容性测试。
struct DiagnosticsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var log = DiagnosticsLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("诊断模式（双击 Shift 后不翻译，只把输入框内容替换为“[GT] + 原文”）", isOn: $settings.diagnosticsMode)
            Text("记录只包含读写方式与结果，不包含任何文本内容。")
                .font(.caption).foregroundStyle(.secondary)
            Table(log.entries) {
                TableColumn("App", value: \.app)
                TableColumn("读取") { Text($0.readMethod) }
                TableColumn("范围") { Text($0.scope) }
                TableColumn("光标") { Text($0.caretAvailable ? "✓" : "✗") }
                TableColumn("辅助功能树") { Text($0.manualAccessibility ? "已启用" : "") }
                TableColumn("回填") { Text($0.replaceResult) }
            }
            HStack {
                Button("复制为 Markdown 表格") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.markdownTable, forType: .string)
                }
                Button("清空") { log.clear() }
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 360)
    }
}
