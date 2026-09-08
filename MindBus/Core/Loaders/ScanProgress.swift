import Combine
import Foundation

/// 扫描进度与预计剩余时间：列表标题、侧栏底部状态行、首启欢迎页的数据源。
///
/// 按**字节**估算而不是按文件数——一个 200MB 的 Codex rollout 和一个 20KB 的会话
/// 在文件数上是 1:1，在耗时上差三个数量级；按字节走，剩余时间才和用户的等待感对得上。
///
/// 一轮扫描的重活分三段，各自按字节计量、各自测速：
///   索引（解析 + 写库）→ 归档副本（LZMA 压缩）→ 画像（Minds 回源解析）
/// 剩余时间 = 该段剩余字节 ÷ 速率。速率**起点用通用参考值**（`referenceRates`，按典型
/// Apple Silicon 机器定，不依赖本机测速），本段跑过 10% 字节后才开始按本段累计实测
/// （完成字节 ÷ 经过秒数）修正，30% 起完全按实测——两者几何插值，跨数量级也平滑。
/// 为什么不一上来就测：各段的单位字节成本差一到两个数量级（2026-09-07 release 实测：
/// 索引 Claude 大文件流式 65 MB/s、Codex 大 rollout 1100 MB/s；画像回源 660–4900 MB/s；
/// LZMA 归档 ~9 MB/s），头几秒碰上哪种文件纯属偶然，按它外推整段就是「还需约 5 分钟」
/// 然后半分钟扫完。旧的「保守默认速率」（索引 6MB/s、画像 15MB/s）则差了一两个数量级，
/// 首启第一眼「还需约 20 分钟」。报长再缩短和报短再变长同样失信，参考值取实测的典型值。
/// 只报当前这一段——后面几段的体量在它开始前还不知道，硬凑一个总时间只会失信。
///
/// 对外显示的剩余秒数像倒计时一样平滑、**只降不升**（`smoothedRemaining`）：估算变大就
/// 原地停住等它回落，绝不出现「越等越多」。索引段要等所有来源都清点完要读多少字节
/// 才开始报时间——各来源并发清点，先到的那个只是一部分，按它报出来的数字下一秒就得涨。
/// 1 秒心跳保证单个大文件处理几十秒没有事件时数字也在走。
///
/// 线程模型：扫描线程只改锁保护的影子状态；发布到 `@Published` 的动作按 250ms 合并
/// 一次投到主线程。此前每个文件完成都往主线程投一块、观察它的四五个视图各重算一遍，
/// 画像段命中缓存时一秒几百次，首建库直接把界面卡死。阶段切换立即发布。
public final class ScanProgress: ObservableObject {

    public static let shared = ScanProgress()

    public enum Phase: Equatable {
        case idle, planning, indexing, archiving, profiling, finishing, done
    }

    /// 发布间隔：4 Hz 足够让数字和环看起来在动，又不会把主线程淹掉。
    public static let publishInterval: TimeInterval = 0.25

    /// 各段的通用参考速率（字节/秒）：典型 Apple Silicon 机器上整库的加权实测值。
    public static let referenceRates: [Phase: Double] = [
        .indexing: 200_000_000, .archiving: 9_000_000, .profiling: 400_000_000,
    ]

    /// 本段累计至少这么久、且有完成量，实测速率才算数。
    public static let minSampleSeconds: TimeInterval = 2

    // MARK: - 发布给界面的状态（只在主线程改）

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var plannedBytes: Int64 = 0
    @Published public private(set) var doneBytes: Int64 = 0
    @Published public private(set) var plannedFiles = 0
    @Published public private(set) var doneFiles = 0
    @Published public private(set) var archivePlannedBytes: Int64 = 0
    @Published public private(set) var archiveDoneBytes: Int64 = 0
    @Published public private(set) var archiveTotal = 0
    @Published public private(set) var archiveDone = 0
    @Published public private(set) var profilePlannedBytes: Int64 = 0
    @Published public private(set) var profileDoneBytes: Int64 = 0
    /// 正在被读取的来源（侧栏工具行据此显示 spinner）
    @Published public private(set) var activeSources: Set<ConversationSource> = []
    /// 当前段的预计剩余秒数（已平滑、只降不升）；来源还没清点完、或没有可估的段（收尾 / 空闲）为 nil
    @Published public private(set) var remainingSeconds: TimeInterval? = nil
    /// 本段已经过的秒数（状态行据此轮换文案），每秒心跳更新
    @Published public private(set) var phaseElapsed: TimeInterval = 0

