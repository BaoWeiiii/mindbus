import Foundation

/// 命中词标注的纯逻辑层（UI 无关，可测）。
///
/// 与召回解耦：FTS5 trigram 负责「哪些会话被搜出来」，这里只负责「原词在
/// 一段文本里的字面位置」——大小写不敏感的 literal 匹配。两者能力不同
/// （trigram 会做子串分解），解耦后分词差异不会让高亮凭空消失或错位；
/// 代价是个别 FTS 召回的行可能标不出高亮（如命中在未展示的字段里），
/// 此时 UI 按「无命中」处理即可，不会错标。
public enum SearchHighlight {

    /// query 在 text 中所有不重叠的命中区间（从前到后，大小写不敏感）。
    /// 空词/空文本返回空数组——调用侧可据此零成本跳过高亮路径。
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: q, options: [.caseInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// 消息是否含命中（消息级定位用）：扫所有块的 plainText，
    /// 与 FTS 入索引的口径一致（text/code/thinking/tool 全算，图片不算——
    /// 它的 plainText 是 "[image: …]" 元信息，不构成用户语义上的命中）。
    public static func messageMatches(_ message: Message, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return message.blocks.contains { block in
            if case .image = block { return false }
            return block.plainText.range(of: q, options: [.caseInsensitive]) != nil
        }
    }
}
