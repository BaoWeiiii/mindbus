import Darwin
import Foundation

/// 思脉底座 · WEAK SPOTS 的四个空位（spec §2 第 6 节）：机械统计证明不了的四类
/// 自陈述——机械层只能证明「出现过」，证明不了「主力/偏好/节奏/目标」，只能靠
/// 宿主模型从对话史里读出来，再由用户在 GUI 确认或撤销。
public enum MindsSpot: String, Equatable, Hashable, CaseIterable, Codable {
    case preferences = "spot:preferences"
    case style = "spot:style"
    case goals = "spot:goals"
    case stack = "spot:stack"
}

/// `enriched.jsonl` 里 `enrich`/`revoke`/`confirm` 三种 append 记录按
/// `id`/`target` 合并后的一条增补现状。
public struct MindsEntry: Identifiable, Equatable {
    public let id: String
    public let spot: MindsSpot
    public let text: String
    public let sources: [String]
    public let agent: String
    public let createdAt: Date
    public let status: Status

    public enum Status: String, Equatable, Hashable {
        case unreviewed
        case confirmed
        case revoked
    }

    public init(id: String, spot: MindsSpot, text: String, sources: [String], agent: String,
                createdAt: Date, status: Status) {
        self.id = id
        self.spot = spot
        self.text = text
        self.sources = sources
        self.agent = agent
        self.createdAt = createdAt
        self.status = status
    }
}

/// 思脉底座 · 增补层：`~/.mindbus/minds/enriched.jsonl` 的读写与状态合并。
///
/// 物理形态（spec §1/§3）：append-only；一行一条 JSON 记录，三种 `kind`——
/// `enrich`（宿主模型补一条陈述，带溯源）/ `confirm`（用户确认）/ `revoke`（撤销）。
/// 确认与撤销不物理删改已写的 `enrich` 行，本身也是新 append 的一行——这与
/// `MCPRefLog`（引用日志）同构，理由也相同：GUI（App 进程）与 MCP（宿主拉起的
/// 独立子进程）可能并发写同一个文件，「只 append、读时合并」是唯一不需要跨进程
/// 加锁就安全的形状（一改就要处理「谁持锁、锁多久、崩了怎么办」，append-only
/// 把这类问题连根切掉）。
///
/// 与 `MCPRefLog.append` 的一处刻意不同：那边任何失败都静默吞掉（引用计数丢一条
/// 无所谓，绝不能让只读的 `memory_open` 因为记不上账而报错）；这里 `appendEnrich`
/// 是**用户可感动作**——是宿主模型在响应用户「帮我补一条」时写下的东西，写失败要
/// 能让上层（未来的 `MindsEnrichTool`）报 `isError` 而不是无声吞掉，所以返回
/// `String?` 让调用方自己判断，不学 `MCPRefLog` 全吞。
public enum MindsEnrichedLog {

