import Foundation

/// 墓碑表:用户的删除记录(2026-08-15 删除功能)。
///
/// 删除语义 = 「从 MindBus 抹除,源文件不动」:索引行删 + 归档副本删 + 这里记
/// 墓碑防扫描复活。对话按 (id, path) 双记——扫描按 path 拦(mtime 对账层),
/// 消息按 (conversationID → messageID 集) 记,重灌时在 parse 后过滤。
///
/// **为什么不存 index.sqlite**:数据政策升级会 DROP 全表重建,墓碑在库里就等于
/// 删除记录随升级蒸发、删过的对话全部复活。放 `~/.mindbus/deleted.json`
/// (与 starred-messages / muted-resurface 同族,用户可见、可整体带走)。
public final class TombstoneStore {

    public static let shared = TombstoneStore()

    private struct Payload: Codable {
        var conversationIDs: [String] = []
        var conversationPaths: [String] = []
        var messages: [String: [String]] = [:]
    }

    private var buriedIDs: Set<String>
    private var buriedPaths: Set<String>
    private var buriedMessagesByConv: [String: Set<String>]
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        // 测试隔离铁律:XCTest 环境下 shared 也走临时路径——测试绝不碰真实
        // ~/.mindbus/deleted.json(曾发生测试在生产库跑迁移的事故,同款防线)。
        let defaultURL: URL
        if ConversationStore.isRunningTests() {
            defaultURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mb-test-deleted-\(ProcessInfo.processInfo.processIdentifier).json")
        } else {
            defaultURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mindbus", isDirectory: true)
                .appendingPathComponent("deleted.json")
        }
        self.fileURL = fileURL ?? defaultURL
        if let data = FileManager.default.contents(atPath: self.fileURL.path),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            buriedIDs = Set(payload.conversationIDs)
            buriedPaths = Set(payload.conversationPaths)
            buriedMessagesByConv = payload.messages.mapValues(Set.init)
        } else {
            buriedIDs = []
            buriedPaths = []
            buriedMessagesByConv = [:]
        }
    }

    // MARK: - 对话墓碑

    public func buryConversation(id: String, path: String) {
        lock.lock(); defer { lock.unlock() }
        buriedIDs.insert(id)
        buriedPaths.insert(path)
        persist()
    }

    public func isBuriedPath(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return buriedPaths.contains(path)
    }

    public func isBuriedConversation(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return buriedIDs.contains(id)
    }

    // MARK: - 消息墓碑

    public func buryMessages(conversationID: String, messageIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        buriedMessagesByConv[conversationID, default: []].formUnion(messageIDs)
        persist()
    }

    public func buriedMessages(conversationID: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return buriedMessagesByConv[conversationID] ?? []
    }

    public func hasBuriedMessages(conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(buriedMessagesByConv[conversationID]?.isEmpty ?? true)
    }

    // MARK: - 持久化(调用方须持锁)

    private func persist() {
        let payload = Payload(conversationIDs: buriedIDs.sorted(),
                              conversationPaths: buriedPaths.sorted(),
                              messages: buriedMessagesByConv.mapValues { $0.sorted() })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
