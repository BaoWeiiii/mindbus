import SwiftUI
import MindBusCore

struct CodeBlockView: View {
    let language: String
    let code: String
    @ObservedObject private var l10n = L10n.shared
    @State private var copied: Bool = false
    @State private var expanded: Bool = false
    /// 逐 token 高亮结果缓存：.task 算一次存 @State——
    /// 曾经每次 render（点复制按钮、任何父级状态翻转）都全文重高亮。
    @State private var highlightedCache: AttributedString? = nil

    private static let foldThreshold = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayLanguage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.t3)
                Spacer()
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.t2)
                }
                .buttonStyle(.borderless)
                .help(l10n.s.copyCodeBlock)
                .accessibilityLabel(l10n.s.copyCodeBlock)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(DS.sf2)

            ScrollView(.horizontal) {
                // 缓存未就绪的一帧内先出素文本（内容正确，仅暂无着色），高亮完成后无缝替换
                Text(highlightedCache ?? AttributedString(displayCode))
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .textSelection(.enabled)
                    .customContextMenuOnly()
            }

            if isFoldable {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                        Text(expanded ? l10n.s.collapse : l10n.s.showMoreLines(hiddenLineCount))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(DS.t2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(DS.sf2)
                }
                .buttonStyle(.plain)
            }
        }
        .background(DS.sf)
        .cornerRadius(DS.radiusMd)
        // expanded 变化才重算（显示行数变了）；高亮放后台，主线程不卡长代码块
        .task(id: expanded) {
            let lang = language
            let codeToShow = displayCode
            highlightedCache = await Task.detached(priority: .userInitiated) {
                Self.buildHighlighted(language: lang, code: codeToShow)
            }.value
        }
    }

    private var displayLanguage: String {
        language.isEmpty ? "TEXT" : language.uppercased()
    }

    private var lineCount: Int {
        code.isEmpty ? 0 : code.components(separatedBy: "\n").count
    }

    private var isFoldable: Bool {
        lineCount > Self.foldThreshold
    }

    private var hiddenLineCount: Int {
        max(0, lineCount - Self.foldThreshold)
    }

    private var displayCode: String {
        if !isFoldable || expanded { return code }
        let lines = code.components(separatedBy: "\n")
        return lines.prefix(Self.foldThreshold).joined(separator: "\n")
    }

    nonisolated private static func buildHighlighted(language: String, code: String) -> AttributedString {
        let tokens = SyntaxHighlighter.highlight(language: language, code: code)
        guard !tokens.isEmpty else { return AttributedString(code) }
        var result = AttributedString()
        for token in tokens {
            var part = AttributedString(token.text)
            part.foregroundColor = color(for: token.kind)
            result += part
        }
        return result
    }

    nonisolated private static func color(for kind: HighlightTokenKind) -> Color {
        switch kind {
        case .plain:   return DS.t1
        case .keyword: return DS.gold
        case .string:  return Color(hex: 0x8CB394)  // muted sage — 与金互补、低饱和
        case .comment: return DS.t3
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            expanded.toggle()
        }
    }
}
