import Foundation

/// 极简 JSON-RPC 2.0——只覆盖 MCP stdio 用得到的部分，不追求通用实现。
///
/// 帧格式是**一行一个 JSON 对象**（MCP stdio 的约定），不是 LSP 那套 `Content-Length` 头。
/// 因此序列化必须保证单行：`JSONSerialization` 不带 `.prettyPrinted` 就不会插换行，
/// 字符串里的换行会被转义成 `\n`。
public enum JSONRPC {

    /// JSON-RPC 允许 id 是数字或字符串。实践中宿主都用整数，但规范允许字符串，照收。
    public enum RequestID: Equatable {
        case number(Int)
        case string(String)
        /// 显式 `"id": null`——JSON-RPC 2.0 允许（SHOULD NOT 但不禁止），MCP 明令不得为 null，
        /// 但现实里宿主偶尔会送。必须能跟"根本没有 id 字段"区分开：前者是请求，要回应
        /// （id 原样是 null）；后者是通知，不回应。两者曾经在 `from` 里一起塌缩成 nil。
        case null

        var jsonValue: Any {
            switch self {
            case .number(let n): return n
            case .string(let s): return s
            case .null:          return NSNull()
            }
        }

        static func from(_ raw: Any?) -> RequestID? {
            switch raw {
            case let n as Int:    return .number(n)
            case let d as Double:
                // `Int(d)` 越界会直接 trap（宿主用随机 u64 当 id 时，一半的取值都越界），
                // 一行 stdin 就能崩掉整个进程、拖死后面所有请求。`Int(exactly:)` 转不成时
                // 不放弃回应，退化成能原样回显该数值的字符串——宿主认不出类型变了也好过
                // 进程死掉。同理，带小数的 id（如 1.5）不该被静默截断成 1，那会让宿主的
                // 应答匹配永远对不上。
                if let exact = Int(exactly: d) { return .number(exact) }
                return .string(literal(for: d))
            case let s as String: return .string(s)
            case is NSNull:       return .null
            case let n as NSNumber:
                // (Int64.max, UInt64.max] 区间的整数 id：JSONSerialization 解析成
                // NSNumber(unsignedLongLong)，`as? Int` 与 `as? Double` 都桥接失败
                // （SE-0170 要求精确表示，该区间只有 2048 的倍数能被 Double 表示）——
                // 此前落进 default 被当通知吞掉，宿主用随机 u64 当 id 时大半取值都
                // 静默无应答。`stringValue` 无损保留十进制字面，宿主还能对上号。
                return .string(n.stringValue)
            default:              return nil
            }
        }

