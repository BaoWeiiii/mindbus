import SwiftUI

/// MindBus Design System — SwiftUI Color & Style Tokens
/// 映射自 设计系统，禁止硬编码颜色值
enum DS {

    // MARK: - Foundation（灰阶，占界面 ~85%）

    /// Void：主背景，页面底色
    static let bg = Color(hex: 0x09090D)
    /// Surface：卡片、内容区块底色
    static let sf = Color(hex: 0x101014)
    /// Elevated：输入框、浮层底色
    static let sf2 = Color(hex: 0x17171C)
    /// Raised：Hover 态、选中态底色
    static let sf3 = Color(hex: 0x1E1E24)
    /// 极淡分隔线
    static let rule = Color.white.opacity(0.04)
    /// 稍强分隔线（表格行）
    static let ruleH = Color.white.opacity(0.07)

    // MARK: - Text（三级文字色）

    /// 主文字，暖白色（非纯白）
    static let t1 = Color(hex: 0xEDEBE4)
    /// 次要文字，说明、描述
    static let t2 = Color(hex: 0x87848F)
    /// 最弱文字，标注、placeholder、时间戳
    static let t3 = Color(hex: 0x4E4B57)

    // MARK: - Brand（暖金光谱，≤5%）

    /// 主强调色：按钮、活跃态、关键高亮
    static let gold = Color(hex: 0xDDB992)
    /// 辅助暖色：hover 底色提亮
    static let goldDim = Color(hex: 0xE8DCC8)
    /// Gold 的辉光/阴影
    static let goldG = Color(hex: 0xDDB992).opacity(0.10)

    // MARK: - System（功能色，≤2%）

    static let green = Color(hex: 0x4ADE80)
    static let greenG = Color(hex: 0x4ADE80).opacity(0.08)
    static let amber = Color(hex: 0xF5A623)
    static let amberG = Color(hex: 0xF5A623).opacity(0.08)
    static let red = Color(hex: 0xE8345A)
    static let redG = Color(hex: 0xE8345A).opacity(0.08)

    // MARK: - Border Radius

    /// 按钮、标签、输入框
    static let radiusSm: CGFloat = 3
    /// 卡片、头像
    static let radiusMd: CGFloat = 6

    // MARK: - Spacing

    static let spaceXs: CGFloat = 4
    static let spaceSm: CGFloat = 8
    static let spaceMd: CGFloat = 12
    static let spaceBase: CGFloat = 16
    static let spaceLg: CGFloat = 24
    static let spaceXl: CGFloat = 32

    // MARK: - Opacity

    static let opacityDisabled: Double = 0.38
    static let opacityHover: Double = 0.85
}

// MARK: - Light Theme（安装向导专用）

/// 亮色主题（与网站 globals.css :root 一致）
enum DSLight {
    // Foundation — 与网站 --bg-100/200/300/400 对齐
    static let bg = Color(hex: 0xFAF9F6)
    static let sf = Color(hex: 0xF0EFEB)
    static let sf2 = Color(hex: 0xE5E4E0)
    static let sf3 = Color(hex: 0xD8D7D3)
    static let rule = Color(hex: 0xE5E4E0)
    static let ruleH = Color(hex: 0xD4D3CF)

    // Text — 与网站 --text-100/200/300 对齐
    static let t1 = Color(hex: 0x1A1A1A)
    static let t2 = Color(hex: 0x2E2E2E)
    static let t3 = Color(hex: 0x555555)
    /// 第四级：时间戳 / 条数这类 meta 信息。
    /// 网站文字稀疏，三级够用；App 列表行一行要塞标题+预览+时间+条数，
    /// 只到 t3 会把层级压扁。取暖灰（R>G>B）与 bg #FAF9F6 同色温——
    /// 系统 .tertiary 是中性灰，压在暖底上会发脏，这正是必须自定义的理由。
    static let t4 = Color(hex: 0x8A8780)

    // Brand — 亮色主题用深金（设计系统 §1.4 Light=#A68450）。
    // 暗色金 #DDB992 在浅色面板上对比太低、几乎看不清。
    static let gold = Color(hex: 0xA68450)
    static let goldDim = Color(hex: 0xC4A06A)
    static let goldG = Color(hex: 0xA68450).opacity(0.12)

