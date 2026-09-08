import SwiftUI
import MindBusCore

struct ConversationBrowserView: View {
    @EnvironmentObject var store: ConversationStore
    @State private var copyingAll = false   // ⌘⇧C 渲染进行中（防重复触发）

    var body: some View {
        // 自绘三栏（替代 NavigationSplitView）：侧栏平贴无浮动卡（参考 mac 原生 chat app），
        // 色差 + 1px 细线分栏，折叠动画自管，列宽固定不漂。
        HStack(spacing: 0) {
            // 侧栏零动画(2026-08-16 二修):折叠动画两种写法都出过同一个病——
            // ① 移除+move transition:切到 Minds 大视图重布局时位移残留;
            // ② 宽度动画+trailing 对齐:中间帧宽度 <220 时内容靠右、左缘被裁,
            //    主线程一卡(Minds 首帧的 SQL)就永远冻在那一帧,文字裁头 logo 消失。
            // 折叠是低频操作,不值得为它的 0.2s 动画赔上整列错位。直接条件渲染。
            if !store.sidebarCollapsed {
                BrowserSidebarView()
                    .frame(width: 220)
                    .background(DSLight.sf)   // 比主区深一级：背景层级差分隔（设计系统主推）
                Rectangle().fill(DSLight.rule).frame(width: 1)
            }

            if store.favoritesSelected {
                FavoritesRootView(store: store)
                    .frame(maxWidth: .infinity)
            } else if store.mindsSelected {
                // Minds 真内容页:机械自描述 + WEAK SPOTS,占满列表+详情两列的位置
                MindsView(store: store)
                    .frame(maxWidth: .infinity)
            } else {
                ConversationListView()
                    .frame(width: 340)

                Rectangle().fill(DSLight.rule).frame(width: 1)

                DetailView()
                    .frame(maxWidth: .infinity)
            }
        }
        .background(DSLight.bg)
        .grain()   // 纸张质感层：设计指南「质感 > 颜色 > 布局」，对齐 web 的 body::before noise
        .frame(minWidth: 900, minHeight: 600)
        .background {
            // ⌘⇧C 复制全文：原在 toolbar 的隐藏按钮，toolbar 去掉后移到这里保留快捷键。
            Button("") { copyAll() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .hidden()
            // ⌘R 手动刷新（传 0 跳过节流）。自动刷新覆盖绝大多数情况，
            // 这个是给「刚在终端敲完、立刻想看到」的人的兜底。
            Button("") { store.refresh(minInterval: 0) }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
        // App 重新激活时增量刷新（内部 30s 节流）。
        // 这是最自然的时机：用户从 Claude Code 切回来，正是期待看到新对话的时刻。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
    }

    /// 渲染放后台（与 FAB 同款：万条消息级会话主线程渲染曾 beachball 秒级），回主线程写剪贴板。
    private func copyAll() {
        guard !copyingAll, let conv = store.selectedDetail else { return }
        copyingAll = true
        let prefs = CopyPrefsStore.shared.prefs
        Task.detached(priority: .userInitiated) {
            let text = ConversationCopy.render(conv, prefs: prefs)
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                copyingAll = false
            }
        }
    }
}

/// 窗口级侧栏折叠钮：裸 icon + hover 轻底（参考 mac 原生 chat app）。
/// 由 NSTitlebarAccessoryViewController 挂在 titlebar——天然钉在红绿灯右侧，位置恒定不随折叠移动。
struct SidebarToggleButton: View {
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { store.sidebarCollapsed.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSLight.t2)
                .frame(width: 28, height: 28)
                .background(hovering ? DSLight.sf2 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.sidebarCollapsed ? l10n.s.expandSidebar : l10n.s.collapseSidebar)
        .accessibilityLabel(store.sidebarCollapsed ? l10n.s.expandSidebar : l10n.s.collapseSidebar)
    }
}