        /// 越界/带小数的 Double id 转成不经过科学计数法的十进制文本，让宿主尽量还能从
        /// 字面上认出这是它发出的那个数字。
        private static func literal(for d: Double) -> String {
            if d.isFinite && d.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f", d)
            }
            return "\(d)"
        }
    }

    public struct Request {
        /// nil = 通知（notification）：按规范**不得**回应。
        public let id: RequestID?
        public let method: String
        public let params: [String: Any]
    }

    public enum ParseOutcome {
        case request(Request)
        case failure(code: Int, message: String, id: RequestID?)
        /// 空行或纯空白——忽略，不回应（宿主的心跳/换行噪声不该换来一条错误帧）。
        case empty
    }

    // JSON-RPC 2.0 标准错误码
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public static func parse(_ line: String) -> ParseOutcome {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let data = trimmed.data(using: .utf8),
              // `.fragmentsAllowed`：RFC 8259 允许顶层是任意 JSON 值（裸标量如
              // `"hello"`、`42`、`true` 都是合法 JSON 文本），不加这个选项时
              // `JSONSerialization` 会把这些当成解析失败（NSCocoaErrorDomain 3840），
              // 跟真正语法损坏的报文（如 `{not json`）混进同一个 -32700 分支——两者要分开。
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // 语法本身解不开——这才是规范意义上的 Parse error。解析不出报文就解析不出 id，
            // 规范要求此时 id 报 null。
            return .failure(code: parseError, message: "Parse error: invalid JSON", id: nil)
        }
        guard let dict = object as? [String: Any] else {
            // JSON 语法合法，只是顶层不是对象——解析本身成功了，错的是"这不是一个
            // Request"，规范把这归为 Invalid Request（-32600），不是 Parse error（-32700）。
            // 顶层数组单独给出"不支持批量"的话：MCP 2025-06-18 起移除了 JSON-RPC
            // batching，本 server 的地板协议版本（`fallbackProtocolVersion`）晚于那次
            // 变更，拒绝批量是对的；但泛泛的错误消息会让发批量的宿主关联不到批里任何
            // 一个 id，只能挂死等超时——明确说"不支持批量"能让它当场改用逐条发送。
            let message = object is [Any]
                ? "Invalid Request: batch requests are not supported"
                : "Invalid Request: expected a JSON object"
            return .failure(code: invalidRequest, message: message, id: nil)
        }
        // `jsonrpc` 字段刻意不校验（值是否为 "2.0"、甚至字段本身缺失都放行）：宽松互操作
        // 好过较真拒绝——宿主实现良莠不齐，为了这一个字段拒绝服务换不来任何好处，
        // 反而可能让某个发了非标准值的宿主彻底连不上。这是有意选择，不是漏改。
        let id = RequestID.from(dict["id"])
        // id 键**存在**却解析不出（数组/对象形态，规范只允许 String/Number/Null）：
        // 不能落进「无 id=通知」被静默吞掉——宿主发了非法 id 只会等到超时，
        // 比一条 -32600 难诊断得多。id 回 null（无法回显非法形态本身）。
        if id == nil, dict.keys.contains("id") {
            return .failure(code: invalidRequest,
                            message: "Invalid Request: id must be a string, number, or null",
                            id: nil)
        }
        guard let method = dict["method"] as? String, !method.isEmpty else {
            return .failure(code: invalidRequest, message: "Invalid Request: missing method", id: id)
        }
        return .request(Request(id: id, method: method,
                                params: dict["params"] as? [String: Any] ?? [:]))
    }

    public static func result(_ value: [String: Any], id: RequestID) -> String {
        encode(["jsonrpc": "2.0", "id": id.jsonValue, "result": value], id: id)
    }

    public static func error(code: Int, message: String, id: RequestID?) -> String {
        encode(["jsonrpc": "2.0",
                "id": id?.jsonValue ?? NSNull(),
                "error": ["code": code, "message": message]], id: id)
    }

    /// `.sortedKeys` 让响应逐字可断言；`.withoutEscapingSlashes` 让路径读得出来。
    ///
    /// 序列化失败（塞进了非 JSON 值，例如某个工具的 `inputSchema` 里写了
    /// `Double.infinity` 或 `Date()`）时不能崩——但 `JSONSerialization.data(withJSONObject:)`
    /// 对不合法对象抛的是 Objective-C 异常（`_writeJSONValue → objc_exception_throw →
    /// abort`），`try?` 只挡 Swift `throws`，挡不住这个，直接把进程 abort 掉。
    /// `isValidJSONObject` 做的是同一套校验但返回 `Bool`，不会抛/不会崩，必须先用它探路。
    private static func encode(_ object: [String: Any], id: RequestID?) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return fallbackErrorFrame(id: id)
        }
        return text
    }

    /// 序列化失败时的兜底帧：把 id 原样透传进去，否则宿主关联不到 pending 请求，
    /// 只能等超时而不是收到一条明确的错误。`id.jsonValue` 只可能是 `Int`/`String`/
    /// `NSNull`，天然合法 JSON，这次 `JSONSerialization` 调用不会重蹈上面失败的覆辙；
    /// 仍用 `try?` 而不是强解包，避免这条兜底路径本身成为新的崩溃点（虽然按构造应当
    /// 恒成功）。
    private static func fallbackErrorFrame(id: RequestID?) -> String {
        let fallback: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id?.jsonValue ?? NSNull(),
            "error": ["code": internalError, "message": "Internal error: response not serializable"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        // 理论不可达：fallback 只含 Int/String/NSNull 与字面量字典/数组。留一条不依赖
        // JSONSerialization 的最终兜底，保证这个函数永远有返回值。
        return #"{"error":{"code":-32603,"message":"Internal error: response not serializable"},"id":null,"jsonrpc":"2.0"}"#
    }
}
