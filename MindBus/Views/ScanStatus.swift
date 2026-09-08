import SwiftUI
import MindBusCore

/// 后台扫描的状态文案：阶段 + 预计剩余。侧栏底部状态行与首启欢迎页共用同一套口径。
enum ScanStatus {

    /// 阶段文案每隔这么久换一句
    static let messageInterval: TimeInterval = 4

    /// nil = 没有在跑的后台活动。文案按本段经过的时间轮换；还没有可报的时间
    /// （各来源还在清点要读多少）时只有文案。
    @MainActor
    static func text(_ p: ScanProgress, _ l10n: L10n) -> String? {
        let messages: [String]
        switch p.phase {
        case .planning, .indexing: messages = l10n.s.scanMsgsIndexing
        case .archiving: messages = l10n.s.scanMsgsArchiving
        case .profiling: messages = l10n.s.scanMsgsProfiling
        case .finishing: return l10n.s.scanTidying
        case .idle, .done: return nil
        }
        let message = messages[Int(p.phaseElapsed / messageInterval) % max(1, messages.count)]
        guard let s = p.remainingSeconds else { return message + "…" }
        return l10n.s.statusJoin(message, etaText(s, l10n))
    }

    /// 剩余时间：<5s「马上就好」、<60s 逐秒倒数（值本身已在 ScanProgress 里平滑）、之后按分钟向上取整。
    @MainActor
    static func etaText(_ s: TimeInterval, _ l10n: L10n) -> String {
        if s < 5 { return l10n.s.etaSoon }
        if s < 60 { return l10n.s.etaSeconds(Int(s.rounded(.up))) }
        return l10n.s.etaMinutes(Int((s / 60).rounded(.up)))
    }

    @MainActor
    static func isActive(_ p: ScanProgress) -> Bool {
        switch p.phase {
        case .idle, .done: return false
        default: return true
        }
    }
}

/// 12pt 小环：sf3 轨道 + 金色弧，弧长只随真实进度走；动画放慢到 0.9s，
/// 让它看起来是「在缓慢前进」而不是一格一格跳。
///
/// 弧长用本地状态 + withAnimation 推进，而不是在弧上挂 `.animation(value:)`：
/// 后者会把同一拍里发生的布局位移（旁边的倒计时文字每秒变宽窄，环跟着左右挪）
/// 也拖成 0.9 秒的慢动作，轨道立刻到位、弧慢慢飘过去，两者短暂出现在两个地方。
struct ProgressRing: View {
    let fraction: Double
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(DSLight.sf3, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, shown)))
                .stroke(DSLight.gold, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { shown = fraction }
        .onChange(of: fraction) { f in
            withAnimation(.linear(duration: 0.9)) { shown = f }
        }
    }
}
