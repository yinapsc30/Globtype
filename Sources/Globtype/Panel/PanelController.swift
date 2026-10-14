import AppKit
import Combine
import SwiftUI

/// 永不成为 key window 的非激活面板：目标 App 的输入框始终保持焦点（需求 5.4）。
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 非激活窗口中第一次点击也要生效。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 面板定位规则（需求 5.1~5.3）。
enum PanelPlacement {
    static let gap: CGFloat = 6

    static func origin(for size: CGSize, caret: CGRect?, element: CGRect?, mouse: NSPoint) -> NSPoint {
        let anchor: CGRect
        if let caret {
            anchor = caret
        } else if let element {
            anchor = CGRect(x: element.minX, y: element.minY, width: 0, height: 0)
        } else {
            anchor = CGRect(x: mouse.x + 8, y: mouse.y - 8, width: 0, height: 0)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchor.minX
        // 默认放在锚点下方；放不下时翻到上方
        var y = anchor.minY - gap - size.height
        if y < visible.minY {
            y = anchor.maxY + gap
        }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSPoint(x: x, y: y)
    }
}

@MainActor
final class PanelController {
    let model = PanelModel()
    private let panel = FloatingPanel()
    private var hosting: FirstMouseHostingView<PanelView>!
    private var cancellable: AnyCancellable?
    private var anchorCaret: CGRect?
    private var anchorElement: CGRect?
    private var anchorMouse = NSPoint.zero
    private var placedAbove = false

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    init() {
        hosting = FirstMouseHostingView(rootView: PanelView(model: model))
        panel.contentView = hosting
        // 内容变化后重新计算尺寸与位置
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
    }

    func show(caret: CGRect?, element: CGRect?) {
        anchorCaret = caret
        anchorElement = element
        anchorMouse = NSEvent.mouseLocation
        placedAbove = false
        layout(initial: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func layout(initial: Bool = false) {
        guard initial || panel.isVisible else { return }
        let size = hosting.fittingSize
        if initial {
            let origin = PanelPlacement.origin(for: size, caret: anchorCaret, element: anchorElement, mouse: anchorMouse)
            let anchorY = anchorCaret?.minY ?? anchorElement?.minY ?? anchorMouse.y
            placedAbove = origin.y > anchorY
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
            return
        }
        // 面板在锚点下方时保持顶边不动向下生长；在上方时保持底边不动
        var frame = panel.frame
        if placedAbove {
            frame.size = size
        } else {
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - size.height
        }
        if let visible = panel.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY + 4
        }
        panel.setFrame(frame, display: true)
    }
}

/// 1.5 秒后自动消失的小提示。
@MainActor
final class ToastController {
    private let panel = FloatingPanel()
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, caret: CGRect? = nil, element: CGRect? = nil) {
        let view = FirstMouseHostingView(rootView:
            Text(message)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .fixedSize()
        )
        panel.contentView = view
        let size = view.fittingSize
        let origin = PanelPlacement.origin(for: size, caret: caret, element: element, mouse: NSEvent.mouseLocation)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
