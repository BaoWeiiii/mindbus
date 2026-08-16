import SwiftUI
import Charts
import MindBusCore

/// Minds 可视化组件集(2026-08-12 方案定稿)。
///
/// 设计纪律(调研共识):金色单色系(强度=深浅/透明度,不引第二色相);
/// 小图无轴无网格无图例(Apple 规范:小图是预告);同构数据同形;
/// 图表是文字行的补充不是替换(Lupi:数字连回人话)。
/// 全部 Swift Charts macOS 13 集(BarMark/AreaMark)+ 自绘滑条,零外部依赖;
/// 不碰滚动 API——ImageRenderer 视觉验证链路不断。
enum MindsCharts {

    // MARK: - ① 24 格节律条带(WORK RHYTHM)

    /// 线性 24 格(调研否决径向钟面:线性认知更优,深夜占比 2.8% 不构成钟面理由)。
    /// 峰值实金、其余按量淡金;每 6 格一个小时刻度字。
    struct HourlyStrip: View {
        let hours: [Int]   // 24 桶

        var body: some View {
            let maxV = max(hours.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 4) {
                // x 用 zero-padded 字符串类别轴:Int 连续量 + ratio 宽度在 ImageRenderer
                // 下渲空(2026-08-12 探针实证),类别轴离屏在屏皆稳;补零保字典序=数值序。
                Chart(Array(hours.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("hour", String(format: "%02d", hour)), y: .value("count", count))
                        .foregroundStyle(count == maxV ? DSLight.gold : DSLight.gold.opacity(0.18 + 0.5 * Double(count) / Double(maxV)))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                HStack {
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text(String(format: "%02d", h)).font(BrandFont.mono(9)).foregroundStyle(DSLight.t3)
                        if h != 18 { Spacer() }
                    }
                    Text("24").font(BrandFont.mono(9)).foregroundStyle(DSLight.t3)
                }
            }
        }
    }

    // MARK: - ② 月度面积图(THIS MONTH)

    /// byMonth 全序列;金色渐变填充,当前月端点金点+数字(Tufte sparkline 规范)。
    struct MonthlyFlow: View {
        let months: [(month: String, count: Int)]

