import SwiftUI

extension View {
    /// 对话正文里的链接只放行 http / https（交给系统浏览器）；`file://`、`ssh://`、
    /// 自定义 scheme 一律丢弃。
    ///
    /// 正文来自不可信来源——工具输出、粘贴进来的网页、被 prompt injection 的回复
    /// 都能写进会话文件——而 SwiftUI 默认把任何 scheme 的 `.link` 直接交给
    /// `NSWorkspace.open`，点一下就能以当前用户身份拉起本地 App 或任意 URL 处理程序。
    func safeLinkOpening() -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .discarded
            }
            return .systemAction
        })
    }
}
