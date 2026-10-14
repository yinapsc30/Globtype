import AppKit
import SwiftUI

/// 只读、可选中的文本，并把当前选中的内容回传（需求 10.11：在译文中选中文字加入复习）。
struct SelectableText: NSViewRepresentable {
    let text: String
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityLabel("译文，可选中文字加入复习")
        view.string = text
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.selection = $selection
        if view.string != text { view.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        return CGSize(width: width, height: max(height, 18))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.length > 0 else { return }
            let picked = (view.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            // 避免在视图更新过程中修改状态
            DispatchQueue.main.async { self.selection.wrappedValue = picked }
        }
    }
}
