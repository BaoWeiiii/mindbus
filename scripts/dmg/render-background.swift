import AppKit

// DMG 安装窗背景。设计系统 token(亮色):
// bg-100 #FAF9F6 / gold #A68450 / text-100 #1A1A1A / text-300 #555555
// 布局:窗口 640×360,图标中心 y=140(App x=180 / Applications x=460,128pt 槽),
// 金箭头连接;Finder 文件名标签区 ~217-235;双语指引在其下(主行黑/次行灰)。
// 无假阴影——白底图标是平贴纸面的语言,接触影实测不自然(用户否决)。
//
// 输出格式按扩展名分流:
//   .pdf — 矢量。Finder 按窗口 backing scale 光栅化 → Retina 下文字真清晰(首选)
//   .png — 1x 位图兜底。Finder 渲位图一律像素=点(PNG DPI / multirep TIFF 2x 均不认,
//          实测),位图文字只有 1x:大字号+重字重+字形吸附像素栅格换可读性

let W: CGFloat = 640, H: CGFloat = 360
let out = CommandLine.arguments[1]
let isPDF = out.hasSuffix(".pdf")

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF)/255,
            green: CGFloat((v >> 8) & 0xFF)/255,
            blue: CGFloat(v & 0xFF)/255, alpha: a)
}
let bg = hex(0xFAF9F6), gold = hex(0xA68450)
let t1 = hex(0x1A1A1A), t3 = hex(0x555555)

// 整幅设计画在「左上原点」翻转坐标系里(调用前已 translate/scale 翻好)
func drawDesign(_ cg: CGContext) {
    // ── 底色 + 噪点(与 App grain 同族质感) ──
    cg.setFillColor(bg.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
    srand48(7)
    for _ in 0..<7900 {
        let x = CGFloat(drand48()) * W, y = CGFloat(drand48()) * H
        let dark = drand48() < 0.5
        cg.setFillColor((dark ? NSColor.black : NSColor.white).withAlphaComponent(0.030).cgColor)
        cg.fill(CGRect(x: x, y: y, width: 0.7, height: 0.7))
    }

    // ── 金色引导箭头(左图标 → 右图标,与图标中心同高) ──
    cg.setStrokeColor(gold.withAlphaComponent(0.8).cgColor)
    cg.setLineWidth(2.5)
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: 262, y: 140))
    cg.addLine(to: CGPoint(x: 372, y: 140))
    cg.strokePath()
    // 箭头头
    cg.setFillColor(gold.withAlphaComponent(0.85).cgColor)
    cg.move(to: CGPoint(x: 384, y: 140))
    cg.addLine(to: CGPoint(x: 370, y: 133))
    cg.addLine(to: CGPoint(x: 370, y: 147))
    cg.closePath()
    cg.fillPath()

    // ── 文字(flipped context,NSAttributedString 正常绘制) ──
    // 位图路径的 1x 清晰度三件套:字形吸附像素栅格、起点取整、整数 kern(矢量下均无害)
    cg.setShouldSubpixelPositionFonts(false)
    cg.setShouldSubpixelQuantizeFonts(true)
    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
              kern: CGFloat = 0, centerX: CGFloat, y: CGFloat) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        if kern > 0 { attrs[.kern] = kern }
        let a = NSAttributedString(string: text, attributes: attrs)
        let sz = a.size()
        // 全局是「左上原点」翻转系,文字绘制局部翻回,否则镜像
        cg.saveGState()
        cg.translateBy(x: (centerX - sz.width / 2).rounded(), y: (y + sz.height).rounded())
        cg.scaleBy(x: 1, y: -1)
        a.draw(at: .zero)
        cg.restoreGState()
    }

    // 双语指引(用户定案保留:主行黑 / 次行灰;避开 Finder 文件名标签区)
    // 矢量下用体面的字号字重;位图兜底必须加大加重才不糊
    if isPDF {
        draw("拖入 Applications 完成安装", size: 16, weight: .medium, color: t1, kern: 0.5, centerX: W / 2, y: 248)
        draw("Drag to Applications to install", size: 12.5, weight: .regular, color: t3, centerX: W / 2, y: 278)
    } else {
        draw("拖入 Applications 完成安装", size: 18, weight: .semibold, color: t1, kern: 1, centerX: W / 2, y: 246)
        draw("Drag to Applications to install", size: 13, weight: .medium, color: t3, centerX: W / 2, y: 278)
    }
}

if isPDF {
    var mediaBox = CGRect(x: 0, y: 0, width: W, height: H)
    let consumer = CGDataConsumer(url: URL(fileURLWithPath: out) as CFURL)!
    let cg = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    cg.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)
    drawDesign(cg)
    NSGraphicsContext.restoreGraphicsState()
    cg.endPDFPage()
    cg.closePDF()
} else {
    // 1x 位图。scale 参数保留,备日后系统恢复识别 2x
    let SCALE: CGFloat = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2])!) : 1
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(W * SCALE), pixelsHigh: Int(H * SCALE),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // 声明点尺寸(=@2x DPI 元数据):没有它 Finder 把 2x 像素当点的大图,窗口被撑破
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: H * SCALE)
    cg.scaleBy(x: SCALE, y: -SCALE)
    drawDesign(cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
print("written \(out)")
