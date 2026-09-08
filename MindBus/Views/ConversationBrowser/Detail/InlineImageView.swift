import SwiftUI
import AppKit
import MindBusCore

/// 已解码图片的进程级缓存。
///
/// base64 解码此前直接写在 `body` 里，而 `MessageBubbleView` 挂了 `.onHover`——
/// 鼠标划过一条带图消息就会重跑 body，于是「全串扫描找逗号 → 复制 payload →
/// Data(base64Encoded:) → NSImage 全分辨率解码」整套重来一遍，全在主线程。
///
/// NSCache 在内存吃紧时会自动驱逐，比自己拿字典存更合适；
/// key 用 payload 的 hashValue，避免把几 MB 的 base64 本身当键。
private enum DecodedImageCache {
    static let shared: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 60
        return c
    }()
}

struct InlineImageView: View {
    let mediaType: String
    let source: ImageSource

    @ObservedObject private var l10n = L10n.shared
    /// 解码结果由 .task 在后台产出后落到这里，body 不再做解码。
    @State private var decoded: NSImage?
    @State private var decodeFailed = false

    var body: some View {
        switch source {
        case .base64(let data):
            Group {
                if let img = decoded {
                    renderedImage(img)
                } else if decodeFailed {
                    placeholder(label: l10n.s.imageUndecodable)
                } else {
                    // 占位保持与图片一致的最大宽度，避免解码完成时布局跳动
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: 320, maxHeight: 60, alignment: .leading)
                }
            }
            .task(id: data) { await loadBase64(data) }
        case .url(let urlString):
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: 320, maxHeight: 60)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
                            .background(DSLight.sf2)
                            .cornerRadius(DSLight.radiusMd)
                    case .failure:
                        placeholder(label: l10n.s.imageLoadFailed)
                    @unknown default:
                        placeholder(label: l10n.s.imagePlaceholder)
                    }
                }
            } else {
                placeholder(label: l10n.s.imageInvalidLink)
            }
        case .unknown:
            placeholder(label: l10n.s.imagePlaceholder)
        }
    }

    @ViewBuilder
    private func renderedImage(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
            .background(DSLight.sf2)
            .cornerRadius(DSLight.radiusMd)
            .contextMenu {
                Button(l10n.s.copyImage) { copyImage(img) }
                Button(l10n.s.saveAsPNG) { saveImage(img) }
            }
    }

    // 亮色页用 DSLight token（DS 是暗色 token，混入亮色详情页会成一块突兀深斑）
    private func placeholder(label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .foregroundStyle(DSLight.t3)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DSLight.t3)
        }
        .padding(6)
        .background(DSLight.sf2)
        .cornerRadius(DSLight.radiusSm)
    }

    /// 命中缓存直接用；未命中则在后台解码，绝不在主线程做。
    private func loadBase64(_ raw: String) async {
        let key = String(raw.hashValue) as NSString
        if let hit = DecodedImageCache.shared.object(forKey: key) {
            decoded = hit
            return
        }
        // SendableImageBox：NSImage 的 Sendable 标注 macOS 14 才有；此处图片创建后只读，安全
        let img = await Task.detached(priority: .userInitiated) {
            SendableImageBox(image: Self.decodeBase64(raw))
        }.value.image
        if let img {
            DecodedImageCache.shared.setObject(img, forKey: key)
            decoded = img
        } else {
            decodeFailed = true
        }
    }

    private struct SendableImageBox: @unchecked Sendable {
        let image: NSImage?
    }

    nonisolated private static func decodeBase64(_ raw: String) -> NSImage? {
        let pure = raw.contains(",") ? String(raw.split(separator: ",", maxSplits: 1).last ?? "") : raw
        guard let data = Data(base64Encoded: pure, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }

    private func copyImage(_ img: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    private func saveImage(_ img: NSImage) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "image-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
