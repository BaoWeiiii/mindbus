import Foundation

/// 评测集生成（方法学与四路生成规则的唯一真相：
/// `docs/superpowers/plans/2026-08-11-bench-pipeline.md`；出处见
/// `MEMORY-LAYER-SPEC.md` §7.59「评测集」）。
///
/// **为什么这份文件放在 `MindBusCore` 而不是独立 target**：生成逻辑要能被
/// `Tests/MindBusCoreTests` 直接单测（`@testable import`），且未来 `mindbus-bench`
/// 可执行文件（Task 2，`MindBus/BenchMain/`）需要 `import MindBusCore` 才能调用它——
/// 放进产品代码库同一个 target 是唯一同时满足两者的位置。App 本体不会因此多编译
/// 任何东西：`MindBus` target 已经 `exclude` 了整个 `Core` 目录，`BenchDataset` 只被
/// `mindbus-bench`（不进 app bundle）与它自己的测试引用。
///
/// **子进程边界（重要）**：本文件内部用 `Process` 跑 `git log`（见 `gitLog(repoRoot:)`）
/// 为 commitMessage 一路取 commit 历史——这是本仓库目前**唯一**允许子进程的代码路径。
/// `mindbus-bench` 是本地开发者工具，不是 App 运行时；生产代码路径（App 本体、
/// MCP server）依然零子进程。这条豁免只对 `BenchDataset` 及其调用方
/// （`BenchRunner`/`BenchMain`/本文件自己的测试）生效，不得被生产代码复用或效仿。
///
/// **数据边界**：评测集内容含用户真实语料，只落 `~/.mindbus/bench/`（或
/// `MINDBUS_BENCH_ROOT` 注入的路径），绝不进 git 仓——本文件只提供生成/读写能力，
/// 落盘路径由调用方（`BenchMain`，Task 2）决定，这里不做路径策略判断。
public struct BenchItem: Codable, Equatable {
    public let query: String
    public let answerID: String        // 标准答案会话 id（§7.59：标准答案是会话级的，不是段级）
    public let source: Source          // 四路之一
    public let band: Band              // low / mid / high（生成时按低频词重叠数算好）

    public enum Source: String, Codable { case commitMessage, rareEntity, firstMessage, structuralEvent }
    public enum Band: String, Codable { case low, mid, high }

    public init(query: String, answerID: String, source: Source, band: Band) {
        self.query = query
        self.answerID = answerID
        self.source = source
        self.band = band
    }
}

public enum BenchDataset {

    // MARK: - 生成

    /// 从只读索引生成评测集：四路查询来源（commitMessage/rareEntity/firstMessage/
    /// structuralEvent）各自独立生成、各自按 `maxPerSource` 截断，再统一算分带。
    ///
    /// 四路互不依赖，谁先跑不影响另一路的结果；`maxPerSource` 分别限制**每一路**的
    /// 数量（不是总数上限），保证四路在最终数据集里大致均衡，不被某一路的语料密度
    /// （比如 rareEntity 天然比 commitMessage 多）独占整个评测集。
    public static func generate(index: ConversationIndex, maxPerSource: Int) -> [BenchItem] {
        let metas = index.allMetadata()
        let lexicon = index.loadLexicon()
        let totalSegments = index.segmentCount()
        let cache = ConversationCache()

        var items: [BenchItem] = []
        items += generateCommitMessage(index: index, metas: metas, lexicon: lexicon,
                                        totalSegments: totalSegments, cache: cache, maxPerSource: maxPerSource)
        items += generateRareEntity(index: index, metas: metas, lexicon: lexicon,
                                     totalSegments: totalSegments, cache: cache, maxPerSource: maxPerSource)
        items += generateFirstMessage(index: index, metas: metas, lexicon: lexicon,
                                       totalSegments: totalSegments, cache: cache, maxPerSource: maxPerSource)
        items += generateStructuralEvent(index: index, metas: metas, lexicon: lexicon,
                                          totalSegments: totalSegments, cache: cache, maxPerSource: maxPerSource)
        return items
    }

    // MARK: - JSONL 读写

