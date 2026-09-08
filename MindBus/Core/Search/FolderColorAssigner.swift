import Foundation

/// 文件夹标签的**颜色索引**分配(色值本身在 Views 层的 FolderTagPalette)。
///
/// 规则(用户定案 2026-08-11):
/// 1. **活跃集内绝不撞色**——按最近活跃排序的前 `poolSize` 个项目,每个一色
///    (鸽笼:8 项 8 色恰好);它们最常出现、最常相邻,撞色最扎眼。
/// 2. **尽量保住哈希原色**——分配按活跃降序进行,每个项目先试自己的 FNV-1a 哈希色,
///    被占才线性探测下一个空位:大多数项目跨日恒色,只有撞了的少数被挪,
///    且同一活跃集下挪到哪也是确定的。
/// 3. **活跃集外走裸哈希**——老项目与活跃项目撞色时,两者在列表时间轴上本来就
///    离得远(这正是「重复的之间尽可能离得远」的结构性达成);老项目之间低频出现,
///    哈希自然分布即可。
public enum FolderColorAssigner {

    /// 色池容量。与 Views 层 FolderTagPalette 的色对数必须一致——
    /// 那边有断言守着,改这里必须同时改那边。
    public static let poolSize = 8

    /// 语言无关的稳定色键:cwd 尾目录;无 cwd(browser 等)用 source 的 rawValue。
    /// **不能用显示名**——来源显示名随界面语言变,中英切换颜色就洗牌了。
    public static func colorKey(cwd: String, sourceRawValue: String) -> String {
        guard !cwd.isEmpty else { return "source:" + sourceRawValue }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "source:" + sourceRawValue : name
    }

    /// 对活跃键(按最近活跃**降序**,调用方负责去重排序)做无冲突分配。
    /// 只取前 `poolSize` 个;返回 key → 色索引。
    public static func resolve(activeKeysInOrder: [String]) -> [String: Int] {
        var taken = [Bool](repeating: false, count: poolSize)
        var out: [String: Int] = [:]
        for key in activeKeysInOrder.prefix(poolSize) {
            guard out[key] == nil else { continue }   // 调用方没去重也不坏事
            var slot = hashedIndex(key)
            // 线性探测:池必有空位(最多 poolSize 个键),不会死循环
            while taken[slot] { slot = (slot + 1) % poolSize }
            taken[slot] = true
            out[key] = slot
        }
        return out
    }

    /// 裸哈希色(活跃集外的回落)。
    public static func hashedIndex(_ key: String) -> Int {
        Int(fnv1a(key) % UInt64(poolSize))
    }

    /// FNV-1a:稳定、快、零依赖。不用 String.hashValue——它带进程随机种子,
    /// 重启一次颜色就全洗牌,「同文件夹恒定同色」直接破功。
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
