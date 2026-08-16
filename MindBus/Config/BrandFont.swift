import SwiftUI
import CoreText

/// 品牌等宽字体（DM Mono，SIL OFL 1.1）。
///
/// **只用于纯英数场景**：版本号、文件路径、token 计数、工具名标签。
/// 中文与中英混排一律保持系统字体 ——
/// - 中文用系统苹方（PingFang SC）：它是 macOS 原生中文字体，质量优于把 Noto Sans SC
///   打进包（还要多背几十 MB）。设计系统里写 Noto 是给 Web 用的，那边没有苹方。
/// - 混排（如「42 条 · 1 小时」）不换：DM Mono 无中文字形会触发 fallback，
///   两种字体基线不一致会上下错位。
///
/// 注册方式用 `CTFontManagerRegisterFontsForURL` 而非 Info.plist 的
/// `ATSApplicationFontsPath`：SPM 把资源放进嵌套的 `MindBus_MindBus.bundle`，
/// 后者只扫 app bundle 的 Resources 根目录，够不着。
enum BrandFont {

    /// 惰性注册，首次取字体时执行一次。失败不致命 —— 调用方会回退系统等宽。
    private static let registered: Bool = {
        let names = ["DMMono-Regular", "DMMono-Medium"]
        var ok = false
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                ok = true
            } else if let e = error?.takeRetainedValue(),
                      CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue {
                ok = true   // 已注册（多次调用）不算失败
            }
        }
        return ok
    }()

    /// 等宽数字与英文。注册失败时回退系统 monospaced，绝不崩。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard registered else { return .system(size: size, weight: weight, design: .monospaced) }
        return .custom(weight == .regular ? "DMMono-Regular" : "DMMono-Medium", fixedSize: size)
    }
}
