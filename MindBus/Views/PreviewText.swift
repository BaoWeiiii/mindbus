import Foundation
import MindBusCore

extension String {
    /// 索引里的 preview 是扫描期算好落库的，含「(无文字)」「[图片]」两个中文哨兵值
    ///（Core 不依赖 L10n，哨兵只能是固定字面量）。语言切换不会重扫，所以哨兵在显示层
    /// 映射——旧索引照样双语。所有把 preview 直接给用户看的地方都走这里。
    @MainActor func localizedPreview(_ l10n: L10n) -> String {
        if l10n.isZh { return self }
        return replacingOccurrences(of: "(无文字)", with: l10n.s.previewNoText)
            .replacingOccurrences(of: "[图片]", with: l10n.s.imagePlaceholder)
    }
}