    // MARK: - 影子状态（扫描线程改，锁保护）

    private struct State {
        var phase: Phase = .idle
        var plannedBytes: Int64 = 0, doneBytes: Int64 = 0
        var plannedFiles = 0, doneFiles = 0
        var archivePlannedBytes: Int64 = 0, archiveDoneBytes: Int64 = 0
        var archiveTotal = 0, archiveDone = 0
        var profilePlannedBytes: Int64 = 0, profileDoneBytes: Int64 = 0
        var activeSources: Set<ConversationSource> = []
        /// 这一轮要读的来源数与已清点完（报过计划或已结束）的来源：索引段全清点完才报时间。
        /// expectedSources == 0 表示调用方没说，不做这个门槛。
        var expectedSources = 0
        var plannedSources: Set<ConversationSource> = []
        var planningComplete: Bool { expectedSources == 0 || plannedSources.count >= expectedSources }
        /// 原始估算（剩余字节 ÷ 速率）；来源没清点完 / 不可估的段为 nil
        var rawRemaining: TimeInterval? = nil
        var phaseElapsed: TimeInterval = 0
        /// 对外显示的剩余秒数（`smoothedRemaining` 平滑后）
        var remainingSeconds: TimeInterval? = nil
        var lastTick = Date()
        // 测速：本段累计（完成字节 ÷ 经过秒数）
        var rateStart = Date()
        var rateStartBytes: Int64 = 0
        var measuredRate: Double? = nil
        // 各段耗时：收尾写一行日志，给日后校准用
        var phaseStartedAt = Date()
        var indexingSecs = 0.0, archivingSecs = 0.0, profilingSecs = 0.0

        var phasePlannedBytes: Int64 {
            switch phase {
            case .indexing: return plannedBytes
            case .archiving: return archivePlannedBytes
            case .profiling: return profilePlannedBytes
            default: return 0
            }
        }

        var phaseDoneBytes: Int64 {
            switch phase {
            case .indexing: return doneBytes
            case .archiving: return archiveDoneBytes
            case .profiling: return profileDoneBytes
            default: return 0
            }
        }

        /// 切段：记上一段耗时，本段测速从零开始。调用前先把本段的计数归位。
        mutating func enter(_ next: Phase, now: Date = Date()) {
            let spent = now.timeIntervalSince(phaseStartedAt)
            switch phase {
            case .indexing: indexingSecs += spent
            case .archiving: archivingSecs += spent
            case .profiling: profilingSecs += spent
            default: break
            }
            phase = next
            phaseStartedAt = now
            rateStart = now
            rateStartBytes = phaseDoneBytes
            measuredRate = nil
        }

        mutating func sample(now: Date) {
            let elapsed = now.timeIntervalSince(rateStart)
            guard elapsed >= ScanProgress.minSampleSeconds else { return }
            let bytes = Double(phaseDoneBytes - rateStartBytes)
            guard bytes > 0 else { return }
            measuredRate = bytes / elapsed
        }

        /// 每个事件与每秒心跳都走这里：重测速率 → 原始估算 → 平滑显示值。
        mutating func refreshEstimate(now: Date = Date()) {
            sample(now: now)
            phaseElapsed = max(0, now.timeIntervalSince(phaseStartedAt))
            let gated = phase == .indexing && !planningComplete
            rawRemaining = gated ? nil
                : ScanProgress.remaining(phase: phase, plannedBytes: phasePlannedBytes,
                                         doneBytes: phaseDoneBytes, measuredRate: measuredRate)
            let dt = max(0, now.timeIntervalSince(lastTick))
            lastTick = now
            remainingSeconds = ScanProgress.smoothedRemaining(shown: remainingSeconds, raw: rawRemaining, dt: dt)
        }

        var summaryLine: String {
            func mb(_ b: Int64) -> Double { Double(b) / 1e6 }
            func rate(_ b: Int64, _ s: Double) -> Double { s > 0 ? mb(b) / s : 0 }
            return String(format: "[scan] read %.0f MB in %.1fs (%.0f MB/s) · backup %.0f MB in %.1fs (%.0f MB/s) · profile %.0f MB in %.1fs (%.0f MB/s)",
                          mb(doneBytes), indexingSecs, rate(doneBytes, indexingSecs),
                          mb(archiveDoneBytes), archivingSecs, rate(archiveDoneBytes, archivingSecs),
                          mb(profileDoneBytes), profilingSecs, rate(profileDoneBytes, profilingSecs))
        }
    }

