import SwiftUI
import MindBusCore

/// 对话窗口最左列：工具单选聚焦（全部 + 3 工具，带 logo）+ 底部设置入口。
struct BrowserSidebarView: View {
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var stars = StarredMessagesStore.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updater = UpdaterManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
                .padding(.top, 64)   // logo 上缘 = 中栏首行卡片上缘（header 52 + List 顶 inset ≈ 64）
                .padding(.bottom, 16)

            mindsSection

            favoritesSection

            sectionHeader(l10n.s.sidebarWorkspace)

            toolSelector

            Spacer(minLength: 12)

            bottomSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .windowDragArea()   // 侧栏空白 = 拖动带（工具行/设置按钮是控件，优先于手势）
        // 与中栏同坐标系：中栏列表列 ignoresSafeArea 顶到窗口 0，侧栏此前落在
        // titlebar safe area 下（≈28pt）——同一个 padding 值两列却不同高，对不齐。
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - 品牌行

    /// logo + 词标：无标题栏窗口里 App 身份的唯一常驻锚点。
    /// 侧栏折叠时整列不渲染（ConversationBrowserView 的 if），无需另行隐藏。
    private var brandRow: some View {
        HStack(spacing: 8) {
            if let logo = BrandLogoImage.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
            }
            Text("MindBus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DSLight.t1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)   // 与工具行同缩进，logo 与 tile 左缘对齐
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MindBus")
    }

    // MARK: - 分组小标题

    /// 分组名小字：与行内容同缩进（14），对齐 icon 左缘。
    /// t4（meta 级暖灰）：分组名是「地图标注」不是内容，必须比行文字退后一档。
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DSLight.t4)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
    }

    // MARK: - 工具行

    private let toolRowH: CGFloat = 32

    private var toolItems: [ConversationSource?] {
        [nil] + store.availableSources   // 只列探测到「用过」的工具（用户定案）
    }

    private var selectedToolIndex: Int {
        toolItems.firstIndex(where: { $0 == store.focusedSource }) ?? 0
    }

    /// 工具单选：玻璃药丸随 offset 滑动——
    /// 滑动过程中玻璃折射药丸**下面经过的行**的 icon/文字（移动时的形变）；
    /// 药丸**内部叠一份当前选中行的清晰内容**跟随，所以**停在选中行时该行清晰、不糊**。
    private var toolSelector: some View {
        ZStack(alignment: .top) {
            // 底层：所有行常态（玻璃滑过时被折射形变）
            VStack(spacing: 0) {
                ForEach(Array(toolItems.enumerated()), id: \.offset) { _, src in
                    toolRowContent(src, active: false)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.mindsSelected = false   // 从 Minds/收藏 回工作空间
                            store.favoritesSelected = false
                            store.focusedSource = src
                        }
                }
            }
            // 玻璃药丸（折射底层）+ 内部当前选中行清晰内容（跟随滑动，停下清晰）。
            // Minds/收藏 选中时工具组无选中态，药丸整体退场。
            if !store.mindsSelected && !store.favoritesSelected {
                ZStack {
                    selectionPill
                    toolRowContent(store.focusedSource, active: true)
                        .padding(.horizontal, 8)
                }
                .frame(height: toolRowH)
                .padding(.horizontal, 6)
                .offset(y: CGFloat(selectedToolIndex) * toolRowH)
                .allowsHitTesting(false)
                .animation(.bouncy(duration: 0.4), value: store.focusedSource)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.mindsSelected)
    }

    /// 选中药丸玻璃：通透 glassEffect（折射下面滚过的行）+ 细边缘高光，旧系统 sf2 实色。
    @ViewBuilder
    private var selectionPill: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        } else {
            shape.fill(DSLight.sf2)
        }
    }

    private func toolRowContent(_ source: ConversationSource?, active: Bool) -> some View {
        HStack(spacing: 8) {
            if let s = source {
                ToolTile(source: s, active: active, size: 18)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(active ? DSLight.t1 : DSLight.t3)
                    .frame(width: 18, height: 18)
            }
            Text(source == nil ? l10n.s.filterAll : shortLabel(source!))
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? DSLight.t1 : DSLight.t2)
            Spacer(minLength: 0)
        }
        .frame(height: toolRowH)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 侧栏标签 = 统一展示名（旧的 claudeAgent→"Claude" 特例随「Claude 客户端」
    /// 改名一并取消：名字本身已短且自解释，两处再分叉只会前后不一致）。
    private func shortLabel(_ s: ConversationSource) -> String {
        s.displayName(isZh: l10n.isZh)
    }

    // MARK: - Minds 模块

    /// Minds 独立模块：品牌行下、工作区组上（用户定案的顺序）；与工具行同构，
    /// 选中态同款玻璃药丸（不参与工作区的滑动药丸——两组选中互斥）。
    /// 与工作区组只靠留白分组（原生侧栏语法：小标题+留白）——
    /// 不加分隔线，一屏只留底部功能区那一条。
    private var mindsSection: some View {
        ZStack {
            if store.mindsSelected {
                selectionPill
                    .frame(height: toolRowH)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
            mindsRowContent(active: store.mindsSelected)
                .padding(.horizontal, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.mindsSelected = true }
        .animation(.easeOut(duration: 0.15), value: store.mindsSelected)
    }

    /// 收藏模块入口(设计说明:Minds 下方、工作区上方,跨项目全局;标准书签图标;
    /// 右侧数字 = **含收藏的对话数**,不是消息总数,hover 提示给两个数)。
    private var favoritesSection: some View {
        let convCount = stars.summaries().count
        return ZStack {
            if store.favoritesSelected {
                selectionPill
                    .frame(height: toolRowH)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Image(systemName: store.favoritesSelected ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12))
                    .foregroundStyle(store.favoritesSelected ? DSLight.gold : DSLight.t3)
                    .frame(width: 18, height: 18)
                Text(l10n.s.sidebarFavorites)
                    .font(.system(size: 13, weight: store.favoritesSelected ? .semibold : .regular))
                    .foregroundStyle(store.favoritesSelected ? DSLight.t1 : DSLight.t2)
                Spacer(minLength: 0)
                if convCount > 0 {
                    Text("\(convCount)")
                        .font(BrandFont.mono(11))
                        .foregroundStyle(store.favoritesSelected ? DSLight.gold : DSLight.t3)
                }
            }
            .frame(height: toolRowH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.favoritesSelected = true }
        .help(l10n.s.favoritesTooltip(convCount, stars.activeCount))
        .animation(.easeOut(duration: 0.15), value: store.favoritesSelected)
        .padding(.bottom, 20)   // 与下方工作区组的留白分组
    }

    private func mindsRowContent(active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 12))
                .foregroundStyle(active ? DSLight.t1 : DSLight.t3)
                .frame(width: 18, height: 18)
            Text(l10n.s.sidebarMinds)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? DSLight.t1 : DSLight.t2)
            Spacer(minLength: 0)
        }
        .frame(height: toolRowH)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部：设置入口

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 10).padding(.bottom, 4)
            // 后台发现新版本时才出现（用户定案：提示放主窗设置入口上方，不弹窗）
            if let v = updater.availableUpdateVersion {
                updateRow(version: v)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            SidebarMenuRow(title: l10n.s.settingsTitle, icon: "gearshape") {
                SettingsWindow.shared.show()
            }
        }
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.25), value: updater.availableUpdateVersion)
    }

    /// 更新提示行：与菜单行同构，金色标记「贵重但安静」——点击进标准更新流程。
    private func updateRow(version: String) -> some View {
        Button { updater.checkForUpdates() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13)).frame(width: 18)
                Text(l10n.s.updateBanner(version))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(l10n.s.updateBannerAction)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(DSLight.gold, in: Capsule())
            }
            .foregroundStyle(DSLight.gold)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(DSLight.gold.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

/// 侧栏底部菜单项：icon + 文字，hover 高亮。
private struct SidebarMenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSLight.t1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovering ? DSLight.sf2 : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))   // 设计系统：菜单项 rounded-8
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
