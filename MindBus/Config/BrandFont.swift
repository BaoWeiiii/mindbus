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

    /// 按内容选字体：纯英数走 DM Mono，一旦含中日韩就整句走系统字体。
    ///
    /// 存在理由是本文件顶部那条规则在真机上被违反了——Minds 把「开场高峰 16-20—45%」
    /// 这类整句中文塞进 `mono`，DM Mono 没有汉字字形，每个汉字都触发系统回退，
    /// 一行里两套度量，字距忽宽忽窄、和数字对不齐。文案是 L10n 模板拼出来的，
    /// 调用点无法在编译期知道里面有没有中文，所以把判断放到运行时这一处。
    static func text(_ s: String, _ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        s.contains(where: { $0.isCJK }) ? .system(size: size, weight: weight) : mono(size, weight: weight)
    }
}

extension Character {
    /// 汉字/假名/中日韩标点/全角形式——判「这串字符该不该用系统字体」用，不求语言学精确。
    var isCJK: Bool {
        unicodeScalars.contains { s in
            (0x3000...0x303F).contains(s.value)      // 中日韩标点
                || (0x3040...0x30FF).contains(s.value)   // 假名
                || (0x3400...0x4DBF).contains(s.value)   // 扩展 A
                || (0x4E00...0x9FFF).contains(s.value)   // 基本区
                || (0xFF00...0xFFEF).contains(s.value)   // 全角形式
        }
    }
}
