import Foundation
import MindBusCore

/// 一键接入：把 mindbus-mcp 写进本机已安装的 AI 工具的 MCP 配置。
///
/// 此前用户要复制一句话发给 AI 让它自己配——现在设置页和首启卡片各一个按钮。
/// 文本变换在 Core 的 `MCPHostConfig`（可测试），这里只管探测、读写文件、发布状态。
@MainActor
final class MCPConnector: ObservableObject {

    static let shared = MCPConnector()

    enum Host: String, CaseIterable, Identifiable {
        case claudeCode, codex
        var id: String { rawValue }
        /// 工具专名不译
        var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    }

    struct HostState: Equatable {
        var installed = false
        var connected = false
    }

    @Published private(set) var states: [Host: HostState] = [:]
    @Published private(set) var lastError: String?

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    private var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    private var codexDir: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    private var codexTOML: URL { codexDir.appendingPathComponent("config.toml") }

    init() { refresh() }

    func state(_ host: Host) -> HostState { states[host] ?? HostState() }

    /// 本机装了哪个工具、是否已接入。首启卡片按这个决定推荐接哪个。
    var suggestedHost: Host? {
        Host.allCases.first { state($0).installed && !state($0).connected }
    }

    func refresh() {
        let fm = FileManager.default
        var next: [Host: HostState] = [:]
        next[.claudeCode] = HostState(
            installed: fm.fileExists(atPath: claudeDir.path) || fm.fileExists(atPath: claudeJSON.path),
            connected: MCPHostConfig.claudeCodeHas(json: try? Data(contentsOf: claudeJSON)))
        next[.codex] = HostState(
            installed: fm.fileExists(atPath: codexDir.path),
            connected: MCPHostConfig.codexHas(toml: (try? String(contentsOf: codexTOML, encoding: .utf8)) ?? ""))
        states = next
    }

    func connect(_ host: Host) { apply(host, add: true) }
    func disconnect(_ host: Host) { apply(host, add: false) }

    private func apply(_ host: Host, add: Bool) {
        lastError = nil
        do {
            switch host {
            case .claudeCode:
                let existing = try? Data(contentsOf: claudeJSON)
                if add {
                    try writePreservingPermissions(
                        try MCPHostConfig.claudeCodeAdd(json: existing, serverPath: MCPSetup.serverPath), to: claudeJSON)
                } else if let existing {
                    try writePreservingPermissions(try MCPHostConfig.claudeCodeRemove(json: existing), to: claudeJSON)
                }
            case .codex:
                let existing = (try? String(contentsOf: codexTOML, encoding: .utf8)) ?? ""
                let out = add ? MCPHostConfig.codexAdd(toml: existing, serverPath: MCPSetup.serverPath)
                              : MCPHostConfig.codexRemove(toml: existing)
                if add { try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true) }
                if add || !existing.isEmpty {
                    try writePreservingPermissions(Data(out.utf8), to: codexTOML)
                }
            }
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }

    /// 原子写回，保住原文件权限（config.toml 通常是 600）。
    private func writePreservingPermissions(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
        try data.write(to: url, options: .atomic)
        if let perms {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        }
    }
}
