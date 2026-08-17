import SwiftUI

/// Minds 模块的视觉底座（2026-08-17 UI 重构规范）。
///
/// 为什么不直接改 `DSLight`：那套 token 服务全 App（列表/详情/设置），
/// 这里要的是「白卡 + 1px 描边 + 暖白页底」的档案感，与列表页「无描边、靠背景
/// 色阶分层」是两种语言。改全局会波及所有界面，所以本模块自带一套，
/// 色相仍与 DSLight 同源（页底就是 `DSLight.bg`），不引入第二种色温。
enum MindsUI {

    // MARK: - 面

    /// 页底：暖白，不是纯白
    static let page = Color(hex: 0xFAF9F6)
    /// 卡片底
    static let surface = Color.white
    /// 卡内更浅一层的底（子行、轨道背景）
    static let surfaceSoft = Color(hex: 0xF8F6F1)
    /// 可点元素悬停
    static let surfaceHover = Color(hex: 0xF4F1EA)
    static let border = Color(hex: 0xE8E4DD)

    // MARK: - 强调色（全模块只有这一种）

    static let accent = Color(hex: 0xB88943)
    static let accentStrong = Color(hex: 0xA97730)
    static let accentSoft = Color(hex: 0xE5D3B4)
    static let accentBG = Color(hex: 0xF6EFE3)

    // MARK: - 文字

    static let textPrimary = Color(hex: 0x181715)
    static let textSecondary = Color(hex: 0x625F59)
    static let textTertiary = Color(hex: 0x99948C)

    // MARK: - 图表

    /// 图表轨道（条形底）
    static let chartTrack = Color(hex: 0xECE8E1)
    /// 非主要数据
    static let chartMuted = Color(hex: 0xD9C7AA)

    /// 热力图 5 档（0 档是「没有对话」，不是浅金）
    static let heat: [Color] = [
        Color(hex: 0xEEECE7), Color(hex: 0xE4D9C7), Color(hex: 0xD7C3A2),
        Color(hex: 0xC5A069), Color(hex: 0xA97937),
    ]

    // MARK: - 尺度

    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 20
    static let cardGap: CGFloat = 15
    static let moduleGap: CGFloat = 26
    static let contentMaxWidth: CGFloat = 1160
    /// 低于这个宽度，双栏一律拆成单栏（窄窗不能靠横向滚动解决）
    static let singleColumnBelow: CGFloat = 760
}

/// 「图标对齐大数字的视觉中心」。
///
/// 默认的 `.center` 会让图标去对齐「数字 + 标签」整块的中心，看上去比数字低半行；
/// `.firstTextBaseline` 又会落到数字底边。这两种都不是设计要的——要的是图标中心
/// 与数字中心齐平，所以自定义一条对齐轴，由数字那一行自己声明位置。
enum MindsMetricCenter: AlignmentID {
    static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
}

extension VerticalAlignment {
    static let mindsMetricCenter = VerticalAlignment(MindsMetricCenter.self)
}

// MARK: - 卡片

/// 统一卡片：白底 + 1px 描边 + 14 圆角 + 极弱阴影。
/// `fill` 让并排的两张卡拉到等高（短的那张不吊在半空）。
struct MindsCardStyle: ViewModifier {
    var padding: CGFloat = MindsUI.cardPadding
    var fill: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity,
                   maxHeight: fill ? .infinity : nil,
                   alignment: .topLeading)
            .background(MindsUI.surface, in: RoundedRectangle(cornerRadius: MindsUI.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: MindsUI.cardRadius)
                    .stroke(MindsUI.border, lineWidth: 1)
            }
            .shadow(color: Color(red: 40 / 255, green: 32 / 255, blue: 20 / 255).opacity(0.025),
                    radius: 10, x: 0, y: 6)
    }
}

extension View {
    func mindsCard(padding: CGFloat = MindsUI.cardPadding, fill: Bool = true) -> some View {
        modifier(MindsCardStyle(padding: padding, fill: fill))
    }

    /// 表格数字对齐（等宽数位），中文照常走系统字形。
    func mindsTabularNumbers() -> some View { monospacedDigit() }
}

