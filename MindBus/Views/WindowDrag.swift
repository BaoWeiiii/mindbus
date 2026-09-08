import SwiftUI
import AppKit

/// 无边框窗的「可拖区」修饰符。
///
/// 背景：`isMovableByWindowBackground = true` 会把 SwiftUI **自绘滚动条**的拖动
/// 误判成「拖背景」（自绘 scroller 不是 AppKit 控件，系统认不出来）——用户拖
/// 进度条时整个窗口跟着跑。所以两个无边框窗改为关掉全背景拖动，用本修饰符把
/// 可拖区精确划给顶部 header 带与侧栏空白：滚动条/列表/消息区永不误拖，
/// 抓 header 或侧栏空白仍可自然拖窗。
///
/// 实现：macOS 15+ 用官方 `WindowDragGesture`（参与 SwiftUI 命中测试，
/// 不挡同区域按钮）；14 回退 `DragGesture` + `NSWindow.performDrag`
/// （首个 onChanged 把当前事件交给系统拖动循环，随后手势序列自然结束）。
extension View {
    func windowDragArea() -> some View {
        modifier(WindowDragAreaModifier())
    }
}

private struct WindowDragAreaModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), !DesignCapabilities.forceLegacy {
            content.gesture(WindowDragGesture())
        } else {
            content.gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        guard let event = NSApp.currentEvent,
                              let window = NSApp.keyWindow else { return }
                        window.performDrag(with: event)
                    }
            )
        }
    }
}
