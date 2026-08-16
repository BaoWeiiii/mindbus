import Foundation

/// 增量加载流水线（SQLite 索引版）：各 loader 共用，mtime 对比 index → 仅 parse 变化文件 → 写 ConversationIndex。
public enum LoaderRuntime {

    /// 全局解析并发上限：跨所有 loader 限制同时 parse 的文件数。
    /// 峰值内存 ≈ 此值 × 单个大会话 parse 的瞬时对象（42MB 级会话存在），故压低。
    private static let parseGate = DispatchSemaphore(value: 2)

    /// 索引路径的单 block 文本上限与会话级文本预算(2026-08-14 首建峰值削减)。
    /// 检索段有 4000 字软顶/200K 硬顶——超限文本对索引零边际,却让巨型会话的
    /// parse 峰值破 GB:真机 720MB Codex rollout(response_item 275MB 全量进
    /// Message 数组,叠加 segments/entityText/userText 派生拷贝,峰值 1.8GB)。
    /// 预算耗尽后的消息只留结构(角色/时间戳,撑计数与段切分),文本清空——
    /// 与段级 hardTextCap 同一哲学:截断只影响超长尾部的可搜性。详情路径全量不受影响。
    /// 16MB 预算覆盖 P99.9 真会话(716 场评测集全部在几 MB 内);first-run 实测:
    /// 48MB 版峰值仍 1.2GB(前 48MB ×5 份派生拷贝),16MB 才把巨型 rollout 摁住。
    static let indexingBlockCap = 256 * 1024
    static let indexingSessionBudget = 16 * 1024 * 1024

