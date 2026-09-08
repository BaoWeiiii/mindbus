import SwiftUI
import MindBusCore

/// Minds 的三个页面。不是全局导航的一部分——切换只发生在 Minds 内容区里面，
/// 侧栏/顶栏一概不动。
enum MindsPage: Int, CaseIterable, Identifiable {
    case overview, ai, projects

    var id: Int { rawValue }

    /// 「01 / 02 / 03」与标题同级，不放大
    var number: String { String(format: "%02d", rawValue + 1) }

    func title(_ s: Strings) -> String {
        switch self {
        case .overview: return s.mindsPageOverview
        case .ai: return s.mindsPageAI
        case .projects: return s.mindsPageProjects
        }
    }
}

/// 页内分段导航。做成一排下划线标签而不是 SwiftUI 的 `Picker(.segmented)`：
/// 系统分段控件带自己的灰底胶囊，压在暖白页底上是另一种色温，
/// 而且它的选中态是蓝色（系统强调色），本模块只许有一种金。
struct MindsPageTabs: View {
    @Binding var page: MindsPage
    let l10n: Strings
    @State private var hovering: MindsPage?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 26) {
            ForEach(MindsPage.allCases) { p in
                tab(p)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(MindsUI.border).frame(height: 1)
        }
    }

    /// 选中的那一项就是页面标题（22px），未选中的是导航链接（13px）。
    /// 合成一行而不是「标签栏 + 下面再来一个大标题」——那样同一句话会在
    /// 50pt 的距离里出现两次。
    private func tab(_ p: MindsPage) -> some View {
        let selected = p == page
        return Button {
            page = p
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: selected ? 9 : 6) {
                Text(p.number)
                    .font(BrandFont.mono(selected ? 18 : 12, weight: .medium))
                    .foregroundStyle(selected ? MindsUI.accent : MindsUI.textTertiary)
                Text(p.title(l10n))
                    .font(.system(size: selected ? 22 : 13,
                                  weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? MindsUI.textPrimary : MindsUI.textSecondary)
                    .opacity(selected ? 1 : (hovering == p ? 1 : 0.85))
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? MindsUI.accent : (hovering == p ? MindsUI.accentSoft : .clear))
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? p : (hovering == p ? nil : hovering) }
    }
}