    /// 写成 JSONL（一行一个 JSON 对象）。目录不存在则先建；单条编码失败跳过、不中断
    /// 整批（评测集生成是离线批处理，不该因一条脏数据满盘皆输）。
    public static func write(_ items: [BenchItem], to url: URL) {
        let encoder = JSONEncoder()
        var lines: [String] = []
        for item in items {
            guard let data = try? encoder.encode(item), let line = String(data: data, encoding: .utf8) else {
                NSLog("[bench] skip item that failed to encode: query=%@", item.query)
                continue
            }
            lines.append(line)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[bench] failed to write dataset to %@: %@", url.path, String(describing: error))
        }
    }

    /// 读回 JSONL。文件不存在或整行解析失败一律跳过（不 throw）——评测集是开发者手边
    /// 的工具产物，读不到就是空数据集，调用方（`mindbus-bench run`）自己决定怎么提示。
    public static func read(from url: URL) -> [BenchItem] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        var out: [BenchItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let item = try? decoder.decode(BenchItem.self, from: Data(line.utf8)) else { continue }
            out.append(item)
        }
        return out
    }

    // MARK: - 四路生成（§7.59，细节定死，逐条对应 plan）

    /// commitMessage：cwd 向上找 git 根（复用 `ConversationIndex.gitRoot(of:)`）→ 每个
    /// 仓库跑一次 `git log` → commit 时间落在某会话 `[startAt-1h, endAt+1h]` 闭区间
    /// 窗口内 → (commit subject, 该会话) 成对。同仓库多会话命中同一个 commit 时取
    /// 时间最近的一个——「最近」按到 `[startAt, endAt]` 实际跨度的距离算（落在跨度内
    /// 记 0，否则记到最近边界的距离），不是到窗口边界的距离，窗口的 ±1h 只是放宽
    /// 「算不算命中」，不该参与「谁更近」的排名。subject 短于 8 字符丢——太短无查询
    /// 价值（如 "fix bug"，对检索几乎不构成有效查询）。
    private static func generateCommitMessage(index: ConversationIndex, metas: [ConversationLite],
                                                lexicon: Set<String>, totalSegments: Int,
                                                cache: ConversationCache, maxPerSource: Int) -> [BenchItem] {
        guard maxPerSource > 0 else { return [] }

        // 按仓库根分组：同一仓库即使被多个会话（不同 cwd 子目录）命中，也只跑一次
        // `git log`。只收「真的找到 .git」的会话——`gitRoot(of:)` 找不到时会退回
        // 标准化后的原路径，那种路径下必然没有 .git，用这个特征区分「找到」与「没找到」
        // （见 `ConversationIndex.gitRoot(of:)` 文档）。
        var sessionsByRepo: [String: [ConversationLite]] = [:]
        for m in metas {
            let root = ConversationIndex.gitRoot(of: m.cwd)
            guard FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: root).appendingPathComponent(".git").path
            ) else { continue }
            sessionsByRepo[root, default: []].append(m)
        }
        guard !sessionsByRepo.isEmpty else { return [] }

        struct Candidate { let subject: String; let session: ConversationLite; let commitDate: Date }
        var candidates: [Candidate] = []

        for (repo, sessions) in sessionsByRepo.sorted(by: { $0.key < $1.key }) {
            for commit in gitLog(repoRoot: repo) {
                guard commit.subject.count >= 8 else { continue }
                let matches: [(session: ConversationLite, distance: TimeInterval)] = sessions.compactMap { s in
                    let windowStart = s.startAt.addingTimeInterval(-3600)
                    let windowEnd = s.endAt.addingTimeInterval(3600)
                    guard commit.commitDate >= windowStart, commit.commitDate <= windowEnd else { return nil }
                    let distance = max(0, max(s.startAt.timeIntervalSince(commit.commitDate),
                                               commit.commitDate.timeIntervalSince(s.endAt)))
                    return (s, distance)
                }
                guard let best = matches.min(by: {
                    $0.distance != $1.distance ? $0.distance < $1.distance : $0.session.id < $1.session.id
                }) else { continue }
                candidates.append(Candidate(subject: commit.subject, session: best.session, commitDate: commit.commitDate))
            }
        }

        // 全局按 (commitDate, subject) 排序后再按 maxPerSource 截断——截断结果与仓库
        // 遍历顺序无关，可复现。
        candidates.sort { $0.commitDate != $1.commitDate ? $0.commitDate < $1.commitDate : $0.subject < $1.subject }

        var items: [BenchItem] = []
        for c in candidates {
            guard items.count < maxPerSource else { break }
            guard let answerText = cache.get(c.session)?.searchableText else { continue }
            let band = bandForOverlap(query: c.subject, answerFullText: answerText, index: index,
                                       lexicon: lexicon, totalSegments: totalSegments)
            items.append(BenchItem(query: c.subject, answerID: c.session.id, source: .commitMessage, band: band))
        }
        return items
    }

    /// rareEntity：`entities(forConversationID:)` 已按 DF 升序返回（且已做样板实体压制），
    /// 取 DF ≤3 的前两条，query = 实体原文。
    private static func generateRareEntity(index: ConversationIndex, metas: [ConversationLite],
                                            lexicon: Set<String>, totalSegments: Int,
                                            cache: ConversationCache, maxPerSource: Int) -> [BenchItem] {
        guard maxPerSource > 0 else { return [] }
        var items: [BenchItem] = []
        for m in metas {
            guard items.count < maxPerSource else { break }
            let rare = index.entities(forConversationID: m.id, limit: Int.max)
                .filter { $0.conversationCount <= 3 }
                .prefix(2)
            guard !rare.isEmpty else { continue }
            guard let answerText = cache.get(m)?.searchableText else { continue }
            for e in rare {
                guard items.count < maxPerSource else { break }
                let band = bandForOverlap(query: e.text, answerFullText: answerText, index: index,
                                           lexicon: lexicon, totalSegments: totalSegments)
                items.append(BenchItem(query: e.text, answerID: m.id, source: .rareEntity, band: band))
            }
        }
        return items
    }

    /// firstMessage：首条 user 消息的 `Segmenter.plainTextForSearch` 截前 12 个词
    /// （空白切），结果短于 10 字符丢。**回避身份泄漏**：query 与答案同源，重叠天然
    /// 高——这一路主要落 high 带，是 §7.59 明确标注的预期现象，不是 band 计算的缺陷。
    private static func generateFirstMessage(index: ConversationIndex, metas: [ConversationLite],
                                              lexicon: Set<String>, totalSegments: Int,
                                              cache: ConversationCache, maxPerSource: Int) -> [BenchItem] {
        guard maxPerSource > 0 else { return [] }
        var items: [BenchItem] = []
        for m in metas {
            guard items.count < maxPerSource else { break }
            guard let conv = cache.get(m) else { continue }
            guard let firstUser = conv.messages.first(where: { $0.role == .user }) else { continue }
            let words = Segmenter.plainTextForSearch(of: firstUser)
                .split(whereSeparator: { $0.isWhitespace })
                .prefix(12)
            let query = words.joined(separator: " ")
            guard query.count >= 10 else { continue }
            let band = bandForOverlap(query: query, answerFullText: conv.searchableText, index: index,
                                       lexicon: lexicon, totalSegments: totalSegments)
            items.append(BenchItem(query: query, answerID: m.id, source: .firstMessage, band: band))
        }
        return items
    }

    /// structuralEvent：`Segmenter` 切出的段里，取「段末用户短消息」（6...60 字闭区间）
    /// 的文本当查询——结构事件的用户侧（长回复后的短反馈，常是「不对/对了/继续」这类
    /// 否定或确认）。短于 6 字符丢（同上，太短无查询价值）。
    private static func generateStructuralEvent(index: ConversationIndex, metas: [ConversationLite],
                                                 lexicon: Set<String>, totalSegments: Int,
                                                 cache: ConversationCache, maxPerSource: Int) -> [BenchItem] {
        guard maxPerSource > 0 else { return [] }
        var items: [BenchItem] = []
        for m in metas {
            guard items.count < maxPerSource else { break }
            guard let conv = cache.get(m) else { continue }
            let segments = Segmenter.segments(of: conv.messages)
            guard !segments.isEmpty else { continue }
            let answerText = conv.searchableText
            for seg in segments {
                guard items.count < maxPerSource else { break }
                guard seg.lastMessageIndex < conv.messages.count else { continue }
                let lastMsg = conv.messages[seg.lastMessageIndex]
                guard lastMsg.role == .user else { continue }
                let text = Segmenter.plainTextForSearch(of: lastMsg)
                guard text.count >= 6, text.count <= 60 else { continue }
                let band = bandForOverlap(query: text, answerFullText: answerText, index: index,
                                           lexicon: lexicon, totalSegments: totalSegments)
                items.append(BenchItem(query: text, answerID: m.id, source: .structuralEvent, band: band))
            }
        }
        return items
    }

    // MARK: - 分带（§7.59：query 与答案会话全文的低频词重叠数）

    /// 低频词重叠分带：query 与答案会话全文各自切词（`ConversationIndex.candidateTokens`
    /// —— 与 RM3 扩展词候选**同一条**管道，见该方法文档）→ 取交集 → 交集里 df ≤
    /// `ceiling`（`max(2, 5%×总段数)`，与 `expansionTermsInsideQueue` 的扩展词 df
    /// 上限公式相同）的词计数 → 映射到三档：0-1 low，2-3 mid，≥4 high。
    ///
    /// 用全文算重叠会被长对话的常见词淹没（v1 就栽在这，见 spec §7.59）——所以只算
    /// 交集里的**低频**词，不是交集本身的大小。
    ///
    /// internal（非 private）可见度：供 `BenchDatasetTests` 用可控 df 的临时语料直测
    /// 分带边界，不进公开 API（同 `ConversationIndex.expansionTerms` 的先例）。
    static func bandForOverlap(query: String, answerFullText: String, index: ConversationIndex,
                                lexicon: Set<String>, totalSegments: Int) -> BenchItem.Band {
        let queryWords = Set(ConversationIndex.candidateTokens(from: query, lexicon: lexicon))
        let answerWords = Set(ConversationIndex.candidateTokens(from: answerFullText, lexicon: lexicon))
        let shared = queryWords.intersection(answerWords)
        guard !shared.isEmpty else { return .low }

        let dfs = index.documentFrequencies(terms: Array(shared))
        let ceiling = max(2, Int(0.05 * Double(totalSegments)))
        let overlap = shared.filter { (dfs[$0] ?? 0) <= ceiling }.count

        switch overlap {
        case 0, 1: return .low
        case 2, 3: return .mid
        default: return .high
        }
    }

    // MARK: - git log（本文件唯一的子进程调用点）

    /// 跑 `git log --format=%H|%ct|%s`，解析成 (commit hash, committer 时间, subject)。
    /// 任何失败（git 不存在、目录不是仓库、进程起不来、空仓库无提交）一律返回空数组
    /// ——commitMessage 这一路的产出本就允许比其他三路薄，不该让整个 `generate()`
    /// 因为某一个仓库读不出 commit 历史而抛错中断。
    ///
    /// `%s`（subject）本身没有禁止管道符：用 `maxSplits: 2` 只切前两个 `|`（对应
    /// `%H` 与 `%ct` 之间、`%ct` 与 `%s` 之间），第三段原样保留，哪怕 subject 里还有
    /// 更多 `|`。
    ///
    /// 读 stdout 必须在 `waitUntilExit()` 之前——`git log` 输出量可能超过管道缓冲区，
    /// 若先 `waitUntilExit()` 再读，子进程会阻塞在写满的管道上而父进程阻塞在
    /// `waitUntilExit()`，两者互等造成死锁。`readDataToEndOfFile()` 会阻塞到子进程
    /// 关闭写端（通常即进程退出）才返回，天然规避了这个顺序问题。
    private static func gitLog(repoRoot: String) -> [(hash: String, commitDate: Date, subject: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", repoRoot, "log", "--format=%H|%ct|%s"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }

        let text = String(decoding: data, as: UTF8.self)
        var out: [(hash: String, commitDate: Date, subject: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let epoch = Double(parts[1]) else { continue }
            out.append((hash: String(parts[0]), commitDate: Date(timeIntervalSince1970: epoch), subject: String(parts[2])))
        }
        return out
    }

    // MARK: - 会话全文缓存

    /// 同一会话可能被多路复用（如既是 rareEntity 候选又要参与分带计算），一次会话
    /// 最多解析一次源文件。失败（`loadFull` 返回 nil）也缓存——避免对已知读不到的
    /// 会话反复重试解析。`private`：只在 `BenchDataset` 自己的四个生成函数间传递。
    private final class ConversationCache {
        private var store: [String: Conversation?] = [:]

        func get(_ lite: ConversationLite) -> Conversation? {
            if let cached = store[lite.id] { return cached }
            let conv = ConversationStore.loadFull(id: lite.id, fileURL: lite.fileURL, source: lite.source)
            store[lite.id] = conv
            return conv
        }
    }
}