    /// 扫描支持的本地来源写入索引：仅 Claude Code / Claude / Codex 三个本地工具
    /// （+ browser 全量替换，Web 采集单独维度）。并发。
    /// loadAsync / runSyncSnapshot / 启动 warm-up 共用，单一真相来源。
    /// 注：Cursor/OpenClaw/Copilot 的 Loader 代码保留，但产品范围当前只支持上述三个，故不扫。
    public static func indexAllSources(into index: ConversationIndex) async {
        // 并发调用合流到同一次扫描：启动预热与打开窗口会几乎同时触发，
        // 各跑一遍不只白烧一倍 CPU/IO —— 两个写者还会互相把对方的批次撞回滚。
        let task: Task<Void, Never> = {
            scanLock.lock(); defer { scanLock.unlock() }
            if let running = runningScan { return running }
            let t = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { await onUtilityQueue { ClaudeCodeLoader.loadAll(into: index) } }
                    g.addTask { await onUtilityQueue { CodexLoader.loadAll(into: index) } }
                    g.addTask { await onUtilityQueue { ClaudeAgentLoader.loadAll(into: index) } }
                    g.addTask { await onUtilityQueue { BrowserVaultLoader.loadAll(into: index) } }
                }
                await onUtilityQueue { pruneMissing(from: index) }
                // 归档扫尾：把索引里该归档而未归档的源文件补齐。
                // 必须在 pruneMissing 之后 —— prune 先清掉政策排除与真正无救的行，
                // 剩下的才是值得占归档空间的。
                await onUtilityQueue {
                    let n = VaultArchive.sweep(paths: archiveScope(of: index))
                    if n > 0 { NSLog("[vault] archived %d new conversation file(s)", n) }
                }
                // 个人词表：语料涨了就重学（spec §7.62——语料越多词表越准）。放在 sweep
                // 之后纯粹是顺序上的收尾位置，两者无数据依赖。
                await onUtilityQueue {
                    _ = index.rebuildLexiconIfNeeded()
                }
                // MCP 引用回流（spec §7 第5步/§2.2）：汇入 memory_open 记的 jsonl 到
                // 聚合表 mcp_refs。放在词表重建之后同样是顺序上的收尾位置，
                // 与上面词表重建互不依赖，全量重算本身也是幂等的。
                await onUtilityQueue {
                    index.ingestRefLog(from: MCPRefLog.defaultLogURL)
                }
                // 文件夹改名追踪:百级目录各一次 stat,发现「同 inode 换路径」即自动
                // 写别名——历史会话的标签下轮刷新即合流到新名。人工别名优先(tracker 内保证)。
                await onUtilityQueue {
                    let renames = FolderIdentityTracker.track(
                        cwds: index.allMetadata().map(\.cwd))
                    if !renames.isEmpty {
                        NSLog("[folders] auto-aliased %d renamed folder(s): %@", renames.count,
                              renames.map { "\($0.old)→\($0.new)" }.joined(separator: ", "))
                    }
                }
                // 思脉底座机械层（design spec §2）：六节统计陈述重建 minds.md。放在词表
                // 重建与 refs 汇入**之后**——VOCABULARY 节消费前者的产出（词表 df），
                // AGENT USAGE 节消费后者的产出（mcp_refs 聚合表），颠倒顺序会让本轮
                // 重建看到上一轮的旧数据。全量重建、幂等，代价与词表重灌同量级（毫秒级）。
                await onUtilityQueue {
                    MindsBuilder.build(from: index)
                }
                FormatTelemetry.shared.flushToLog()   // 「静默的未知」显式化
                // 归还 malloc 空闲池(2026-08-14):首建的行级 JSON 反序列化把池水位
                // 推到 GB 级,活对象释放后池不还 OS——Activity Monitor 的「内存」
                // (phys_footprint)含池,峰后长时间显示虚高。收尾主动还给系统,
                // 稳态读数回落到真实活对象水平。
                malloc_zone_pressure_relief(nil, 0)
                // withLock：同步闭包内持锁即释，async 上下文的合法姿势
                // （裸 lock()/unlock() 在 async 函数体内是 Swift 6 错误——可能跨悬挂点持锁）
                scanLock.withLock { runningScan = nil }
            }
            runningScan = t
            return t
        }()
        await task.value
    }

    /// 清掉索引里那些源文件已从磁盘消失、且没有归档副本的行。
    ///
    /// `ConversationIndex.prune` 此前只有单元测试调用，产品代码从未接线。
    /// 后果：用户删掉一个会话文件后，列表里那条永远都在，点开却因为
    /// `loadFull` 返回 nil 而显示「从左侧选择一个对话」——
    /// 明明点了一条，界面却让他去选一条。
    ///
    /// 直接按索引里的 file_path 反查磁盘，不依赖各 loader 的目录规则；
    /// 只 stat 不解析，千条量级毫秒完成。
    ///
    /// 只 stat 绝对路径：browser 行的 file_path 是相对伪路径
    /// （`browser-chatgpt/2026-05-07.jsonl#3`，replaceBrowserVault 拿 conv.id 充当），
    /// 不是磁盘路径，fileExists 必为 false——不跳过的话每轮扫描都会把 browser 行整段误删。
    ///
    /// 「文件存在但命中排除规则」（内置标记 / 用户 ~/.mindbus/ignore）同样清除：
    /// 排除规则新增后，存量行的源文件 mtime 不变、增量扫描永远跳过，
    /// 不在这里清就成了永久残留（isExcluded 可注入供测试）。
    /// 该被归档的源路径集合。
    ///
    /// 用 `conversationPaths()` 而不是 `knownMtimes()`：后者故意把「解析无产出」的文件
    /// 也并进来（增量跳过需要），但那些是子代理轨迹、壳会话、API Error 残骸——
    /// App 永远不显示它们。实测本机若用 knownMtimes，1062 个路径里只有约 4% 是真对话，
    /// 归档量 272MiB 中约 65% 是废的。
    ///
    /// 这是一条已接受的不可逆取舍：当前进 `skipped_files` 的文件永不归档。
    /// 若将来数据政策放宽、把某类 skipped 重新判定为真对话，其 Claude Code 源
    /// 可能早已被 30 天清理删除——届时没有归档副本可补，那份历史就真的没了。
    /// 风险主要集中在「壳会话」这类边界样本，它们与「真对话」的界线最容易随政策调整移动。
    static func archiveScope(of index: ConversationIndex) -> [String] {
        index.conversationPaths().filter(VaultArchive.isArchivableSourcePath)
    }

    static func pruneMissing(from index: ConversationIndex,
                             isExcluded: (String) -> Bool = ClaudeCodeLoader.isExcludedPath,
                             hasArchive: (String) -> Bool = { VaultArchive.hasArchive(sourcePath: $0) }) {
        let fm = FileManager.default
        let missing = index.knownMtimes().keys.filter { path in
            // browser 行的 file_path 是相对伪路径，不是磁盘路径，不能 stat
            guard path.hasPrefix("/") else { return false }
            // 政策排除优先于一切：这内容不该在库里，有没有副本都要清
            if isExcluded(path) { return true }
            guard !fm.fileExists(atPath: path) else { return false }
            // 源文件被工具清理了，但我们有自己的副本 —— 留着这一行，详情改从副本读。
            // 这一句就是「工具删它的，你的还在」的全部实现；删掉它，删除就会传染。
            return !hasArchive(path)
        }
        guard !missing.isEmpty else { return }
        index.prune(missingPaths: Array(missing))
    }

    private static let scanLock = NSLock()
    private static var runningScan: Task<Void, Never>?

    /// 把同步阻塞的扫描工作派发到 GCD utility 队列：loadAll → index() 内部用
    /// DispatchSemaphore.wait / group.wait 同步阻塞，若直接跑在 Swift Concurrency
    /// 协作线程池（池宽=核数）会在低核机首建库时把搜索/详情解析饿死；
    /// GCD 线程可超售（overcommit），阻塞无害。协作线程只在 continuation 上挂起，不被占用。
    private static func onUtilityQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                work()
                cont.resume()
            }
        }
    }

    /// 仅服务「1 文件 = 1 对话」的 6 个普通 loader；BrowserVault 走 `index.replaceBrowserVault`。
    /// `source` 形参暂未直接使用（conv 自带 source），保留以备将来按源 prune 隔离。
    public static func index(
        urls: [URL],
        into index: ConversationIndex,
        source: ConversationSource,
        parse: @escaping (URL) -> Conversation?
    ) {
        indexRows(urls: urls, into: index, source: source) { url in
            parse(url).map { IndexRow.from($0, fileURL: url) }
        }
    }

    /// 消息墓碑会话的重灌慢路径:全量 parse → 过滤被删消息 → 纯函数重建产物。
    /// 只对「用户删过单条消息」的会话触发(量极少),不侵入各 loader 的 parse 逻辑。
    static func rebuildFilteringBuriedMessages(url: URL, row: IndexRow) -> IndexRow? {
        let buried = TombstoneStore.shared.buriedMessages(conversationID: row.lite.id)
        guard !buried.isEmpty else { return row }
        guard let conv = fullParse(url: url, source: row.lite.source) else { return nil }
        let kept = conv.messages.filter { !buried.contains($0.id) }
        guard !kept.isEmpty else { return nil }   // 全删光=整场消失(墓碑该升级为对话级,由调用方处理)
        let filtered = Conversation(id: conv.id, source: conv.source,
                                    startAt: kept.first!.timestamp, endAt: kept.last!.timestamp,
                                    cwd: conv.cwd, gitBranch: conv.gitBranch,
                                    title: conv.title, messages: kept)
        return IndexRow.from(filtered, fileURL: url)
    }

    /// 详情级全量 parse(与 ConversationStore 的详情路径同款 loader 分发)。
    static func fullParse(url: URL, source: ConversationSource) -> Conversation? {
        switch source {
        case .claudeCode: return try? ClaudeCodeLoader.loadConversation(fileURL: url)
        case .codex: return try? CodexLoader.loadConversation(fileURL: url)
        case .claudeAgent: return try? ClaudeAgentLoader.loadConversation(fileURL: url)
        default: return nil
        }
    }

    /// 统一入口:上游只需产 `IndexRow`(全量或流式)。旧 `parse:` 版是它的薄封装。
    public static func indexRows(
        urls: [URL],
        into index: ConversationIndex,
        source: ConversationSource,
        makeRow: @escaping (URL) -> IndexRow?
    ) {
        let known = index.knownMtimes()
        struct Stale { let url: URL; let mtime: Double }
        var stale: [Stale] = []
        for url in urls {
            // 用户删除的对话(墓碑)永不重入——删除语义「从 MindBus 抹除」的扫描侧防线。
            if TombstoneStore.shared.isBuriedPath(url.path) { continue }
            guard let m = mtime(of: url)?.timeIntervalSince1970 else { continue }
            if known[url.path] == m { continue }   // 未变，跳过（不 parse）
            stale.append(Stale(url: url, mtime: m))
        }
        guard !stale.isEmpty else { return }
        // 小文件优先(2026-08-14 首装负担削减):日常会话几百 KB 先入库,列表先可用;
        // 巨型 rollout 殿后。配合下面的 bigGate,首装期间系统负担平缓。
        let sizeOf: (URL) -> Int = {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0
        }
        var staleSizes: [String: Int] = [:]
        for it in stale { staleSizes[it.url.path] = sizeOf(it.url) }
        stale.sort { (staleSizes[$0.url.path] ?? 0) < (staleSizes[$1.url.path] ?? 0) }

        // 流式 + 全局限并发：parseGate 限制同时 parse 的大文件数（瞬时对象是峰值内存主因，
        // 实测全量并发 parse 达 ~1.9GB）。每个 conv parse 完即在 autoreleasepool 释放原始对象，
        // 只保留 (瘦身 lite + 全文)；小批 flush 进 SQLite，全文不累积全部。
        let group = DispatchGroup()
        let lock = NSLock()
        var batch: [(lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String, userText: String, lastRole: String)] = []
        var barren: [(path: String, mtime: Double)] = []   // 解析了但没产出的
        var revived: [String] = []                         // 曾无产出、这次有了的
        var dupSkipped: [(path: String, mtime: Double)] = []   // 同 id 不同 path 被 upsert 跳过的副本文件
        // 保持 8。曾试过 64（少开事务），实测写库 2.96→3.61s 无收益 ——
        // 写库被 FTS5 trigram 建索引主导，事务开销是噪声级。而 upsert 是
        // 整批一个事务，批越大「一条脏数据连累整批回滚」的爆炸半径越大：
        // 加大批次 = 零收益放大风险。
        let flushThreshold = 8
        // 大文件闸:>32MB 的文件同一时刻只 parse 一个——两个 GB 级瞬时工作集叠加
        // 是首建峰值的放大器。锁序恒定(先 bigGate 后 parseGate),无环无死锁。
        let bigGate = DispatchSemaphore(value: 1)
        let bigFileBytes = 32 * 1024 * 1024
        // 跨文件的池归还计数(2026-08-14 v6):JSONLReader 内的 64MB 归还是单文件
        // 局部的——383 个几十 MB 的文件各自不触发,池水位跨文件累积到 GB
        //(五轮删库实测峰值恒在 1.2-2GB 的真身)。按累积源字节全局计数,
        // 每 64MB 归还一次,池窗口被限制在「64MB 源 × 建树膨胀」内。
        var bytesSinceRelief = 0
        // 体量第二阈值（2026-08-14 首建峰值削减）：8 条「大会话」（5000+ 消息，段文本
        // 数 MB/条）与 8 条小会话的待写内存差百倍——条数阈值对前者形同虚设。累积段
        // 字符 ≥2M（≈6MB 内存）即提前 flush：大会话批次自动缩到 1-2 条，峰值削掉，
        // 事务爆炸半径同向缩小。小会话照旧攒满 8 条，写库节奏不变。
        let flushCharThreshold = 2_000_000
        var batchChars = 0

        for item in stale {
            let isBig = (staleSizes[item.url.path] ?? 0) >= bigFileBytes
            if isBig { bigGate.wait() }
            parseGate.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                var row: (lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String, userText: String, lastRole: String)? = nil
                autoreleasepool {
                    // 段级索引:切段后写入(会话级全文实测 R@1 仅 5.2%)。产物形状由
                    // makeRow 统一(全量路径 IndexRow.from / 大文件流式 streamIndexRow)。
                    if var r = makeRow(item.url) {
                        if TombstoneStore.shared.isBuriedConversation(id: r.lite.id) {
                            // 同 id 换 path 的副本(Codex resume 写新 rollout 等):
                            // path 墓碑拦不住,按 id 拦并补 path 墓碑自愈——row 保持
                            // nil 走 barren 分支(记 skipped,mtime 不变不再碰)。
                            TombstoneStore.shared.buryConversation(id: r.lite.id, path: item.url.path)
                        } else {
                            // 有消息墓碑的会话(用户删过单条):产物要过滤重建——检索/
                            // 语料/Minds 全链路都不许再见到被删消息(半删比不删更糟)。
                            if TombstoneStore.shared.hasBuriedMessages(conversationID: r.lite.id),
                               let filtered = Self.rebuildFilteringBuriedMessages(url: item.url, row: r) {
                                r = filtered
                            }
                            row = (r.lite, r.segments, item.mtime, r.entityText, r.userText, r.lastRole)
                        }
                    }
                }
                parseGate.signal()   // parse 完即放槽（upsert 不占解析并发）
                if isBig {
                    // 大文件收工即归还池:它推高的水位不留给后续文件叠加
                    malloc_zone_pressure_relief(nil, 0)
                    bigGate.signal()
                } else {
                    lock.lock()
                    bytesSinceRelief += staleSizes[item.url.path] ?? 0
                    let relieve = bytesSinceRelief >= 64 * 1024 * 1024
                    if relieve { bytesSinceRelief = 0 }
                    lock.unlock()
                    if relieve { malloc_zone_pressure_relief(nil, 0) }
                }
                defer { group.leave() }
                guard let r = row else {
                    // 记下来，下次不再白解析一遍（sidechain / 观察者日志 / 空文件都走这里）
                    lock.lock(); barren.append((item.url.path, item.mtime)); lock.unlock()
                    return
                }
                var pending: [(lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String, userText: String, lastRole: String)]? = nil
                lock.lock()
                revived.append(item.url.path)
                batch.append(r)
                batchChars += r.segments.reduce(0) { $0 + $1.text.count }
                    + r.entityText.count + r.userText.count
                if batch.count >= flushThreshold || batchChars >= flushCharThreshold {
                    pending = batch; batch = []; batchChars = 0
                }
                lock.unlock()
                if let p = pending {
                    do {
                        let dups = try index.upsert(p)
                        if !dups.isEmpty { lock.lock(); dupSkipped.append(contentsOf: dups); lock.unlock() }
                    }
                    catch { NSLog("[index] upsert batch failed (%d items): %@", p.count, String(describing: error)) }
                }
            }
        }
        group.wait()
        lock.lock()
        let rest = batch; batch = []
        var barrenSnapshot = barren; barren = []
        let revivedSnapshot = revived; revived = []
        var dupSnapshot = dupSkipped; dupSkipped = []
        lock.unlock()
        if !rest.isEmpty {
            do { dupSnapshot.append(contentsOf: try index.upsert(rest)) }
            catch { NSLog("[index] upsert batch failed (%d items): %@", rest.count, String(describing: error)) }
        }
        // 被过滤/解析失败的文件若曾在早期状态入过库——如「活跃会话豁免」窗口里的
        // 半成品，随后补齐成 API Error 残骸被过滤——旧记录会变成幽灵条目：列表可见、
        // 详情读取被同一过滤器拒掉，误报「源文件已无法读取」。跳过之前先删同路径既有行。
        index.prune(missingPaths: barrenSnapshot.map(\.path))
        // 副本文件（同 id 不同 path 被 upsert 跳过）并入 skipped：不记的话它的 mtime
        // 永远不入库，每轮扫描都白解析一遍再被跳过。必须在 unmarkSkipped 之后落库——
        // revived 含所有产出过 conv 的路径（包括副本），先摘后记才能让标记存活。
        barrenSnapshot.append(contentsOf: dupSnapshot)
        index.unmarkSkipped(revivedSnapshot)   // 先摘旧标记，再记新的，避免同路径两边都有
        index.markSkipped(barrenSnapshot)
    }

    private static func mtime(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}

