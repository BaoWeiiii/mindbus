import Foundation

/// 用户对采集来源的开关：关掉的工具不再扫描，已入库的行在下一轮扫描收尾移除；
/// 本地归档副本保留——那是用户自己的东西，关开关不等于要删。
///
/// 存 UserDefaults（`~/Library/Preferences/ai.mindbus.app.plist`），Core 不依赖 UI 层；
/// 写入后发通知，`ConversationStore` 收到即刷新侧栏并触发一次重扫。
public enum SourcePreferences {

    public static let defaultsKey = "disabledSources"
    public static let changed = Notification.Name("ai.mindbus.sourcePreferences.changed")

    /// 可注入：测试用独立 suite，绝不碰真实偏好。
    public static var defaults: UserDefaults = .standard

    public static func disabledSources() -> Set<ConversationSource> {
        let raw = defaults.stringArray(forKey: defaultsKey) ?? []
        return Set(raw.compactMap(ConversationSource.init(rawValue:)))
    }

    public static func isEnabled(_ source: ConversationSource) -> Bool {
        !disabledSources().contains(source)
    }

    public static func setEnabled(_ enabled: Bool, for source: ConversationSource) {
        var set = disabledSources()
        if enabled { set.remove(source) } else { set.insert(source) }
        setDisabled(set)
    }

    public static func setDisabled(_ sources: Set<ConversationSource>) {
        let raw = sources.map(\.rawValue).sorted()
        if raw.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(raw, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
