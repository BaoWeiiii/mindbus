import SwiftUI
import MindBusCore

// MARK: - 命中词金色标注（列表行 / 详情气泡 / 时间线摘要共用）
//
// 召回与标注分工：FTS trigram 负责「搜出哪些会话」（ConversationIndex.search），
// 这里只对原词做大小写不敏感的 literal 标注（SearchHighlight.ranges）。
// 样式按设计系统品牌色规则：前景 DSLight.gold（亮色主题深金）+ DSLight.goldG 淡金底，
// 不加粗不放大——命中是「被点亮」，不是「被吼出来」。

enum SearchHighlighter {

    /// 纯文本 → 标注后的 AttributedString。空词/无命中时原样（但有构造成本，
    /// 空词场景请在调用侧直接走纯 Text 分支，见 HighlightedLine）。
    static func attributed(_ text: String, query: String) -> AttributedString {
        var attr = AttributedString(text)
        annotate(&attr, query: query)
        return attr
    }

    /// 在（可能已渲染过 markdown 的）AttributedString 上按**可见文本**标注：
    /// markdown 语法符号在渲染时已被消费，`attr.characters` 即用户看到的字符流，
    /// 对它找 range 再映射回 AttributedString——粗体/行内代码等既有属性只被
    /// 叠加前景/底色，不被破坏。
    static func annotate(_ attr: inout AttributedString, query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let visible = String(attr.characters)
        for r in SearchHighlight.ranges(of: q, in: visible) {
            guard let ar = Range(r, in: attr) else { continue }
            attr[ar].foregroundColor = DSLight.gold
            attr[ar].backgroundColor = DSLight.goldG
        }
    }
}

/// 单行命中高亮文本（列表标题/preview、时间线节点摘要共用）。
///
/// Equatable：这些行的父视图都有 hover/选中 @State，每次翻转都会重建子视图值；
/// text/query 未变则判等短路、body 不重算——range 扫描不进热路径。
/// 空 query 走纯 Text 分支：不构造 AttributedString，非搜索态零成本。
struct HighlightedLine: View, Equatable {
    let text: String
    let query: String
    var font: Font
    var color: Color

    /// font/color 在同一调用点恒定，不参与判等。
    static func == (l: Self, r: Self) -> Bool {
        l.text == r.text && l.query == r.query
    }

    var body: some View {
        Group {
            if query.isEmpty {
                Text(text)
            } else {
                Text(SearchHighlighter.attributed(text, query: query))
            }
        }
        .font(font)
        .foregroundStyle(color)
    }
}
