import Foundation

/// 把 Minds 注入文本写进用户全局 `~/.claude/CLAUDE.md` 的**受管分节**。
///
/// 闸门纪律(spec §5):只有 confirmed 条目 + 机械紧凑版能走到这里,且写入动作
/// 必须由用户在 GUI 亲手触发(人在环)——本类型只提供机械能力,不自作主张。
///
/// 受管分节 = 一对标记之间的内容,MindBus 只动标记内的部分:
/// 用户自己写的其余内容一个字不碰;重复注入是幂等替换;移除即删整段。
public enum MindsInjection {

    public static let beginMarker = "<!-- mindbus-minds-begin -->"
    public static let endMarker = "<!-- mindbus-minds-end -->"

    /// 用户全局 CLAUDE.md。测试一律注入临时路径,绝不碰真实文件。
    public static var defaultTargetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("CLAUDE.md")
    }

    /// 注入或更新受管分节。返回是否成功。
    ///
    /// - 文件不存在:创建,内容 = 受管分节。
    /// - 已有受管分节:**替换**标记之间的内容(幂等)。
    /// - 无受管分节:末尾追加(与既有内容之间空一行)。
    /// - 只找到一半标记(用户手改坏了):不动文件返回 false——宁可不写,
    ///   也不能猜测边界把用户自己的内容吞进受管段。
    @discardableResult
    public static func inject(content: String, into url: URL = defaultTargetURL) -> Bool {
        let block = "\(beginMarker)\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n\(endMarker)"
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try (block + "\n").write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch { return false }
        }
        guard let data = fm.contents(atPath: url.path) else { return false }
        let existing = String(decoding: data, as: UTF8.self)

        let hasBegin = existing.contains(beginMarker)
        let hasEnd = existing.contains(endMarker)
        let updated: String
        switch (hasBegin, hasEnd) {
        case (true, true):
            guard let b = existing.range(of: beginMarker),
                  let e = existing.range(of: endMarker), b.lowerBound < e.upperBound
            else { return false }
            updated = existing.replacingCharacters(in: b.lowerBound..<e.upperBound, with: block)
        case (false, false):
            let sep = existing.hasSuffix("\n\n") ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
            updated = existing + sep + block + "\n"
        default:
            // 半个标记:边界不可信,拒绝写入
            return false
        }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    /// 移除受管分节(含标记)。文件不存在或无完整分节 = 无操作返回 false。
    @discardableResult
    public static func remove(from url: URL = defaultTargetURL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        let existing = String(decoding: data, as: UTF8.self)
        guard let b = existing.range(of: beginMarker),
              let e = existing.range(of: endMarker), b.lowerBound < e.upperBound
        else { return false }
        var updated = existing.replacingCharacters(in: b.lowerBound..<e.upperBound, with: "")
        // 收掉替换后残留的连续空行(最多留一个空行)
        while updated.contains("\n\n\n") {
            updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    /// 目标文件里当前是否已有受管分节(GUI 用来切换「注入/更新」与「移除」按钮)。
    public static func hasSection(at url: URL = defaultTargetURL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains(beginMarker) && text.contains(endMarker)
    }
}
