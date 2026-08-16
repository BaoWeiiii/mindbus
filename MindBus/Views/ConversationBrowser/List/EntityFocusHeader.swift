import SwiftUI
import MindBusCore

/// 实体页头(L1):列表栏进入实体模式时置顶——实体名 + 会话数 + 共现实体。
///
/// 「想不起关键词时顺着找」的 GUI 落点:共现实体逐个可跳,溜达式导航;
/// MCP 的 memory_browse(facet="entity:…") 是同一份数据的另一种渲染。
struct EntityFocusHeader: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if let entity = store.focusedEntity {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entity)
                        .font(BrandFont.mono(14, weight: .medium))
                        .foregroundStyle(DSLight.t1)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // 退出实体模式,回普通列表
                    Button {
                        store.focusedEntity = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(DSLight.t3)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.s.entityExitHelp)
                }
                Text(l10n.s.entityConvCount(store.filteredConversations.count))
                    .font(.system(size: 11))
                    .foregroundStyle(DSLight.t3)

                let neighbours = store.coOccurringEntities()
                if !neighbours.isEmpty {
                    Text(l10n.s.entityCoOccurring)
                        .font(.system(size: 11))
                        .foregroundStyle(DSLight.t3)
                        .padding(.top, 2)
                    FlowLayout(spacing: 6) {
                        ForEach(neighbours, id: \.text) { n in
                            Button {
                                store.focusedEntity = n.text   // 顺着共现跳下一个实体
                            } label: {
                                HStack(spacing: 4) {
                                    Text(n.text).font(BrandFont.mono(11))
                                        .foregroundStyle(DSLight.t2)
                                    Text("\(n.count)").font(BrandFont.mono(10))
                                        .foregroundStyle(DSLight.t4)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(DSLight.sf2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSLight.sf)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DSLight.rule).frame(height: 0.5)
            }
        }
    }
}
