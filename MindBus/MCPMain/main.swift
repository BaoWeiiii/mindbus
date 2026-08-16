import Foundation
import MindBusMCP

// stdio 泵。逻辑全在 MindBusMCP 里，这里只负责搬字节。
//
// 铁律：**stdout 只准出 JSON-RPC**。日志一律 stderr——混进一个字节的非协议内容，
// 整条 stdio 连接就废了（宿主按行解析，一行解不开就报协议错误并断开）。
let indexPath = MCPIndexAccess.defaultIndexPath()
let server = MCPServer(openIndex: MCPIndexAccess.opener(path: indexPath))

FileHandle.standardError.write(Data("[mindbus-mcp] index: \(indexPath)\n".utf8))

// readLine 走 stdio 的行缓冲，能吃任意长的行；EOF 返回 nil → 正常退出。
while let line = readLine(strippingNewline: true) {
    guard let response = server.handleLine(line) else { continue }
    FileHandle.standardOutput.write(Data((response + "\n").utf8))
}