// MARK: - 标题

/// 模块标题 + 同行说明。整页只有这一种模块题头形态。
struct MindsSectionHeader: View {
    let title: String
    var hint: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MindsUI.textPrimary)
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(MindsUI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }
}

/// 卡内小标题（比模块标题低一级）
struct MindsCardTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MindsUI.textPrimary)
    }
}

// MARK: - 通用零件

/// 一条洞察：极小线性图标 + 主句 + 副句。图标一律走 SF Symbols 线性字重，
/// 不混 emoji（emoji 是彩色实心的，和线性图标放一起像两套系统）。
struct MindsInsightRow: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .mindsMetricCenter, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(MindsUI.accent)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(MindsUI.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    // 图标对齐主句中心；副句换行时图标也不会跟着往下跑
                    .alignmentGuide(.mindsMetricCenter) { $0[VerticalAlignment.center] }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(MindsUI.textSecondary)
                        .mindsTabularNumbers()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 水平条排行的一行：名称 | 轨道+条 | 右侧数值。
/// 轨道必须画出来——没有轨道时最短的一条会缩成一个点，读不出相对量。
struct MindsBarRow: View {
    let label: String
    let value: Int
    let maxValue: Int
    let trailing: String
    var labelWidth: CGFloat = 56
    var trailingWidth: CGFloat = 92
    var isTop: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(MindsUI.textPrimary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MindsUI.chartTrack)
                    Capsule()
                        .fill(isTop ? MindsUI.accent : MindsUI.chartMuted)
                        .frame(width: max(6, geo.size.width * ratio))
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            Text(trailing)
                .font(.system(size: 12))
                .foregroundStyle(MindsUI.textSecondary)
                .mindsTabularNumbers()
                .lineLimit(1)
                .frame(width: trailingWidth, alignment: .trailing)
        }
        .frame(height: 20)
    }

    private var ratio: CGFloat {
        guard maxValue > 0 else { return 0 }
        return CGFloat(value) / CGFloat(maxValue)
    }
}

/// 词条胶囊。`emphasis` 只给前三名，其余一律同尺寸浅底——
/// 尺寸随强弱变会让每一行高低不齐，深金大面积铺开则等于没有重点。
struct MindsTagChip: View {
    let word: String
    let meta: String
    var emphasis: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(word)
                    .font(.system(size: 12.5, weight: emphasis ? .semibold : .medium))
                    .foregroundStyle(emphasis ? MindsUI.accentStrong : MindsUI.accent)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(MindsUI.textSecondary)
                        .mindsTabularNumbers()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(chipBG, in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var chipBG: Color {
        if hovering { return MindsUI.surfaceHover }
        return emphasis ? Color(hex: 0xEEE1CC) : Color(hex: 0xF6F2EB)
    }
}

/// 迷你消退曲线：过去一段时间该词的出现频率，无坐标轴。
struct MindsMiniSparkline: View {
    let series: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(series.max() ?? 1, 1)
            let w = geo.size.width, h = geo.size.height
            let step = series.count > 1 ? w / CGFloat(series.count - 1) : w
            Path { p in
                for (i, v) in series.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: h - h * CGFloat(v) / CGFloat(maxV))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(MindsUI.accent.opacity(0.8),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 60, height: 20)
    }
}

/// 环形图。macOS 13 没有 Swift Charts 的 `SectorMark`（要 14），所以自绘：
/// 四段按同一个金色的四级明度排，不引入第二种色相。
struct MindsDonut: View {
    /// 已按展示顺序排好的分段值
    let values: [Int]
    var lineWidth: CGFloat = 16

    private var total: Int { max(values.reduce(0, +), 1) }

    /// 由深到浅——第一段（最短对话）用最浅，越往后越深，读起来是「越聊越深」
    static func shade(_ i: Int, of n: Int) -> Color {
        let steps: [Double] = [0.28, 0.48, 0.7, 1.0]
        return MindsUI.accent.opacity(steps[min(i, steps.count - 1)])
    }