        var body: some View {
            Chart {
                ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                    AreaMark(x: .value("m", i), y: .value("c", m.count))
                        .foregroundStyle(LinearGradient(colors: [DSLight.gold.opacity(0.35), DSLight.gold.opacity(0.04)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("m", i), y: .value("c", m.count))
                        .foregroundStyle(DSLight.gold.opacity(0.8))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if let last = months.indices.last {
                    PointMark(x: .value("m", last), y: .value("c", months[last].count))
                        .foregroundStyle(DSLight.gold)
                        .symbolSize(36)
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("\(months[last].count)")
                                .font(BrandFont.mono(10, weight: .medium)).foregroundStyle(DSLight.gold)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 0, to: months.count, by: max(1, months.count / 6)))) { v in
                    AxisValueLabel {
                        if let i = v.as(Int.self), months.indices.contains(i) {
                            Text(String(months[i].month.suffix(2)))
                                .font(BrandFont.mono(9)).foregroundStyle(DSLight.t3)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 88)
        }
    }

    // MARK: - ③ 双峰直方 + 轮次条(COLLABORATION SHAPE)

    /// 时长 4 桶直方(「双峰」本来就是图形概念)与轮次 4 桶,并排两张小图。
    struct ShapeHistograms: View {
        let shape: ConversationIndex.CollaborationShape
        let durationLabels: [String]
        let turnLabels: [String]

        var body: some View {
            HStack(spacing: 24) {
                miniHistogram(values: shape.durationBands, labels: durationLabels)
                miniHistogram(values: shape.turnBands, labels: turnLabels)
            }
        }

        private func miniHistogram(values: [Int], labels: [String]) -> some View {
            let maxV = max(values.max() ?? 1, 1)
            return VStack(spacing: 4) {
                Chart(Array(values.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("b", "\(i)"), y: .value("v", v), width: .fixed(26))
                        .foregroundStyle(v == maxV ? DSLight.gold : DSLight.gold.opacity(0.35))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 52)
                HStack {
                    ForEach(labels, id: \.self) { l in
                        Text(l).font(BrandFont.mono(8)).foregroundStyle(DSLight.t3)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - ④ 杠杆双层条(LEVERAGE)

    /// Oura 式单色双层编码:淡金全长=对话总量,实金短段=你打的字。1:N 一眼可见。
    struct LeverageBar: View {
        let userChars: Int
        let totalChars: Int

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DSLight.gold.opacity(0.16))
                    Capsule().fill(DSLight.gold)
                        .frame(width: max(6, geo.size.width * CGFloat(userChars) / CGFloat(max(totalChars, 1))))
                }
            }
            .frame(height: 10)
        }
    }

    // MARK: - ⑤ 周几 7 柱(WEEKEND SELF)

    /// 周一..周日;周末两根实金、工作日淡金——「周末的形状」一眼可见。
    struct WeekdayBars: View {
        let days: [Int]   // 7 桶,周一=0
        let labels: [String]

        var body: some View {
            VStack(spacing: 4) {
                Chart(Array(days.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("d", "\(i)"), y: .value("v", v), width: .fixed(30))
                        .foregroundStyle(i >= 5 ? DSLight.gold : DSLight.gold.opacity(0.3))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 56)
                HStack {
                    ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                        Text(l).font(BrandFont.mono(9))
                            .foregroundStyle(i >= 5 ? DSLight.gold : DSLight.t3)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - ⑥ 个人史百分位滑条(WORK RHYTHM 的 P 行)

    /// Savant 滑条单色化:浅灰轨道 + 金气泡含数字,气泡深浅随分位。自绘 Capsule。
    struct PercentileSlider: View {
        let percentile: Int   // 0-100

        var body: some View {
            GeometryReader { geo in
                let x = geo.size.width * CGFloat(percentile) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(DSLight.sf3).frame(height: 4)
                    Text("P\(percentile)")
                        .font(BrandFont.mono(9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DSLight.gold.opacity(0.5 + 0.5 * Double(percentile) / 100), in: Capsule())
                        .offset(x: min(max(0, x - 16), geo.size.width - 34))
                }
            }
            .frame(height: 18)
        }
    }

    // MARK: - 二期:行内 sparkline 族

    /// 时间跨度线段(RECURRING):全库时间轴上 first→last 的位置。词级尺寸,无轴。
    struct SpanLine: View {
        let start: Double   // 0-1(相对全库范围)
        let end: Double

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DSLight.sf3).frame(height: 3)
                    Capsule().fill(DSLight.gold.opacity(0.7))
                        .frame(width: max(4, geo.size.width * CGFloat(end - start)), height: 3)
                        .offset(x: geo.size.width * CGFloat(start))
                    Circle().fill(DSLight.gold).frame(width: 5, height: 5)
                        .offset(x: geo.size.width * CGFloat(end) - 2.5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 72, height: 12)
        }
    }

    /// 消退曲线(FADED WORDS):近 12 月出现次数折线——「说得多→归零」的形状。
    /// 词级 Path 自绘(Tufte sparkline:无轴,当前值即末端归零本身是叙事)。
    struct DecaySparkline: View {
        let series: [Int]

        var body: some View {
            GeometryReader { geo in
                let maxV = max(series.max() ?? 1, 1)
                let w = geo.size.width
                let h = geo.size.height
                let step = series.count > 1 ? w / CGFloat(series.count - 1) : w
                Path { p in
                    for (i, v) in series.enumerated() {
                        let pt = CGPoint(x: CGFloat(i) * step,
                                         y: h - h * CGFloat(v) / CGFloat(maxV))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(DSLight.gold.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 64, height: 14)
        }
    }

    /// 沉默条(FADED WORDS):silentDays 相对一年的占比——「走远了多久」。
    struct SilenceBar: View {
        let silentDays: Int

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    Capsule().fill(DSLight.sf3).frame(height: 3)
                    Capsule().fill(DSLight.t3.opacity(0.55))
                        .frame(width: max(4, geo.size.width * CGFloat(min(silentDays, 365)) / 365), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 56, height: 12)
        }
    }

    /// 比例条(MARATHONS):相对榜首的体量。
    struct RatioBar: View {
        let value: Int
        let maxValue: Int

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DSLight.sf3).frame(height: 3)
                    Capsule().fill(DSLight.gold.opacity(0.65))
                        .frame(width: max(4, geo.size.width * CGFloat(value) / CGFloat(max(maxValue, 1))), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 64, height: 12)
        }
    }
}
