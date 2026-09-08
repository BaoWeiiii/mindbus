import SwiftUI
import AppKit

/// 纸张噪点质感层。
///
/// 设计指南把「质感 > 颜色 > 布局」列为判断优先级第一条：界面要有物质感，
/// 而不是纯数字平面。Web 端用 `body::before` 的 SVG noise（opacity 0.018）实现，
/// 这里是 macOS 端的对应物——同一套视觉语言。
///
/// 实现要点：贴片只生成一次并缓存（128×128，约 16k 次填充，启动时一次性开销），
/// 之后靠 `ImagePaint` 平铺，滚动与重绘都不会重新生成。
enum GrainTexture {

    /// 平铺用的噪点贴片。128 是经验值：再小会看出重复规律，再大浪费内存。
    ///
    /// 噪点取「接近白但略暗」的窄区间，配合 multiply 使用 —— 见 `grain(_:)` 的说明。
    static func makeTile(darkest: CGFloat) -> NSImage {
        let side = 128
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        for x in 0..<side {
            for y in 0..<side {
                let v = CGFloat.random(in: darkest...1.0)
                // 噪点本身必须是暖的（R > G > B）。
                // 用中性灰噪点做 multiply 会把暖白底 #FAF9F6 洗成冷灰——
                // 加了材质却毁掉色温，得不偿失。实测过，这一步不能省。
                NSColor(calibratedRed: v, green: v * 0.997, blue: v * 0.990, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    /// 0.96 是校准出来的：更暗（0.92）会让颗粒粗到像脏屏。
    static let tile: NSImage = makeTile(darkest: 0.96)

    /// 强度经离屏渲染阶梯比对得出。0.15 几乎不可见，0.60 略重；
    /// 0.40 在小样本里最佳，但整窗面积会放大观感，故取保守的 0.35。
    static let defaultIntensity: Double = 0.35
}

extension View {
    /// 在当前视图上叠一层纸纹。
    ///
    /// **必须用 multiply，不能用 overlay。** overlay 混合在底色亮度 > 0.5 时走 screen 分支，
    /// 而亮色主题的 bg 是 #FAF9F6（亮度约 0.98），噪点会被整个洗白、完全看不见。
    /// Web 端能用 overlay + 0.018 是因为那边是暗色主题（#09090D）。同一套参数换个
    /// 明度环境就失效，这是踩过的坑。
    ///
    /// multiply 下噪点只会让底色**轻微变暗且不均匀**，正是纸张纤维的观感。
    /// `allowsHitTesting(false)` 保证不吃掉任何点击。
    func grain(_ intensity: Double = GrainTexture.defaultIntensity) -> some View {
        overlay {
            Rectangle()
                .fill(ImagePaint(image: Image(nsImage: GrainTexture.tile)))
                .opacity(intensity)
                .blendMode(.multiply)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
    }

    /// 强度对比用（仅设计校验期使用）。
    func grainTile(_ tile: NSImage, intensity: Double) -> some View {
        overlay {
            Rectangle()
                .fill(ImagePaint(image: Image(nsImage: tile)))
                .opacity(intensity)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }
}
