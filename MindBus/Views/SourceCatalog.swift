import Foundation
import MindBusCore
import SwiftUI

/// 三个采集来源的展示路径：向导来源页与设置页共用一份，改一处即两处同步。
enum SourceCatalog {
    static let entries: [(source: ConversationSource, path: String)] = [
        (.claudeCode,  "~/.claude/projects/"),
        (.claudeAgent, "~/Library/Application Support/Claude/local-agent-mode-sessions/"),
        (.codex,       "~/.codex/sessions/"),
    ]
}

/// 来源开关的界面模型：包一层 `SourcePreferences`，让 SwiftUI 能观察变化。
@MainActor
final class SourcePrefsModel: ObservableObject {
    static let shared = SourcePrefsModel()

    @Published private(set) var disabled: Set<ConversationSource> = SourcePreferences.disabledSources()

    func isEnabled(_ source: ConversationSource) -> Bool { !disabled.contains(source) }

    func setEnabled(_ on: Bool, for source: ConversationSource) {
        SourcePreferences.setEnabled(on, for: source)
        disabled = SourcePreferences.disabledSources()
    }
}

/// 「让 AI 调用」的接入指令：设置页与向导完成页共用。
enum MCPSetup {
    /// 随 App 打包的 mindbus-mcp 路径；裸跑（非 .app）时退回标准安装位置。
    static var serverPath: String {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { return "/Applications/MindBus.app/Contents/MacOS/mindbus-mcp" }
        return bundle + "/Contents/MacOS/mindbus-mcp"
    }

    @MainActor
    static func copyPrompt(_ l10n: L10n) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(l10n.s.mcpPrompt(serverPath), forType: .string)
    }
}

/// 「复制接入指令」按钮：点击复制，1.5 秒内显示「已复制」。
struct CopyMCPPromptButton: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var copied = false
    @State private var generation = 0

    var body: some View {
        Button {
            MCPSetup.copyPrompt(l10n)
            copied = true
            generation += 1
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if g == generation { copied = false } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copied ? l10n.s.mcpPromptCopied : l10n.s.mcpCopyPrompt)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(copied ? DSLight.green : DSLight.gold)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
