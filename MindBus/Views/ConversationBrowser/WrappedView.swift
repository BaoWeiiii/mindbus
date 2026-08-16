import SwiftUI
import MindBusCore
import AppKit

/// 「你的对话报告」——Wrapped 体裁的本地版(2026-08-12 行业调研落地)。
///
/// 设计三原则(调研结论):
/// 1. **全部纯统计,零 LLM 卡**——ChatGPT 版被吐槽的全是 LLM 层(谄媚诗/空洞预测),
///    被晒最多的卡(em-dash 计数/最忙一天)恰是纯统计;
/// 2. **跨工具分工卡是主打**——两家官方各只有自家数据,这是 MindBus 独有轴;
/// 3. **本地保存,绝不默认分享**(支付宝 2017 红线)——导出 PNG 落 ~/Downloads。
/// 时间范围 1/3/12 月 + 全部,学 Claude Reflect 的窗口化改造(年报体裁日常化)。
struct WrappedView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss

    enum Window: String, CaseIterable, Identifiable {
        case month1, month3, month12, all
        var id: String { rawValue }
        var label: (zh: String, en: String) {
            switch self {
            case .month1: return ("近 1 个月", "1 month")
            case .month3: return ("近 3 个月", "3 months")
            case .month12: return ("近 12 个月", "12 months")
            case .all: return ("全部", "All time")
            }
        }
        var from: Date {
            switch self {
            case .month1: return Date().addingTimeInterval(-30 * 86_400)
            case .month3: return Date().addingTimeInterval(-91 * 86_400)
            case .month12: return Date().addingTimeInterval(-365 * 86_400)
            case .all: return .distantPast
            }
        }
    }

    @State private var window: Window = .month3
    @State private var data: WrappedData?
    @State private var exportedURL: URL?
    /// 脱敏(方案原案「脱敏可分享」补全):隐藏含自由文本的卡(口头禅/第一场),
    /// 只留纯数字卡——分享图里不出现你的原话与项目细节。
    @State private var redacted = false

    private var isZh: Bool { l10n.s.sidebarMinds != "Minds" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DSLight.sf3)
            ScrollView {
                cardsColumn
                    .padding(.vertical, 28)
            }
            .background(DSLight.bg)
        }
        .frame(width: 520, height: 640)
        .onAppear { reload() }
        .onChange(of: window) { _ in reload() }
    }

    private func reload() {
        data = WrappedData.build(store: store, from: window.from)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(isZh ? "你的对话报告" : "Your Conversation Report")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(DSLight.t1)
            Picker("", selection: $window) {
                ForEach(Window.allCases) { w in
                    Text(isZh ? w.label.zh : w.label.en).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Spacer()
            Toggle(isOn: $redacted) {
                Text(isZh ? "脱敏" : "Redact").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help(isZh ? "隐藏原话与对话标题,只留数字——分享更安心" : "Hide verbatim text and titles — numbers only, safe to share")
            Button {
                exportPNG()
            } label: {
                Label(isZh ? "导出图片" : "Export", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12))
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DSLight.sf)
    }

    /// 卡片列(渲染与导出共用——ImageRenderer 渲这个)。
    private var cardsColumn: some View {
        Group {
            if let d = data {
                WrappedCards(data: d, isZh: isZh, redacted: redacted)
            } else {
                Text("…").foregroundStyle(DSLight.t3)
            }
        }
        .frame(maxWidth: .infinity)
    }

        // MARK: - 导出(本地保存,绝不默认分享)

    @MainActor
    private func exportPNG() {
        // 导出图带极轻落款(传播回路:被晒出去的图能被认出来;App 内不显示——
        // 调研纪律「展示用户不展示品牌」,落款小到不喧宾夺主)
        let renderer = ImageRenderer(content: VStack(spacing: 10) {
            cardsColumn
            Text("MindBus · github.com/BaoWeiiii/mindbus")
                .font(BrandFont.mono(9)).foregroundStyle(DSLight.t3.opacity(0.7))
        }
            .padding(.vertical, 28)
            .frame(width: 520)
            .background(DSLight.bg))
        renderer.scale = 2
        guard let png = renderer.nsImage?.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?
            .representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let stamp = WrappedCards.dayString(Date())
        let url = dir.appendingPathComponent("MindBus-Report-\(stamp).png")
        try? png.write(to: url)
        exportedURL = url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Wrapped 数据包:全部纯统计,一次窗口查询组装。
struct WrappedData {
    let conversationCount: Int
    let bySource: [ConversationIndex.FacetCount]
    let busiestDay: (day: String, count: Int)?
    let hourQuarters: [Int]
    let catchphrases: [(phrase: String, count: Int)]
    let volume: (userChars: Int, totalChars: Int)
    let first: ConversationIndex.UnfinishedThread?
    let activeDayCount: Int
    // 分型卡四轴输入(全部机械指标,counted not generated)
    let shape: ConversationIndex.CollaborationShape?
    let avgProjectsPerDay: Double
    let topSourceShare: Int   // 第一工具占比 %

    @MainActor
    static func build(store: ConversationStore, from: Date) -> WrappedData {
        let to = Date().addingTimeInterval(1)
        let bySource = store.wrappedSourceCounts(from: from, to: to)
        let corpus = store.wrappedUserCorpus(from: from)
        return WrappedData(
            conversationCount: bySource.reduce(0) { $0 + $1.count },
            bySource: bySource,
            busiestDay: store.wrappedBusiestDay(from: from, to: to),
            hourQuarters: store.wrappedHourQuarters(from: from, to: to),
            catchphrases: MindsBuilder.catchphrases(corpus: corpus, limit: 3),
            volume: store.wrappedVolume(from: from, to: to),
            first: store.wrappedFirstConversation(from: from, to: to),
            activeDayCount: store.wrappedActiveDays(from: from),
            shape: store.vizShape(),
            avgProjectsPerDay: store.wrappedSwitchingAvg(),
            topSourceShare: {
                let total = bySource.reduce(0) { $0 + $1.count }
                guard total > 0, let top = bySource.first else { return 0 }
                return top.count * 100 / total
            }())
    }
}

/// 卡片列本体——独立 View 供离屏渲染注入假数据验证(sheet 是渲染盲区)。
struct WrappedCards: View {
    let data: WrappedData
    let isZh: Bool
    var redacted: Bool = false

    var body: some View {
        let d = data
        VStack(spacing: 16) {
            openingCard(d)
            if d.bySource.count > 1 { crossToolCard(d) }
            if let b = d.busiestDay { busiestCard(b, total: d.conversationCount) }
            rhythmCard(d)
            // 脱敏:口头禅是你的原话、第一场含对话标题——隐藏这两张,其余全是纯数字
            if !redacted, !d.catchphrases.isEmpty { catchphraseCard(d) }
            if d.volume.userChars > 0 { leverageCard(d) }
            if !redacted, let f = d.first { archaeologyCard(f) }
            if d.shape != nil { archetypeCard(d) }
            closingCard(d)
        }
        .frame(width: 440)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 14))
    }

    private func kicker(_ text: String) -> some View {
        Text(text).font(BrandFont.mono(10)).kerning(1.4).foregroundStyle(DSLight.t3)
    }

    private func bigNumber(_ text: String) -> some View {
        Text(text).font(BrandFont.mono(34, weight: .medium)).foregroundStyle(DSLight.gold)
    }

    private func openingCard(_ d: WrappedData) -> some View {
        card {
            kicker(isZh ? "总量" : "VOLUME")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                bigNumber("\(d.conversationCount)")
                Text(isZh ? "场对话" : "conversations").font(.system(size: 13)).foregroundStyle(DSLight.t2)
            }
            Text(isZh ? "你打了 \(MindsBuilder.compactChars(d.volume.userChars)) 字"
                      : "you typed \(MindsBuilder.compactChars(d.volume.userChars)) characters")
                .font(.system(size: 12)).foregroundStyle(DSLight.t2)
        }
    }

    /// 主打卡:跨工具分工——只有收全量对话的 MindBus 能画这张图。
    private func crossToolCard(_ d: WrappedData) -> some View {
        let maxN = d.bySource.map(\.count).max() ?? 1
        return card {
            kicker(isZh ? "跨工具 · 只有这里能看全" : "ACROSS TOOLS · ONLY VISIBLE HERE")
            ForEach(d.bySource, id: \.key) { s in
                HStack(spacing: 10) {
                    Text(s.key).font(BrandFont.mono(12)).foregroundStyle(DSLight.t1)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DSLight.gold.opacity(0.72))
                            .frame(width: max(4, geo.size.width * CGFloat(s.count) / CGFloat(maxN)))
                    }
                    .frame(height: 8)
                    .background(DSLight.sf2, in: RoundedRectangle(cornerRadius: 3))
                    Text("\(s.count)").font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private func busiestCard(_ b: (day: String, count: Int), total: Int) -> some View {
        card {
            kicker(isZh ? "最忙的一天" : "BUSIEST DAY")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                bigNumber("\(b.count)")
                Text(isZh ? "场 · \(b.day)" : "conversations · \(b.day)")
                    .font(.system(size: 13)).foregroundStyle(DSLight.t2)
            }
            if total > 0 {
                Text(isZh ? "占这段时间全部对话的 \(b.count * 100 / total)%"
                          : "\(b.count * 100 / total)% of everything, in one day")
                    .font(.system(size: 12)).foregroundStyle(DSLight.t2)
            }
        }
    }

    private func rhythmCard(_ d: WrappedData) -> some View {
        let names = ["00-04", "04-08", "08-12", "12-16", "16-20", "20-24"]
        let maxQ = d.hourQuarters.max() ?? 1
        return card {
            kicker(isZh ? "作息" : "RHYTHM")
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(d.hourQuarters[i] == maxQ ? DSLight.gold : DSLight.gold.opacity(0.35))
                            .frame(width: 34, height: max(4, 52 * CGFloat(d.hourQuarters[i]) / CGFloat(max(maxQ, 1))))
                        Text(names[i]).font(BrandFont.mono(9)).foregroundStyle(DSLight.t3)
                    }
                }
            }
        }
    }

    private func catchphraseCard(_ d: WrappedData) -> some View {
        card {
            kicker(isZh ? "口头禅" : "CATCHPHRASES")
            ForEach(d.catchphrases.prefix(3), id: \.phrase) { c in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\u{201C}\(c.phrase)\u{201D}")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(DSLight.t1)
                    Text("×\(c.count)").font(BrandFont.mono(13)).foregroundStyle(DSLight.gold)
                }
            }
        }
    }

    private func leverageCard(_ d: WrappedData) -> some View {
        let ratio = d.volume.userChars > 0 ? d.volume.totalChars / d.volume.userChars : 0
        return card {
            kicker(isZh ? "杠杆率" : "LEVERAGE")
            bigNumber("1:\(ratio)")
            Text(isZh ? "你的 \(MindsBuilder.compactChars(d.volume.userChars)) 字,换回 \(MindsBuilder.compactChars(d.volume.totalChars)) 字的工作记录"
                      : "\(MindsBuilder.compactChars(d.volume.userChars)) chars in, \(MindsBuilder.compactChars(d.volume.totalChars)) chars of work back")
                .font(.system(size: 12)).foregroundStyle(DSLight.t2)
        }
    }

    /// 第一次对话考古——官方 Wrapped 因隐私不敢引原文,本地无此顾虑(空白点)。
    private func archaeologyCard(_ f: ConversationIndex.UnfinishedThread) -> some View {
        card {
            kicker(isZh ? "这段时间的第一场" : "WHERE IT STARTED")
            Text(f.title?.isEmpty == false ? f.title! : f.preview)
                .font(.system(size: 14)).foregroundStyle(DSLight.t1).lineLimit(2)
            Text(Self.dayString(f.endAt) + " · " + ((f.cwd as NSString).lastPathComponent))
                .font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
        }
    }

    /// 四轴机械分型(观察项 C):每轴二分,型名=描述性组合,四轴数值附在下方——
    /// 「counted not generated」纪律:分型不是算命,每一轴都能对回数字。
    private func archetypeCard(_ d: WrappedData) -> some View {
        let sh = d.shape!
        let hq = d.hourQuarters
        let evening = (hq.count == 6 && hq.reduce(0, +) > 0)
            ? (hq[4] + hq[5]) * 100 / hq.reduce(0, +) : 0   // 16-24 时段占比
        let marathon = sh.durationBands.reduce(0, +) > 0
            ? sh.durationBands[3] * 100 / sh.durationBands.reduce(0, +) : 0
        let deep = sh.turnBands.reduce(0, +) > 0
            ? sh.turnBands[3] * 100 / sh.turnBands.reduce(0, +) : 0
        let axisTime = evening >= 50
        let axisDepth = deep >= 50
        let axisSession = marathon >= 25
        let axisFocus = d.topSourceShare >= 70
        let nameZh = (axisTime ? "暮色" : "晨光") + (axisDepth ? "深耕者" : "巡游者")
        let nameEn = (axisTime ? "Evening " : "Daylight ") + (axisDepth ? "Cultivator" : "Explorer")
        let tags: [(String, String)] = [
            (axisTime ? (isZh ? "晚间型" : "evening") : (isZh ? "日间型" : "daytime"),
             "\(evening)% 16-24h"),
            (axisDepth ? (isZh ? "共事型" : "co-worker") : (isZh ? "问答型" : "asker"),
             "\(deep)% 16+ turns"),
            (axisSession ? (isZh ? "马拉松" : "marathon") : (isZh ? "速查型" : "sprinter"),
             "\(marathon)% 2h+"),
            (axisFocus ? (isZh ? "单工具主力" : "one-tool") : (isZh ? "多工具" : "multi-tool"),
             "\(d.topSourceShare)% top tool"),
        ]
        return card {
            kicker(isZh ? "你的型" : "YOUR ARCHETYPE")
            Text(isZh ? nameZh : nameEn)
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(DSLight.gold)
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                HStack(spacing: 8) {
                    Circle().fill(DSLight.gold.opacity(0.6)).frame(width: 4, height: 4)
                    Text(tag.0).font(.system(size: 12)).foregroundStyle(DSLight.t1)
                    Text(tag.1).font(BrandFont.mono(10)).foregroundStyle(DSLight.t3)
                }
            }
        }
    }

    private func closingCard(_ d: WrappedData) -> some View {
        card {
            kicker(isZh ? "收尾" : "KEEP")
            Text(isZh ? "活跃 \(d.activeDayCount) 天。模型是租的,对话是你的。"
                      : "Active on \(d.activeDayCount) days. Models are rented; the conversations are yours.")
                .font(.system(size: 13)).foregroundStyle(DSLight.t1)
            // token 锚(观察项 D):中性技术单位——美元估值会把 110 天的思考标成
            // 一顿饭钱(价值感调研:给数字选骄傲极性),token 数只陈述体量不调度
            if d.volume.totalChars > 0 {
                Text(isZh ? "≈ \(MindsBuilder.compactChars(d.volume.totalChars * 5 / 9)) tokens 的真实工作——任何 API 都无法为你重新生成。"
                          : "≈ \(MindsBuilder.compactChars(d.volume.totalChars * 5 / 9)) tokens of lived work — no API can regenerate it.")
                    .font(.system(size: 12)).foregroundStyle(DSLight.t2)
            }
            // 传承句(1 Second Everyday「someday」话术:现在的小积累 × 时间 = 未来的大礼物)
            Text(isZh ? "某一天,你会一口气读完这些年的自己。"
                      : "Someday, you'll read these years of yourself in one sitting.")
                .font(.system(size: 12)).foregroundStyle(DSLight.t2)
        }
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