    /// minds 根目录：`~/.mindbus/minds`（与 `MindsBuilder.defaultMindsURL` 的
    /// `minds.md` 并列同一个目录）。`MINDBUS_MINDS_ROOT` 可覆盖——
    /// 与 `MCPIndexAccess.defaultIndexPath` 的 `MINDBUS_INDEX_PATH` 同模式：
    /// trim 后为空视同未设置（不 trim 的话纯空白会被当成合法目录名，后续操作在一个
    /// 诡异路径上悄悄失败）；`~` 手工展开——这个值多半来自宿主配置文件、不经过
    /// shell，shell 的波浪号展开不会发生在这里，原样传给 `FileManager` 只会被当成
    /// 字面量目录名，路径永远不存在。
    ///
    /// 非 `private`：`MindsBuilder.defaultMindsURL`（同目录下的 `minds.md`）复用这一份
    /// 解析——根目录解析只能有一处真相，两处各写一遍环境变量/波浪号展开逻辑迟早会漂移。
    static func mindsRoot() -> URL {
        if let raw = ProcessInfo.processInfo.environment["MINDBUS_MINDS_ROOT"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("minds", isDirectory: true)
    }

    public static var defaultLogURL: URL {
        mindsRoot().appendingPathComponent("enriched.jsonl")
    }

    /// 追加一条 `enrich` 记录，返回新条目 id（`UUID().uuidString`）。
    ///
    /// 失败（目录建不出来 / 文件打不开 / 写入失败）返回 `nil`。`sources`/`text`
    /// 在这一层不做非空或存在性校验——那是未来 `MindsEnrichTool`（spec §3/§4）的
    /// 职责：它还要拿 `sources` 里每个 conversation_id 去跟索引核对是否真实存在
    /// （反幻觉守卫），需要依赖 `ConversationIndex`，这一层刻意不依赖它，保持
    /// 存储层纯粹、可独立测试。
    @discardableResult
    public static func appendEnrich(spot: MindsSpot, text: String, sources: [String], agent: String,
                                    at date: Date = Date(), to url: URL = defaultLogURL) -> String? {
        let id = UUID().uuidString
        let obj: [String: Any] = [
            "kind": "enrich",
            "id": id,
            "spot": spot.rawValue,
            "text": text,
            "sources": sources,
            "agent": agent,
            "ts": date.timeIntervalSince1970,
        ]
        return writeLine(obj, to: url) ? id : nil
    }

    /// 追加一条 `revoke` 记录。`target` 是否指向一个真实存在的 `enrich.id`
    /// 在这里不校验——写入不读文件（O_APPEND 的意义就是不做「先读再写」），
    /// 未知 `target` 留给 `entries()` 合并时静默忽略。
    @discardableResult
    public static func appendRevoke(target: String, at date: Date = Date(), to url: URL = defaultLogURL) -> Bool {
        writeLine(["kind": "revoke", "target": target, "ts": date.timeIntervalSince1970], to: url)
    }

    /// 追加一条 `confirm` 记录。同 `appendRevoke`，不校验 `target`。
    @discardableResult
    public static func appendConfirm(target: String, at date: Date = Date(), to url: URL = defaultLogURL) -> Bool {
        writeLine(["kind": "confirm", "target": target, "ts": date.timeIntervalSince1970], to: url)
    }

    /// 底层 append：POSIX `open(2)` 带 `O_APPEND`，照抄 `MCPRefLog.append` 的写法
    /// 与理由（`MindBus/Core/MCP/MCPRefLog.swift`）。
    ///
    /// 为什么不用 `FileHandle(forWritingTo:) + seekToEnd() + write()`：实测两个
    /// 进程并发调用（比如 GUI App 扫描收尾与某个宿主拉起的 MCP server 同时写）
    /// 会丢行——`FileHandle(forWritingTo:)` 打开的文件描述符不带 `O_APPEND`，
    /// `seekToEnd()` 与随后的 `write()` 是两次独立系统调用，中间的窗口会被另一个
    /// 进程的 append 插入：两边都 seek 到同一个旧末尾后各自 write，后写者覆盖
    /// 先写者而不是接在后面，行被撕裂或整条吞掉。POSIX `open(2)` 带 `O_APPEND`
    /// 把「移到末尾」与「写入」收进内核里的同一个原子操作，只要单次 write 不超过
    /// 本地文件系统的原子写上限（这里一行是几百字节的 JSON，远小于 4KB），并发
    /// append 就不会互相覆盖或截断——`testConcurrentAppendDoesNotTearLines` 在
    /// 下面用真的多线程压力验证这一点，不只停在注释里的论证。
    ///
    /// `O_CREAT` 直接带在 `open(2)` 里而不是「先 `fileExists` 判断、不存在再建」：
    /// 后者两步之间同样有竞态窗口——两个进程都查到文件不存在都去建，后者会把
    /// 先者刚写的内容截断清空。`O_CREAT` 由内核保证「不存在则建、存在则直接开」
    /// 是单一原子操作，没有这个窗口。
    @discardableResult
    private static func writeLine(_ obj: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return false
        }
        // 目录首次可能不存在（用户还没扫描过一次，或测试注入的临时路径）——
        // `withIntermediateDirectories: true` 在目标目录已存在时不报错；并发下
        // 两个进程都调用也不冲突（底层 `mkdir` 的 `EEXIST` 在这个参数下不算失败）。
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        var line = data
        line.append(0x0A)

        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    /// 全文件合并：`enrich` 建条，`confirm`/`revoke` 按 `target` 改状态。
    ///
    /// 合并规则（spec §3 + 任务简报）：
    /// - 未知 `target`（从未在文件里出现过对应 `enrich.id` 的 `confirm`/`revoke`）
    ///   静默忽略，不产生幽灵条目。
    /// - `revoke` 是吸收态（终态）：只要某个 target 出现过至少一条 `revoke`，
    ///   最终状态就是 `revoked`——无论这条 `revoke` 相对同 target 的 `confirm`
    ///   在文件里是先写还是后写。「撤销」在产品语义上是终局动作，不该被一条
    ///   （哪怕是乱序到达的）`confirm` 复活。因此下面用两个 `Set`
    ///   （`confirmedTargets`/`revokedTargets`）分别收集，而不是按文件物理顺序
    ///   逐条应用状态转移——判定只看「这个 target 有没有出现过 revoke」，与两种
    ///   记录的相对先后无关，重复记录天然幂等（`Set` 插入本就幂等）。
    /// - 同一个 `id` 出现多条 `enrich`（正常路径不会发生，`id` 是 `UUID`）：
    ///   后一条覆盖前一条的内容字段，但排序位置留在第一次出现处，不让重复写入
    ///   打乱输出顺序。
    /// - 坏行（半截 JSON / 缺字段 / 字段类型不对 / 未知 `kind` / 非法枚举值）与
    ///   非法 UTF-8 字节：跳过所在行，不影响其余行。解码用 `String(decoding:as:)`
    ///   的不可失败形态——`ConversationIndex.ingestRefLog` 已经踩过这个坑：
    ///   可失败的 `String(data:encoding:)` 遇到文件里任何一个坏字节就整体返回
    ///   `nil`，下游把「解不出来」等同于「文件是空的」；而 append-only 日志永不
    ///   自愈，一个字节能让此后每次合并都清零。这里同样只能用不可失败解码，
    ///   坏字节退化成 U+FFFD、只废掉所在这一行的 JSON 解析，之前之后的行不受影响。
    public static func entries(from url: URL = defaultLogURL) -> [MindsEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let text = String(decoding: data, as: UTF8.self)

        struct Draft {
            var spot: MindsSpot
            var text: String
            var sources: [String]
            var agent: String
            var createdAt: Date
        }

        var drafts: [String: Draft] = [:]
        var order: [String] = []
        var confirmedTargets = Set<String>()
        var revokedTargets = Set<String>()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = obj["kind"] as? String else { continue }
            switch kind {
            case "enrich":
                // NSNumber.doubleValue 而不是直接 `as? Double`：JSONSerialization
                // 把无小数点的整数字面量解析成整型存储的 NSNumber，Swift 的
                // `as? Double` 动态转换在这种情况下不总能命中；`.doubleValue`
                // 不管底层是整型还是浮点存储都能正确转换（同 ingestRefLog）。
                guard let id = obj["id"] as? String,
                      let spotRaw = obj["spot"] as? String,
                      let spot = MindsSpot(rawValue: spotRaw),
                      let entryText = obj["text"] as? String,
                      let sources = obj["sources"] as? [String],
                      let agent = obj["agent"] as? String,
                      let ts = (obj["ts"] as? NSNumber)?.doubleValue else { continue }
                if drafts[id] == nil { order.append(id) }
                drafts[id] = Draft(spot: spot, text: entryText, sources: sources, agent: agent,
                                    createdAt: Date(timeIntervalSince1970: ts))
            case "confirm":
                if let target = obj["target"] as? String { confirmedTargets.insert(target) }
            case "revoke":
                if let target = obj["target"] as? String { revokedTargets.insert(target) }
            default:
                continue
            }
        }

        return order.compactMap { id in
            guard let d = drafts[id] else { return nil }
            let status: MindsEntry.Status = revokedTargets.contains(id) ? .revoked
                : (confirmedTargets.contains(id) ? .confirmed : .unreviewed)
            return MindsEntry(id: id, spot: d.spot, text: d.text, sources: d.sources, agent: d.agent,
                               createdAt: d.createdAt, status: status)
        }
    }
}
