import SwiftUI
import MindBusCore

// MARK: - 工具品牌标记
//
// 用官方 logo（claude-mark / openai-mark，黑底透明 PNG，源自 simple-icons / openai-codex 仓），
// 以 SwiftUI template 模式按 tile 着色。属设计系统 §1.6「第三方品牌色除外」例外。
// 非选中态：去色（saturation 0）+ 淡化，让选中工具的品牌色「亮起来」= 聚焦信号。
//
// Claude Code 与 Claude 同为 Anthropic 的 Claude 标，靠 tile 底色区分：
//   Claude Code = 深底珊瑚标 / Claude = 珊瑚底奶白标 / Codex = 浅底墨色花瓣结。

enum ToolBrand {
    static let claudeCoral = Color(hex: 0xD97757)
    static let claudeCream = Color(hex: 0xFAF9F6)
    static let ink = Color(hex: 0x1A1A1A)
    static let codexBase = Color(hex: 0xF2F1EC)
}

/// 官方 logo 缓存（NSImage，isTemplate 以便 foregroundStyle 着色）。
enum ToolMarkImage {
    static let claude = load("claude-mark")
    static let openai = load("openai-mark")

    /// 来源 → 官方 mark（ToolTile 与列表圆底徽章共用同一映射）。
    static func mark(for source: ConversationSource) -> NSImage? {
        switch source {
        case .claudeCode, .claudeAgent: return claude
        case .codex:                    return openai
        default:                        return nil
        }
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }
}

/// 列表行来源徽章：28px 圆形浅底（DSLight.sf2）+ 16px 官方 mark 居中。
/// 中性灰去色——品牌色 tile 只给侧栏「当前选中工具」，列表满屏亮色是噪音
/// （与 ToolTile active:false 同一理由）。
struct ToolSourceBadge: View {
    let source: ConversationSource

    var body: some View {
        ZStack {
            Circle().fill(DSLight.sf2)
            if let img = ToolMarkImage.mark(for: source) {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(DSLight.t3)
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// 工具方形 tile（app-icon 风），非选中去色 + 淡化。
struct ToolTile: View {
    let source: ConversationSource
    var active: Bool = true
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            // 未选中：统一中性灰 tile（三个一致，避免明度差）；选中：品牌色 tile 亮起
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(active ? tileColor : DSLight.sf2)
            if let img = markImage {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(active ? markColor : DSLight.t3)
                    .frame(width: size * 0.62, height: size * 0.62)
            }
        }
        .frame(width: size, height: size)
        .opacity(active ? 1 : 0.9)
    }

    private var markImage: NSImage? {
        ToolMarkImage.mark(for: source)
    }

    private var tileColor: Color {
        switch source {
        case .claudeCode:  return ToolBrand.ink
        case .claudeAgent: return ToolBrand.claudeCoral
        case .codex:       return ToolBrand.codexBase
        default:           return DSLight.sf2
        }
    }

    private var markColor: Color {
        switch source {
        case .claudeCode:  return ToolBrand.claudeCoral
        case .claudeAgent: return ToolBrand.claudeCream
        case .codex:       return ToolBrand.ink
        default:           return DSLight.t3
        }
    }
}
