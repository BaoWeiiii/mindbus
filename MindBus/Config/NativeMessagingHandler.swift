import Foundation

/// Chrome Native Messaging 协议处理
/// 协议：4 字节 little-endian uint32 长度前缀 + JSON
/// 浏览器扩展通过 Chrome Native Messaging 把抓到的对话推给本 App。
///
/// 当 App 被 Chrome 以 Native Messaging 方式启动时（`--native-messaging`），
/// 进入 stdin/stdout 通信模式，处理以下消息类型：
///   ping → pong + version
///   get_api_key → 恒返回 error（本版本无账号体系）
///   get_settings → incognito settings
enum NativeMessagingHandler {

    /// 入口：阻塞式 stdin 循环，处理 Native Messaging 请求
    /// 调用者应在检测到 `--native-messaging` 参数时调用此方法并随后 exit
    static func run() -> Never {
        while let message = readMessage() {
            let response = handleMessage(message)
            writeMessage(response)
        }
        exit(0)
    }

    // MARK: - 消息处理

    private static func handleMessage(_ data: Data) -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return ["type": "error", "message": "Invalid message format"]
        }

        switch type {
        case "ping":
            markExtensionConnected()
            return [
                "type": "pong",
                "version": "0.1.0",
                "app": "MindBus",
            ]

        case "get_api_key":
            // 本版本没有账号体系，扩展拿不到 key，因此只会走 record_conversation
            // 把对话推给本地 vault，不会上传任何服务端。
            markExtensionConnected()
            return ["type": "error", "message": "This build has no cloud account"]

        case "get_settings":
            markExtensionConnected()
            let settings = Self.readSettingsCache()
            return [
                "type": "settings",
                "incognito_global": settings.incognitoGlobal,
                "incognito_sources": settings.incognitoSources,
            ]

        case "get_all":
            // 合并返回 key + settings，减少 native messaging 调用次数（每次调用 spawn 进程）
            markExtensionConnected()
            let settings = Self.readSettingsCache()
            // 不含 key：本版本无账号体系，扩展只能把对话推到本地 vault。
            let result: [String: Any] = [
                "type": "all",
                "incognito_global": settings.incognitoGlobal,
                "incognito_sources": settings.incognitoSources,
                "version": "0.1.0",
            ]
            return result

        case "record_conversation":
            markExtensionConnected()
            // Browser extension pushes a captured Web AI conversation here.
            // Append to per-source jsonl in ~/.mindbus/browser-vault/<source>/.
            // The Conversation Browser already knows how to scan this layout.
            let record = (json["record"] as? [String: Any]) ?? [:]
            let saved = appendBrowserRecord(record)
            return [
                "type": "record_ack",
                "saved": saved,
            ]

        default:
            return ["type": "error", "message": "Unknown message type: \(type)"]
        }
    }

    // MARK: - Browser vault append

    /// Stores the JSON record in
    ///   ~/.mindbus/browser-vault/<source>/<YYYY-MM-DD>.jsonl
    /// One line per record. Idempotent within a day: append 前查当日文件已见
    /// (source_session_id|etag) 集合，同 key 跳过——同一 Web 会话每推进一轮，
    /// 扩展会重推一份渐长的全量副本，盲追加会让 vault 每轮多存一份。
    /// 写失败返回 false（ack saved:false，扩展侧可重试），不再静默假成功。
    private static func appendBrowserRecord(_ record: [String: Any]) -> Bool {
        let source = (record["source"] as? String) ?? "browser"
        let dateStr = String((record["captured_at"] as? String ?? "").prefix(10))
        let day = dateStr.isEmpty
            ? ISO8601DateFormatter().string(from: Date()).prefix(10).description
            : dateStr

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus")
            .appendingPathComponent("browser-vault")
            .appendingPathComponent(source)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[native] create browser-vault dir failed: %@", error.localizedDescription)
            return false
        }

        let file = dir.appendingPathComponent("\(day).jsonl")
        guard let line = try? JSONSerialization.data(withJSONObject: record),
              let str = String(data: line, encoding: .utf8)
        else { return false }

        // 幂等 key：扩展侧 etag（内容指纹，恒有）；万一缺失按本行内容 djb2 兜底
        let etag = (record["etag"] as? String) ?? djb2(str)
        let sessionId = (record["source_session_id"] as? String) ?? ""
        let key = sessionId + "|" + etag
        if seenRecordKeys(inFile: file).contains(key) { return true }   // 已存过，幂等成功

        do {
            let data = Data((str + "\n").utf8)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file)
            }
            return true
        } catch {
            NSLog("[native] append browser record failed: %@", error.localizedDescription)
            return false
        }
    }

    /// 当日 vault 文件里已出现过的 (source_session_id|etag) 集合——append 前查重用。
    /// 每条 record_conversation 都是独立 spawn 的进程（sendNativeMessage），内存缓存
    /// 跨消息无效，只能读文件；当日文件因去重不膨胀，逐行解析成本可接受。
    private static func seenRecordKeys(inFile file: URL) -> Set<String> {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var keys = Set<String>()
        for lineSub in content.split(separator: "\n") {
            let line = String(lineSub)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let etag = (obj["etag"] as? String) ?? djb2(line)
            let sessionId = (obj["source_session_id"] as? String) ?? ""
            keys.insert(sessionId + "|" + etag)
        }
        return keys
    }

    /// djb2 内容哈希：etag 缺失时的兜底指纹（JSON 序列化 key 顺序跨进程不保证稳定，
    /// 兜底仅 best-effort；当前扩展侧恒带 etag，此路径基本不走）。
    private static func djb2(_ s: String) -> String {
        var hash: UInt64 = 5381
        for b in s.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return String(hash, radix: 16)
    }

    // MARK: - 设置缓存读取

    /// 从 ~/.mindbus/settings-cache.json 读取隐身模式设置
    /// FileWatcher.refreshIncognitoSettings() 负责写入此文件
    private static func readSettingsCache() -> (incognitoGlobal: Bool, incognitoSources: [String]) {
        let cacheFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus/settings-cache.json")

        guard let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, [])
        }

        let incognitoGlobal = json["incognito_global"] as? Bool ?? false
        let incognitoSources = json["incognito_sources"] as? [String] ?? []
        return (incognitoGlobal, incognitoSources)
    }

    // MARK: - Native Messaging 协议 (length-prefixed JSON)

    /// 单条消息上限 1MB（Chrome native messaging 对入站消息的协议上限也是 1MB）。
    private static let maxMessageBytes: UInt32 = 1_048_576

    /// 从 stdin 读取一条消息：4 字节 LE uint32 长度 + JSON。
    /// pipe 短读容错：readData 一次可能只返回部分数据（>64KB 消息常见），循环累积读满。
    /// 超限消息：读完丢弃（保持流同步）并回 error ack，而不是直接退出进程。
    private static func readMessage() -> Data? {
        let stdin = FileHandle.standardInput
        while true {
            guard let lengthData = readFully(from: stdin, count: 4) else { return nil }

            let length = lengthData.withUnsafeBytes { ptr in
                ptr.loadUnaligned(as: UInt32.self).littleEndian
            }
            guard length > 0 else { return nil }

            if length > maxMessageBytes {
                guard drain(from: stdin, count: Int(length)) else { return nil }  // EOF 中途 → 退出
                writeMessage(["type": "error", "error": "message_too_large"])
                continue   // 跳过这条，继续读下一条
            }

            return readFully(from: stdin, count: Int(length))
        }
    }

    /// 循环 readData 累积直到读满 count 字节；EOF 提前到达（短读收尾）返回 nil。
    private static func readFully(from handle: FileHandle, count: Int) -> Data? {
        var buf = Data()
        buf.reserveCapacity(count)
        while buf.count < count {
            let chunk = handle.readData(ofLength: count - buf.count)
            if chunk.isEmpty { return nil }   // EOF
            buf.append(chunk)
        }
        return buf
    }

    /// 读掉并丢弃 count 字节（超限消息保持流同步用）。EOF 提前到达返回 false。
    private static func drain(from handle: FileHandle, count: Int) -> Bool {
        var remaining = count
        while remaining > 0 {
            let chunk = handle.readData(ofLength: min(65536, remaining))
            if chunk.isEmpty { return false }
            remaining -= chunk.count
        }
        return true
    }

    /// 标记扩展已连接 — 写入 ~/.mindbus/extension-connected
    /// 向导页面轮询此文件以自动检测扩展安装
    private static func markExtensionConnected() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mindbus")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("extension-connected")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: marker, atomically: true, encoding: .utf8)
    }

    /// 检查扩展是否已连接（供 UI 层调用）
    static var isExtensionConnected: Bool {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus/extension-connected")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// 向 stdout 写入一条消息：4 字节 LE uint32 长度 + JSON
    private static func writeMessage(_ response: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: response) else { return }

        var length = UInt32(jsonData.count).littleEndian
        let lengthData = Data(bytes: &length, count: 4)

        let stdout = FileHandle.standardOutput
        stdout.write(lengthData)
        stdout.write(jsonData)
    }
}
