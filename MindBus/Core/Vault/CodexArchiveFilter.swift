import Foundation

/// Codex 会话的归档过滤（存储计划的 B 方案）。
///
/// Claude 系走整拷（位级保真），Codex 不能——实测 `~/.codex/sessions` 主会话 2.99 GiB 里
/// **62.7% 是 agent 截图**（工具输出内嵌 1283.6 MiB + compacted 重复内嵌 399.7 MiB +
/// browser 注入 176.7 MiB）、**22.2% 是 event_msg 遥测**，真正的对话文本不足 0.4%。
/// 整拷要多占 1.2 GiB，而丢掉的恰是图片政策早已判定「永不展示」的字节。
///
/// **实现铁律：只做「整行丢弃」与「行内 data URI 字符串替换」，绝不重新序列化 JSON。**
/// 原因是踩过的一个坑：`CodexLoader.messageLineFilter` 为省内存做字节级预筛，
/// **只扫每行前 256 字节**找 "response_item"；而 `JSONSerialization` 不保证键序，
/// 重新序列化可能把 "payload" 排到 "type" 前面，大 payload 一挤就把 "response_item"
/// 推出预筛窗口，于是整行被解析器**静默跳过**。真实会话实测由此从 206 条消息掉到
/// 147 条——240 条 message 行一条不少、JSON 语义也完全正确，只有拿真实大会话才看得见。
/// 字符串级替换保住原始键序与其余全部字节，天生免疫这个问题。
///
/// 不做文本截断：工具输出文本只占 3.8%，截断省不了多少却真丢内容。
///
/// **已知限制**：`strippingDataURIs` 是整行正则替换，无法区分「图片字段里的 data URI」
/// 与「正文里当文本贴的 data URI」。后者（用户粘一段 data URI 问「这是什么图」）会被一并
/// 换成占位符，所以准确的说法是「保对话正文文本，内联 data URI 文本除外」，不是「一字不差」。
/// 为什么接受：若把匹配收紧到 `"image_url":"…"` 字段，就会漏掉占体积 62.7% 的工具输出内嵌
/// 截图；而受「绝不重新序列化 JSON」这条铁律所限，也无法按字段结构精确定位。两害取轻。
public enum CodexArchiveFilter {

    /// 逐行流式过滤 `source` 写入 `destination`，返回写出的行数。
    ///
    /// 流式而非整读：Codex 单个 rollout 文件实测可达 395 MB，整读进内存正是当初
    /// 首次建库 1.2 GB 内存峰值的成因。
    @discardableResult
    public static func filter(source: URL, to destination: URL) throws -> Int {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var written = 0
        try JSONLReader.forEachLine(fileURL: source, maxLineBytes: maxLineBytes) { line in
            guard let kept = filterLine(line) else { return }
            try out.write(contentsOf: Data((kept + "\n").utf8))
            written += 1
        }
        return written
    }

    /// 单行字节上限：`compacted` 行内嵌整会话累积的 base64 截图，单行实测可达 155 MB。
    /// 与 `CodexLoader.defaultMaxLineBytes` 同口径——超限的行本来就整行都是要丢的图。
    static let maxLineBytes = CodexLoader.defaultMaxLineBytes

    /// 过滤单行：返回要写出的行（原行或剥图后的行）；`nil` = 丢弃这一行。
    /// 判定走 lean 解码(2026-08-15):每行 JSONSerialization 建树曾是归档尾段把
    /// 峰值推回 1.9GB 的最后推手(720MB rollout 逐行 NSDictionary)。lean 只为判定
    /// 抽字段,**输出仍是原行字节**——「绝不重新序列化」铁律不受影响。
    static func filterLine(_ line: String) -> String? {
        guard line.hasPrefix("{"),
              let l = LeanLineParser.decodeCXLine(line) else { return nil }

        switch l.type {
        case "event_msg", "turn_context":
            // 遥测/状态流与逐轮环境快照：占 23% 体积，loader 压根不读
            return nil

        case "compacted":
            // 摘要文本留着（将来可能要展示），里面重复内嵌的历史截图剥掉
            return strippingDataURIs(line)

        case "response_item":
            guard let payload = l.payload else { return line }
            switch payload.type {
            case "reasoning":
                // 加密推理：任何人都渲染不出来，零保留价值
                return nil
            case "message":
                // 用户主动附件图按政策保留 → 整行原样；否则（browser 注入截图等）剥掉。
                // 判定口径与 `CodexLoader` 一致，否则会出现「归档留了图但 loader 不显示」的错位。
                return hasUserAttachedImages(payload) ? line : strippingDataURIs(line)
            case "function_call_output", "custom_tool_call_output":
                // 工具输出里内嵌的截图剥掉，输出文本保留
                return strippingDataURIs(line)
            default:
                return line   // function_call / web_search_call 等原样留，是执行时间线的原料
            }

        default:
            return line       // session_meta 等原样留
        }
    }

    // MARK: - 细节

    /// 这条消息是否带「用户主动附件图」——与 `CodexLoader.parseLine` 同一判据：
    /// `role == user` 且同条消息的文本里含 `# Files mentioned by the user:`。
    private static func hasUserAttachedImages(_ payload: LeanLineParser.CXPayload) -> Bool {
        guard payload.role == "user", let content = payload.content else { return false }
        let merged = content.compactMap { c -> String? in
            switch c.type {
            case "input_text", "output_text", "summary_text": return c.text
            default: return nil
            }
        }.joined(separator: "\n")
        return merged.contains("# Files mentioned by the user:")
    }

    private static let dataURIPattern = try! NSRegularExpression(
        pattern: "data:image/[a-zA-Z0-9+.-]+;base64,[A-Za-z0-9+/=]+")

    /// 把行内所有 data URI 图换成占位符，其余字节一律不动（含键序）。
    ///
    /// 换成 `[image dropped]` 而不是空串：留下痕迹，将来看归档的人能知道这里原本有图、
    /// 是被政策丢掉的，而不是数据损坏。`CodexLoader.parseDataURIImage` 对非 data URI
    /// 返回 nil，于是该图块自然不进 blocks——与「不展示 agent 截图」的既有行为一致。
    private static func strippingDataURIs(_ line: String) -> String {
        // 先做一次廉价子串预检再上正则：绝大多数行里没有图。
        // 不用「长度阈值」做预检——小图的 data URI 可以很短，那样会漏。
        guard line.contains("data:image/") else { return line }
        return dataURIPattern.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..., in: line),
            withTemplate: "[image dropped]")
    }
}
