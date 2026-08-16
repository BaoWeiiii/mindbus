import Foundation

/// 解析 Anthropic / Claude Code / Cursor / OpenClaw JSONL 的 content 字段。
/// 三家结构高度一致：content 可以是 String，也可以是 [{type, ...}] 数组。
public enum ContentBlockParser {

    public static func parse(_ content: Any?) -> [ContentBlock] {
        if let s = content as? String {
            return [.text(s)]
        }
        guard let arr = content as? [[String: Any]] else { return [] }

        var result: [ContentBlock] = []
        for block in arr {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let t = block["text"] as? String {
                    result.append(.text(t))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "unknown"
                let input = block["input"] as? [String: Any] ?? [:]
                let inputJson = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result.append(.toolUse(name: name, input: inputJson))
            case "tool_result":
                if let t = block["content"] as? String {
                    result.append(.toolResult(text: t))
                } else if let arr = block["content"] as? [[String: Any]] {
                    let joined = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    result.append(.toolResult(text: joined))
                }
            case "thinking":
                if let t = (block["thinking"] as? String) ?? (block["text"] as? String) {
                    result.append(.thinking(t))
                }
            case "image":
                let source = block["source"] as? [String: Any] ?? [:]
                let mediaType = source["media_type"] as? String ?? "unknown"
                let imageSource: ImageSource
                switch source["type"] as? String {
                case "base64":
                    imageSource = (source["data"] as? String).map { .base64($0) } ?? .unknown
                case "url":
                    imageSource = (source["url"] as? String).map { .url($0) } ?? .unknown
                default:
                    imageSource = .unknown
                }
                result.append(.image(mediaType: mediaType, source: imageSource))
            default:
                continue
            }
        }
        return result
    }
}
