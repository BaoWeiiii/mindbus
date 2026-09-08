import SwiftUI

/// Minds 模块缺省页：模块还没有内容，先占住列表+详情两列的位置。
/// 与详情占位同风格：纯排版一句话，不用大号通用图标（AI 味重灾区）。
struct MindsPlaceholderView: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Text(l10n.s.mindsPlaceholder)
            .font(.system(size: 13))
            .foregroundStyle(DSLight.t3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .windowDragArea()   // 整页无控件，全域 = 拖动带
            .ignoresSafeArea(.container, edges: .top)   // 与其余各列同坐标系（无标题栏窗口）
    }
}