extension LoaderRuntime {
    /// 活跃会话走增量、其余走全量的统一入口。
    ///
    /// 命中条件严格：文件必须变大、且文件头指纹未变（有些工具会重写整个文件而不是追加，
    /// 那种情况下续读会把旧内容当新的）。任一不满足就退回全量，宁可慢也不能错。
    static func parseWithIncrementalCache(
        url: URL,
        incremental: (Conversation, [Message], UInt64) -> Conversation?,
        fullParse: () -> Conversation?
    ) -> Conversation? {
        let path = url.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
            .flatMap { $0 }.map(UInt64.init) ?? 0

        if let base = IncrementalParseCache.shared.baseline(for: path, currentSize: size),
           let conv = incremental(base.conv, base.conv.messages, base.offset) {
            if let boundary = IncrementalParseCache.lastLineBoundary(of: path) {
                IncrementalParseCache.shared.put(path: path, offset: boundary, conv: conv)
            }
            return conv
        }

        guard let conv = fullParse() else { return nil }
        // 只缓存「有可能继续被写入」的：刚动过的文件才值得占那几十 MB 内存
        if let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date).flatMap({ $0 }),
           Date().timeIntervalSince(m) < 3600,
           let boundary = IncrementalParseCache.lastLineBoundary(of: path) {
            IncrementalParseCache.shared.put(path: path, offset: boundary, conv: conv)
        }
        return conv
    }
}
