import SwiftUI
import MindBusCore

/// 项目文件夹标签的配色池。
///
/// 三条规则(用户定案 2026-08-11):同文件夹恒定同色、不同文件夹尽量不同色、
/// 颜色和谐不突出完美融入。做法:
/// - **8 个低饱和色对**(文字深调 + 同色 12% 透明底),饱和度压在礼貌区间,
///   与 DSLight 的暖纸底同框不抢戏——标签是「地图标注」,不是内容。
/// - **确定性哈希分配**(FNV-1a % 8):同项目名永远同色,跨启动、跨设备稳定,
///   零持久化。项目数超过池容量时必然有撞色——8 色的礼貌池优先于 20 色的花哨池,
///   撞色的两个项目极少相邻出现,可接受。
enum FolderTagPalette {

    struct Pair {
        let text: Color
        let bg: Color
    }

    /// 亮色主题色对。色相绕环大致均布(青竹/雾蓝/陶土/藤紫/玫瑰/湖青/麦金/岩灰),
    /// 文字亮度统一在中深档(与 DSLight.t2 同级),底一律 12% ——
    /// 八个标签摆一列时看起来是「同一族的八个成员」,不是八面彩旗。
    private static let light: [Pair] = [
        Pair(text: Color(hex: 0x4A7C59), bg: Color(hex: 0x4A7C59).opacity(0.12)),  // 青竹绿
        Pair(text: Color(hex: 0x4A6FA5), bg: Color(hex: 0x4A6FA5).opacity(0.12)),  // 雾蓝
        Pair(text: Color(hex: 0xA5642A), bg: Color(hex: 0xA5642A).opacity(0.12)),  // 陶土橙
        Pair(text: Color(hex: 0x7A5CA8), bg: Color(hex: 0x7A5CA8).opacity(0.12)),  // 藤紫
        Pair(text: Color(hex: 0xA0526D), bg: Color(hex: 0xA0526D).opacity(0.12)),  // 玫瑰褐
        Pair(text: Color(hex: 0x3E7E7E), bg: Color(hex: 0x3E7E7E).opacity(0.12)),  // 湖青
        Pair(text: Color(hex: 0x8A7433), bg: Color(hex: 0x8A7433).opacity(0.12)),  // 麦金
        Pair(text: Color(hex: 0x5C6270), bg: Color(hex: 0x5C6270).opacity(0.12)),  // 岩灰蓝
    ]

    /// 按色索引取色对。索引来自 `FolderColorAssigner`:活跃集内走无冲突分配表,
    /// 集外走裸哈希——分配算法在 Core(可测),这里只管「索引 → 颜色」。
    static func pair(at index: Int) -> Pair {
        // 池容量必须与 Core 侧一致——不一致时活跃分配的「绝不撞色」保证会错位
        assert(light.count == FolderColorAssigner.poolSize,
               "FolderTagPalette 色对数与 FolderColorAssigner.poolSize 不一致")
        return light[((index % light.count) + light.count) % light.count]
    }

    /// 便捷:键 + 可选分配表(store 的活跃分配)→ 色对。
    static func pair(for key: String, assignments: [String: Int]) -> Pair {
        pair(at: assignments[key] ?? FolderColorAssigner.hashedIndex(key))
    }
}
