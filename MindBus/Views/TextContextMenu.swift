import SwiftUI
import AppKit

/// 可选中文本（`.textSelection(.enabled)`）的右键接管修饰符。
///
/// 背景：可选 Text 在 macOS 上由 AppKit 文本机件承接命中——右键点在**字形上**时，
/// 它自带的系统文本菜单（查询/翻译/搜索/字体/服务…）优先于挂在祖先视图上的
/// SwiftUI `.contextMenu`；点在气泡留白处才轮到我们的菜单。于是同一条消息
/// 「有时弹系统菜单、有时弹自定义菜单」。产品定案：右键永远只出自定义菜单。
///
/// 实现：透明覆盖层只在「会弹菜单的按下」（右键 / ⌃+左键）时认领命中，
/// 自身不提供菜单 → 事件沿 responder 链上浮到祖先的 `.contextMenu`（与现在
/// 点留白弹出自定义菜单是同一条路径）；其余一切事件 hitTest 返回 nil 放行，
/// 划选/拖选/悬停/滚动/点按完全不受影响。
extension View {
    func customContextMenuOnly() -> some View {
        overlay { ContextMenuClickCatcher() }
    }
}

private struct ContextMenuClickCatcher: NSViewRepresentable {
    final class CatcherView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil,
                  let event = NSApp.currentEvent else { return nil }
            let wantsMenu = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return wantsMenu ? self : nil
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ nsView: CatcherView, context: Context) {}
}
