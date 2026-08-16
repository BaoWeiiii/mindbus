import Foundation

/// 你关注的词(2026-08-16)。
///
/// 为什么需要人来点这一下:13 轮算法实验证明「哪些词有个性」是语义判断,
/// 不是统计属性——TF-IDF / 残差 IDF / 分布熵 / 基尼 / 卡方 / 共现广度 / 汉语
/// 语法位置过滤…最好的 AUC 0.85 却 top30 命中 0,因为这些词在词频光谱的中间带,
/// 任何单调排序只捞两个极端。「第一性原理」和「类似」在所有统计维度上不可分,
/// 区分它们需要知道词义,而词义只在三个地方:外部词典(不引)、大模型(零 LLM
/// 红线)、或者你自己。
///
/// 所以分工:**你给语义(点一下),机器给统计(永久追踪)**——与 Minds 的
/// WEAK SPOTS 同一哲学(数不出来的部分交给人)。点过的词从此在「你关注的词」
/// 里长期记账:说了多少次、跨几个项目、隔了多久还在说。
public final class PinnedWordsStore {

    public static let shared = PinnedWordsStore()

    private var words: [String]          // 保序:先关注的排前
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        let defaultURL: URL
        if ConversationStore.isRunningTests() {
            defaultURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mb-test-pinned-\(ProcessInfo.processInfo.processIdentifier).json")
        } else {
            defaultURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mindbus", isDirectory: true)
                .appendingPathComponent("pinned-words.json")
        }
        self.fileURL = fileURL ?? defaultURL
        if let data = FileManager.default.contents(atPath: self.fileURL.path),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            words = list
        } else {
            words = []
        }
    }

    public var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return words
    }

    public func isPinned(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return words.contains(word)
    }

    public func toggle(_ word: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = words.firstIndex(of: word) { words.remove(at: i) } else { words.append(word) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(words) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
