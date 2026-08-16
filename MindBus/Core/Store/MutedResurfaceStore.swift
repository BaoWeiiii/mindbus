import Foundation

/// 重浮屏蔽表:「那年今日」不想再见的会话(Apple 照片「被回忆伤害」教训——
/// 被动唤起的记忆必须配一键「别再给我看这条」)。
///
/// 存 `~/.mindbus/muted-resurface.json`(裸 id 数组,与 vault/minds 并列可整体带走);
/// 只影响重浮类展示(ON THIS DAY),不影响列表/搜索/详情——屏蔽的是「突然弹出」,
/// 不是对话本身。
public final class MutedResurfaceStore {

    public static let shared = MutedResurfaceStore()

    private var muted: Set<String>
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("muted-resurface.json")
        if let data = FileManager.default.contents(atPath: self.fileURL.path),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            muted = Set(ids)
        } else {
            muted = []
        }
    }

    public func isMuted(_ conversationID: String) -> Bool { muted.contains(conversationID) }

    public func mute(_ conversationID: String) {
        muted.insert(conversationID)
        persist()
    }

    public func unmute(_ conversationID: String) {
        muted.remove(conversationID)
        persist()
    }

    public func filter(_ ids: Set<String>) -> Set<String> { ids.subtracting(muted) }

    private func persist() {
        guard let data = try? JSONEncoder().encode(muted.sorted()) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