    private let lock = NSLock()
    private var state = State()
    private var flushScheduled = false
    /// 1 秒心跳：单个大文件处理几十秒没有事件时，速率与倒计时也要往下走
    private var ticker: Timer?

    public init() {}

    // MARK: - 扫描线程调用的事件

    /// - Parameter expectedSources: 这一轮会读的来源数；索引段等它们全清点完再报时间。0 = 不设门槛。
    public func begin(expectedSources: Int = 0) {
        mutate(immediate: true) { s in
            s = State()
            s.phase = .planning
            s.expectedSources = expectedSources
        }
        onMain { [weak self] in
            self?.ticker?.invalidate()
            self?.ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.mutate { $0.refreshEstimate() }
            }
        }
    }

    public func sourceStarted(_ source: ConversationSource) {
        mutate(immediate: true) { $0.activeSources.insert(source) }
    }

    public func sourceFinished(_ source: ConversationSource) {
        mutate(immediate: true) { s in
            s.activeSources.remove(source)
            s.plannedSources.insert(source)   // 没东西可读的来源直接结束，也算清点完
            s.refreshEstimate()
        }
    }

    public func addPlanned(source: ConversationSource? = nil, bytes: Int64, files: Int) {
        mutate(immediate: true) { s in
            s.plannedBytes += bytes
            s.plannedFiles += files
            if let source { s.plannedSources.insert(source) }
            if s.phase == .planning || s.phase == .idle { s.enter(.indexing) }
            s.refreshEstimate()
        }
    }

    public func fileDone(bytes: Int64) {
        mutate { s in
            s.doneBytes += bytes
            s.doneFiles += 1
            s.refreshEstimate()
        }
    }

    public func beginArchiving(totalBytes: Int64, files: Int) {
        mutate(immediate: true) { s in
            s.archivePlannedBytes = totalBytes; s.archiveDoneBytes = 0
            s.archiveTotal = files; s.archiveDone = 0
            s.enter(.archiving)
            s.refreshEstimate()
        }
    }

    public func archiveFileDone(bytes: Int64) {
        mutate { s in
            s.archiveDoneBytes += bytes
            s.archiveDone += 1
            s.refreshEstimate()
        }
    }

    public func beginProfiling(totalBytes: Int64) {
        mutate(immediate: true) { s in
            s.profilePlannedBytes = totalBytes; s.profileDoneBytes = 0
            s.enter(.profiling)
            s.refreshEstimate()
        }
    }

    public func profileFileDone(bytes: Int64) {
        mutate { s in
            s.profileDoneBytes += bytes
            s.refreshEstimate()
        }
    }

    public func beginFinishing() {
        mutate(immediate: true) { s in
            s.enter(.finishing)
            s.rawRemaining = nil
            s.remainingSeconds = nil
        }
    }

    public func finish() {
        var summary = ""
        mutate(immediate: true) { s in
            s.enter(.done)
            s.rawRemaining = nil
            s.remainingSeconds = nil
            s.activeSources = []
            summary = s.summaryLine
        }
        NSLog("%@", summary)
        ScanLog.append(summary)
        onMain { [weak self] in
            self?.ticker?.invalidate()
            self?.ticker = nil
        }
    }

    // MARK: - 读

    /// 综合进度 0…1：索引 0→0.6、归档 0.6→0.8、画像 0.8→0.95、收尾 0.95、完成 1。
    public var fraction: Double {
        Self.fraction(phase: phase, plannedBytes: plannedBytes, doneBytes: doneBytes,
                      archivePlannedBytes: archivePlannedBytes, archiveDoneBytes: archiveDoneBytes,
                      profilePlannedBytes: profilePlannedBytes, profileDoneBytes: profileDoneBytes)
    }

    /// 纯函数版，便于测试。没有待处理字节的段（增量零变化）直接记满。
    public static func fraction(phase: Phase, plannedBytes: Int64, doneBytes: Int64,
                                archivePlannedBytes: Int64 = 0, archiveDoneBytes: Int64 = 0,
                                profilePlannedBytes: Int64 = 0, profileDoneBytes: Int64 = 0) -> Double {
        func ratio(_ done: Int64, _ planned: Int64) -> Double {
            planned > 0 ? min(1, Double(done) / Double(planned)) : 1
        }
        switch phase {
        case .idle, .planning: return 0
        case .indexing: return 0.6 * ratio(doneBytes, plannedBytes)
        case .archiving: return 0.6 + 0.2 * ratio(archiveDoneBytes, archivePlannedBytes)
        case .profiling: return 0.8 + 0.15 * ratio(profileDoneBytes, profilePlannedBytes)
        case .finishing: return 0.95
        case .done: return 1
        }
    }

    /// 本段的有效速率（纯函数）：参考值打底，跑过 10% 字节后按实测修正，30% 起全按实测。
    /// 不是可估的段 → nil。
    public static func effectiveRate(phase: Phase, plannedBytes: Int64, doneBytes: Int64,
                                     measuredRate: Double?) -> Double? {
        guard let reference = referenceRates[phase] else { return nil }
        guard let measured = measuredRate, plannedBytes > 0 else { return reference }
        let done = Double(doneBytes) / Double(plannedBytes)
        let w = min(1, max(0, (done - 0.1) / 0.2))
        let floored = max(measured, 50_000)   // 50KB/s 下限：别算出几小时的荒唐值
        return pow(reference, 1 - w) * pow(floored, w)
    }

    /// 剩余时间纯函数：剩余字节 ÷ 有效速率。
    public static func remaining(phase: Phase, plannedBytes: Int64, doneBytes: Int64,
                                 measuredRate: Double?) -> TimeInterval? {
        guard let rate = effectiveRate(phase: phase, plannedBytes: plannedBytes,
                                       doneBytes: doneBytes, measuredRate: measuredRate) else { return nil }
        return Double(max(0, plannedBytes - doneBytes)) / rate
    }

    /// 显示值的平滑规则（纯函数，便于测试）——**只降不升**：
    /// - 没有估算 → 不显示；第一次有估算 → 直接采用
    /// - 估算不比显示值小：原地停住（不涨、也不往下数），等它回落
    /// - 正常每秒减 1，减过头就停在估算值上
    /// - 估算比显示值小得多：按差距的比例追（每秒收掉 28%，至少 2 秒），小差距不会「20 秒」
    ///   一闪变「10 秒」，大差距（5 分钟 → 30 秒）也十来秒就追上，不会挂着假数字直到扫完
    public static func smoothedRemaining(shown: TimeInterval?, raw: TimeInterval?, dt: TimeInterval) -> TimeInterval? {
        guard let raw else { return nil }
        guard let shown else { return raw }
        guard raw < shown else { return shown }
        var next = shown - dt
        if next > raw {
            let gap = next - raw
            next = max(raw, next - max(2 * dt, gap * (1 - exp(-dt / 3))))
        } else {
            next = raw
        }
        return max(0, next)
    }

    // MARK: - 影子状态 → 主线程发布（合并）

    private func mutate(immediate: Bool = false, _ change: (inout State) -> Void) {
        lock.lock()
        change(&state)
        let snapshot = state
        let schedule = !flushScheduled && !immediate
        if schedule { flushScheduled = true }
        lock.unlock()
        if immediate {
            onMain { self.publish(snapshot) }
        } else if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let latest = self.state
                self.flushScheduled = false
                self.lock.unlock()
                self.publish(latest)
            }
        }
    }

    private func publish(_ s: State) {
        if phase != s.phase { phase = s.phase }
        plannedBytes = s.plannedBytes; doneBytes = s.doneBytes
        plannedFiles = s.plannedFiles; doneFiles = s.doneFiles
        archivePlannedBytes = s.archivePlannedBytes; archiveDoneBytes = s.archiveDoneBytes
        archiveTotal = s.archiveTotal; archiveDone = s.archiveDone
        profilePlannedBytes = s.profilePlannedBytes; profileDoneBytes = s.profileDoneBytes
        if activeSources != s.activeSources { activeSources = s.activeSources }
        remainingSeconds = s.remainingSeconds
        phaseElapsed = s.phaseElapsed
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// 扫描日志：`~/Library/Logs/MindBus/scan.log`，每轮一两行，只有字节数与秒数、没有路径
/// 和内容。给「首建库慢 / 打开卡」这类反馈一个可以直接贴出来的依据；超过 512KB 轮转一份。
public enum ScanLog {
    public static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MindBus/scan.log")
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    public static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > 512 * 1024 {
            let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        let data = Data((stamp.string(from: Date()) + " " + line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
