import Foundation

/// 复制范围两态模型（用户定案 2026-08-03）：
/// 「未选择消息时复制完整会话；选择消息后，只复制所选内容。」
///
/// - 0 条手动选择 = `.all`（完整会话，界面上**不**画全选态）
/// - ≥1 条手动选择 = `.selected`（仅所选）
/// - 不存在「0 条内容」第三态：选空自动回 `.all`
public enum CopyScope: Equatable {
    case all
    case selected(Set<String>)

    public var selectedIds: Set<String> {
        if case .selected(let ids) = self { return ids }
        return []
    }

    /// 处于「所选消息」模式（≥1 条手动选择）。
    public var isSelection: Bool {
        if case .selected = self { return true }
        return false
    }

    public var count: Int { selectedIds.count }

    /// 单条翻转：all → selected([id])；selected 内 toggle；清空回 all。
    /// 普通点击即累加（不要求按 Command，桌面聊天不是文件管理器）。
    public func toggling(_ id: String) -> CopyScope {
        switch self {
        case .all:
            return .selected([id])
        case .selected(var ids):
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            return ids.isEmpty ? .all : .selected(ids)
        }
    }

    /// Shift 区间：anchor→target（含端点，按 order 给出的显示顺序）整段并入选择。
    /// anchor 缺失或不在 order 里时退化为单条翻转——宁可少选，不猜区间。
    public func selectingRange(anchor: String?, target: String, order: [String]) -> CopyScope {
        guard let anchor,
              let a = order.firstIndex(of: anchor),
              let b = order.firstIndex(of: target)
        else { return toggling(target) }
        let span = Set(order[min(a, b)...max(a, b)])
        let ids = selectedIds.union(span)
        return ids.isEmpty ? .all : .selected(ids)
    }
}