    // System — 不变
    static let green = DS.green
    static let greenG = DS.greenG
    static let amber = DS.amber
    static let red = DS.red
    static let redG = DS.redG

    // Spacing / Radius — 复用
    static let radiusSm = DS.radiusSm
    static let radiusMd = DS.radiusMd
    static let spaceXs = DS.spaceXs
    static let spaceSm = DS.spaceSm
    static let spaceMd = DS.spaceMd
    static let spaceBase = DS.spaceBase
    static let spaceLg = DS.spaceLg
    static let spaceXl = DS.spaceXl
    static let opacityDisabled = DS.opacityDisabled
}

// MARK: - Color Hex Init

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - MindBus Button Styles

/// Primary 按钮：Gold 底色 + 深色文字
struct MBPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(DS.gold)
            .cornerRadius(DS.radiusSm)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1.0) : DS.opacityDisabled)
    }
}

/// Secondary 按钮：sf2 底色 + t1 文字
struct MBSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(DS.t1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(configuration.isPressed ? DS.sf3 : DS.sf2)
            .cornerRadius(DS.radiusSm)
            .opacity(isEnabled ? 1.0 : DS.opacityDisabled)
    }
}

/// Ghost 按钮：无底色 + t3 文字
struct MBGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(DS.t3)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

/// Danger 按钮：无底色 + 红色文字
struct MBDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(DS.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? DS.redG : Color.clear)
            .cornerRadius(DS.radiusSm)
    }
}

// MARK: - Light Theme Button Styles（安装向导用）

/// 亮色 Primary：深金底色 + 白色文字
/// （必须用 DSLight.gold #A68450——暗色浅金 #DDB992 配白字对比只有 ~1.8:1，
///  这是 onboarding「下一步」主 CTA，看不清字是 P0 级）
struct MBLightPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(DSLight.gold)
            .cornerRadius(DSLight.radiusSm)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1.0) : DSLight.opacityDisabled)
    }
}

/// 亮色 Secondary：浅灰底色 + 深色文字
struct MBLightSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(DSLight.t1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(configuration.isPressed ? DSLight.sf3 : DSLight.sf2)
            .cornerRadius(DSLight.radiusSm)
            .opacity(isEnabled ? 1.0 : DSLight.opacityDisabled)
    }
}

/// 亮色 Ghost：无底色 + 灰色文字
struct MBLightGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(DSLight.t3)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

// MARK: - 行 hover 背景（TrayPanel + 对话列表共用）

/// 行 hover 背景：macOS 26 用 Liquid Glass（半透明玻璃，随悬停淡入），旧系统回退 sf2 实底。
struct RowHoverBackground: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background { hoverFill }
    }

    @ViewBuilder private var hoverFill: some View {
        let shape = RoundedRectangle(cornerRadius: DSLight.radiusMd)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .opacity(hovering ? 1 : 0)
        } else {
            shape.fill(hovering ? DSLight.sf2 : Color.clear)
        }
    }
}

extension View {
    func rowHoverBackground(_ hovering: Bool) -> some View {
        modifier(RowHoverBackground(hovering: hovering))
    }
}

/// 列表行状态背景：选中=金调玻璃（持久、明显），hover=无色玻璃（临时）；旧系统回退 goldG/sf2。
/// 不依赖 List 系统 selection（彻底无系统蓝）。
struct RowStateBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background { fill }
    }

    @ViewBuilder private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: DSLight.radiusMd)
        if #available(macOS 26.0, *) {
            if selected {
                Color.clear.glassEffect(.regular.tint(DSLight.gold.opacity(0.20)), in: shape)
            } else if hovering {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                Color.clear
            }
        } else {
            shape.fill(selected ? DSLight.goldG : (hovering ? DSLight.sf2 : Color.clear))
        }
    }
}

extension View {
    func rowStateBackground(selected: Bool, hovering: Bool) -> some View {
        modifier(RowStateBackground(selected: selected, hovering: hovering))
    }
}
