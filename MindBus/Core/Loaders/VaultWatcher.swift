import Foundation

/// 监听对话来源目录，有写入才通知刷新。
///
/// 此前刷新完全靠「App 激活 + 30 秒节流」推动，两头都不理想：
/// - 你在终端聊完切回来，若 30 秒内刚好刷新过，新消息看不到 —— 而这正是最想看到它的时刻
/// - 没有任何变化时，每次激活照样跑一遍全量枚举
///
/// FSEvents 把两件事一起解决：无变化时零开销，有变化时秒级送达。
/// `latency` 让系统替我们合并抖动（AI 工具是逐条追加写的，一次回答会触发很多次写入）。
public final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ai.mindbus.watcher")
    private let onChange: () -> Void

    /// - Parameter onChange: 在主队列回调。
    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    public func start(paths: [String]) {
        stop()
        // 目录不存在也照样注册：用户可能装了工具但还没用过，
        // FSEvents 支持监听尚不存在的路径，创建后会自动开始送事件。
        guard !paths.isEmpty else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onChange() }
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,   // 合并 2 秒内的连续写入：一次 AI 回答会产生大量追加
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// 三个来源的根目录。
    public static var watchedPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects").path,
            home.appendingPathComponent(".codex/sessions").path,
            home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions").path,
        ]
    }
}
