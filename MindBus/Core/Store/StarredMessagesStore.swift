import SwiftUI

/// 一条收藏记录。收藏对象是**单条原始消息**(规格 §2.1)——不是摘要不是笔记。
/// `contentSnapshot` 是收藏当刻抓的正文快照,仅作原消息不可用时的兜底展示,
/// 不取代 messageID 引用(规格 §14)。
public struct FavoriteRecord: Codable, Identifiable, Equatable {
    public var id: String { key }
    /// "conversationID#messageID"——与旧版键格式一致。
    public let key: String
    public let conversationID: String
    public let messageID: String
    public let role: String
    public let favoritedAt: Date
    public var contentSnapshot: String
    /// 软删除时刻。非 nil = 已取消收藏但在撤销窗口内(规格 §8.3:8-10 秒可撤销;
    /// 这里宽限到下次冷启动清理,撤销永远来得及)。
    public var softDeletedAt: Date? = nil
}

/// 首页的对话聚合单位(规格 §2.2:收藏对象是消息,浏览单位是对话)。
public struct FavoriteConversationSummary: Identifiable, Equatable {
    public var id: String { conversationID }
    public let conversationID: String
    public let favoriteCount: Int
    public let lastFavoriteAt: Date
    /// 最近一条收藏的快照(列表摘要)。
    public let latestPreview: String
}

/// 消息收藏存储。
///
/// `~/.mindbus/starred-messages.json`(可整体带走);GUI 单进程写原子落盘,
/// MCP 侧不写(只读纪律)。v2 格式为 [FavoriteRecord];v1 的裸 [String] 键数组
/// 读入时自动迁移(favoritedAt 取迁移时刻,快照留空——旧数据没有的信息不伪造)。
@MainActor
public final class StarredMessagesStore: ObservableObject {

    public static let shared = StarredMessagesStore()

    @Published public private(set) var records: [String: FavoriteRecord] = [:]

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("starred-messages.json")
        load()
    }

    public static func key(conversationID: String, messageID: String) -> String {
        conversationID + "#" + messageID
    }

    // MARK: - 查询

    /// 有效收藏(未软删)。
    public func isStarred(_ key: String) -> Bool {
        records[key].map { $0.softDeletedAt == nil } ?? false
    }

    public func record(for key: String) -> FavoriteRecord? { records[key] }

    /// 有效收藏总数(消息级)。
    public var activeCount: Int { records.values.filter { $0.softDeletedAt == nil }.count }

    /// 某会话的有效收藏,按**原消息在对话中的顺序**由调用方另行排——
    /// 这里按 favoritedAt 给出,消息序需要 messages 数组(视图层有)。
    public func activeRecords(conversationID: String) -> [FavoriteRecord] {
        records.values.filter { $0.conversationID == conversationID && $0.softDeletedAt == nil }
    }

    /// 首页聚合:每个含收藏的会话一条 summary(规格 §2.2 不重复展示)。
    public func summaries() -> [FavoriteConversationSummary] {
        var byConv: [String: [FavoriteRecord]] = [:]
        for r in records.values where r.softDeletedAt == nil {
            byConv[r.conversationID, default: []].append(r)
        }
        return byConv.map { convID, recs in
            let latest = recs.max { $0.favoritedAt < $1.favoritedAt }!
            return FavoriteConversationSummary(
                conversationID: convID, favoriteCount: recs.count,
                lastFavoriteAt: latest.favoritedAt, latestPreview: latest.contentSnapshot)
        }
    }

    /// 最近收藏消息流(右栏「最近收藏」/「全部收藏消息」,favoritedAt 倒序)。
    public func recentFavorites(limit: Int = .max) -> [FavoriteRecord] {
        Array(records.values.filter { $0.softDeletedAt == nil }
            .sorted { $0.favoritedAt > $1.favoritedAt }
            .prefix(max(0, limit)))
    }

    // MARK: - 写入

    /// 收藏(带快照);已软删的同键收藏 = 撤销软删(恢复原记录,不丢原 favoritedAt)。
    public func star(conversationID: String, messageID: String, role: String, snapshot: String) {
        let key = Self.key(conversationID: conversationID, messageID: messageID)
        if var existing = records[key] {
            existing.softDeletedAt = nil
            records[key] = existing
        } else {
            records[key] = FavoriteRecord(
                key: key, conversationID: conversationID, messageID: messageID,
                role: role, favoritedAt: Date(),
                contentSnapshot: String(snapshot.prefix(500)))
        }
        persist()
    }

    /// 取消收藏 = 软删(规格 §8.3:不弹确认,Toast 撤销)。
    public func unstar(_ key: String) {
        guard var r = records[key] else { return }
        r.softDeletedAt = Date()
        records[key] = r
        persist()
    }

    /// 撤销取消。
    public func restore(_ key: String) {
        guard var r = records[key] else { return }
        r.softDeletedAt = nil
        records[key] = r
        persist()
    }

    /// 彻底删除(规格 §8.4 的「删除此条消息」,经确认后;同样先软删可撤销,
    /// 撤销期后由 purge 清走——这里直接物理删供撤销期结束时调用)。
    public func purge(_ key: String) {
        records.removeValue(forKey: key)
        persist()
    }

    // MARK: - 存取

    private func load() {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return }
        if let v2 = try? JSONDecoder.iso.decode([FavoriteRecord].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: v2.map { ($0.key, $0) })
        } else if let v1 = try? JSONDecoder().decode([String].self, from: data) {
            // v1 迁移:裸键数组 → 记录。favoritedAt 取迁移时刻;快照留空(不伪造)。
            let now = Date()
            for key in v1 {
                let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                records[key] = FavoriteRecord(key: key, conversationID: parts[0],
                                              messageID: parts[1], role: "",
                                              favoritedAt: now, contentSnapshot: "")
            }
            persist()   // 立即升格落盘
        }
        // 冷启动清理:软删超过 1 天的真删(撤销窗口早已关闭)
        let cutoff = Date().addingTimeInterval(-86_400)
        let stale = records.values.filter { ($0.softDeletedAt ?? .distantFuture) < cutoff }
        if !stale.isEmpty {
            for r in stale { records.removeValue(forKey: r.key) }
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso.encode(Array(records.values).sorted { $0.key < $1.key })
        else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]; return e
    }
}
