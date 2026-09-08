import SwiftUI
import MindBusCore

struct SearchBar: View {
    @EnvironmentObject var store: ConversationStore
    /// bare：不带自身底色/圆角（外层玻璃胶囊承担视觉）；默认带灰底 rounded-6。
    var bare: Bool = false

    @ObservedObject private var l10n = L10n.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DSLight.t3)
            TextField(l10n.s.searchPlaceholder, text: Binding(
                get: { store.searchQuery },
                set: { store.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .focused($focused)
            .onExitCommand {   // Esc：清词 + 失焦
                store.searchQuery = ""
                focused = false
            }
            if !store.searchQuery.isEmpty {
                Button(action: { store.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSLight.t3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(l10n.s.clearSearch)
            } else if !focused {
                // ⌘K 徽章：告诉用户「不用鼠标够底部」。聚焦或已有词时隐藏——
                // 那两种状态下它既占清除按钮的位又不再传达任何信息。
                // 与清除按钮天然互斥（有词才有清除钮），共用右端位置不打架。
                Text("⌘K")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(DSLight.t4)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    // plain 分支搜索框自身底色就是 sf2，徽章必须上探一级（sf3）
                    // 才有层级差；bare 玻璃胶囊内无实底，sf2 即可浮出。
                    .background(bare ? DSLight.sf2 : DSLight.sf3,
                                in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)   // 纯快捷键提示，VoiceOver 无需播报
            }
        }
        .padding(.horizontal, bare ? 0 : 10)
        .padding(.vertical, bare ? 0 : 8)
        .background(bare ? Color.clear : DSLight.sf2)
        .cornerRadius(bare ? 0 : 6)
        .frame(maxWidth: .infinity)
        .background {
            // ⌘F / ⌘K 双快捷键聚焦搜索框（隐藏按钮承载快捷键——与库内 ⌘⇧C 同款模式）。
            // 「找回对话」是本产品第一动作，搜索框在窗口最底部不该只能鼠标够。
            // ⌘F 是 mac 传统「查找」，⌘K 是新生代工具（Raycast/Linear/Slack)的召唤肌肉记忆，
            // 两个都留——徽章只标 ⌘K，⌘F 留给老习惯静默可用。
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: [.command])
                .hidden()
            Button("") { focused = true }
                .keyboardShortcut("k", modifiers: [.command])
                .hidden()
        }
    }
}
