import SwiftUI
import MindBusCore

/// 列表无内容时显示什么。三种情况的文案不能混用 —— 这是低频工具的第一印象本身。
enum ListPlaceholderKind: Equatable {
    /// 首次建库中：索引为空且正在全量扫描。这一步可能持续几十秒，
    /// 若只在 header 角落转个小圈、正文留白，用户会以为 App 坏了。
    case scanning
    /// 库里确实没有对话（没装那几个工具，或还没用过）。
    case noConversations
    /// 有对话但被筛掉了。必须给出口。
    case noMatch(hint: String)
    /// 搜索词短于 trigram 索引的最小长度（3 字符）。
    ///
    /// 这一态必须和 noMatch 分开：全文索引用的是 trigram（3 字符窗口），
    /// 不足 3 字的查询匹配不到任何 token —— 而中文最常用的恰恰是双字词
    /// （重构、部署、鉴权、死锁）。若沿用「没有匹配的对话」，用户会得到一个
    /// **静默的错误答案**：他会认为自己从没聊过这个话题，而不是搜索没生效。
    /// 索引读不出来（损坏 / 磁盘满 / 权限）。此前这种情况与「你确实没有对话」
    /// 显示同一句文案，用户完全无从判断该做什么。
    case failed(title: String, detail: String)
}

/// 列表占位视图。
///
/// 刻意不使用大号 SF Symbol：通用图标（气泡 / 文件夹 / 放大镜）是 AI 味重灾区，
/// 用排版层级与留白建立质感更贴合产品调性。
struct ListEmptyState: View {
    let kind: ListPlaceholderKind
    var onClearFilters: () -> Void = {}
    /// 空结果救援:高频实体建议,点击直接换搜索词。仅 noMatch 态使用。
    var suggestions: [String] = []
    var onSuggest: (String) -> Void = { _ in }
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 10) {
            switch kind {
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 2)
                Text(l10n.s.emptyScanningTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
                // 不给百分比：扫描量事先不可知，假进度条只会让人更焦虑。
                // 只说明"首次会久一点"，把预期摆正。
                Text(l10n.s.emptyScanningDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
                    .multilineTextAlignment(.center)

            case .noConversations:
                Text(l10n.s.emptyNoneTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
                Text(l10n.s.emptyNoneDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)   // 逼近中文行高 ≥1.85（12pt × 1.85 ≈ 22pt）

            case .noMatch(let hint):
                Text(l10n.s.emptyNoMatchTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
                    .multilineTextAlignment(.center)
                Button(l10n.s.clearFilters, action: onClearFilters)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.gold)
                    .padding(.top, 2)

                // 救援建议:换个词试试——你自己的高频实体是最像"下一个搜索词"的东西。
                // MCP 侧的空结果救援上线后,GUI 这边一直还是空白,这里补齐同款。
                if !suggestions.isEmpty {
                    Text(l10n.s.emptySuggestTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DSLight.t3)
                        .padding(.top, 10)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { word in
                            Button {
                                onSuggest(word)
                            } label: {
                                Text(word)
                                    .font(BrandFont.mono(11))
                                    .foregroundStyle(DSLight.t2)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(DSLight.sf2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 260)
                }


            case .failed(let title, let detail):
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