    var body: some View {
        ZStack {
            ForEach(Array(values.enumerated()), id: \.offset) { i, _ in
                Circle()
                    .trim(from: start(i), to: end(i))
                    .stroke(Self.shade(i, of: values.count),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }

    private func start(_ i: Int) -> CGFloat {
        CGFloat(values.prefix(i).reduce(0, +)) / CGFloat(total)
    }
    private func end(_ i: Int) -> CGFloat {
        CGFloat(values.prefix(i + 1).reduce(0, +)) / CGFloat(total)
    }
}

/// 统一 Tooltip：深底白字圆角。系统 `.help()` 的样式不可控且延迟长，
/// 图表上需要跟手，所以自绘一层覆盖。
struct MindsTooltip: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l)
                    .font(.system(size: 12, weight: i == 0 ? .medium : .regular))
                    .foregroundStyle(i == 0 ? Color.white : Color.white.opacity(0.78))
                    .mindsTabularNumbers()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(red: 30 / 255, green: 28 / 255, blue: 25 / 255).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

// MARK: - 骨架

/// 骨架条。整页一个转圈会让人不知道在等什么，也会在数据到位时整页跳版；
/// 每张卡各自占位、保持原结构，加载完只是内容换上去。
struct MindsSkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    /// 同一张卡里多条错开起拍，避免整片一起闪
    var phase: Double = 0

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: height / 3)
            .fill(MindsUI.chartTrack)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .opacity(dim ? 0.45 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        .delay(phase), value: dim)
            .onAppear { dim = true }
    }
}

/// 卡片正文的骨架。形状要照着真实内容排——图文顺序反了的话，数据到位时
/// 会看到内容"换了个位置"，比没有骨架还乱。
struct MindsSkeletonBody: View {
    var chartHeight: CGFloat?
    var lines: Int = 3
    /// 真实布局里图在文字上方就留 true；工作节律那种「先四条洞察、后柱图」传 false
    var chartFirst: Bool = true

    private static let widths: [CGFloat] = [230, 300, 190, 260]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if chartFirst { chart }
            ForEach(0..<lines, id: \.self) { i in
                MindsSkeletonBar(width: Self.widths[i % Self.widths.count],
                                 height: 11, phase: Double(i) * 0.12)
            }
            if !chartFirst { chart }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let chartHeight { MindsSkeletonBar(height: chartHeight) }
    }
}

/// 格子阵骨架。热力图用一整块大矩形占位会像「渲染出错」，
/// 拆成七行才认得出这是那张图。
struct MindsSkeletonGrid: View {
    var rows: Int = 7
    var rowHeight: CGFloat = 17
    var gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            MindsSkeletonBar(width: 180, height: 9)
                .padding(.bottom, 2)
            ForEach(0..<rows, id: \.self) { i in
                MindsSkeletonBar(width: nil, height: rowHeight, phase: Double(i) * 0.08)
            }
        }
    }
}

/// 数据不够时的说明。不显示一排 0——0 会被读成「我这个月一场没聊」。
struct MindsEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MindsUI.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 双栏：窄到放不下时自动落成单栏，绝不让页面横向滚动。
struct MindsTwoColumn<A: View, B: View>: View {
    /// 落成单栏后两块之间的距离。默认按「两张卡片」给模块间距；
    /// 卡片**内部**的双栏（例如工作节律的洞察 + 柱图）要传小值，
    /// 否则同一张卡里会裂出一条和卡间一样宽的沟。
    var stackedSpacing: CGFloat = MindsUI.moduleGap
    /// 两半在**同一张卡内**时传 true：落成上下排列后给一条细线，
    /// 否则文字与图之间那片空白分不清是留白还是没渲出来。
    /// 卡片与卡片配对时不要开——那会在两张卡中间画一条不属于任何一张的线。
    var stackedDivider: Bool = false
    @ViewBuilder var left: () -> A
    @ViewBuilder var right: () -> B

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: MindsUI.cardGap) {
                left().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                right().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: MindsUI.singleColumnBelow)
            VStack(alignment: .leading, spacing: stackedSpacing) {
                left()
                if stackedDivider {
                    Rectangle().fill(MindsUI.border.opacity(0.7)).frame(height: 1)
                }
                right()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
