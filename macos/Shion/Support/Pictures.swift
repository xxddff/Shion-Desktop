import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded picture, handed between tasks: a CGImage never changes once made.
nonisolated struct Picture: @unchecked Sendable {
    let image: CGImage

    var pixels: CGSize { CGSize(width: image.width, height: image.height) }
}

/// A picture made ready to send: in a format Hermes takes (PNG, JPEG, GIF, WebP), small enough,
/// and without its metadata (location, time taken, camera).
nonisolated struct OutgoingPicture: Sendable {
    let data: Data
    let mime: String
    let ext: String
}

/// ImageIO, off the main thread. Only ImageIO decodes what the chat shows; SVG and PDF are not
/// pictures here.
nonisolated enum Pictures {
    /// The long edge a sent picture is brought down to; vision models shrink bigger ones anyway.
    static let longEdge = 2048

    /// What Hermes's `prompt.submit` takes: the bytes' own type, as it sniffs them
    /// (gateway/session_ingress_media.py).
    static func mime(of data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// A picture to send: GIF as it is (it may move, and holds no location); anything else ImageIO
    /// opens is redrawn with its orientation applied, its long edge at most `longEdge` when
    /// `shrink`, as PNG when it was one or has transparency, else JPEG. Redrawing leaves every
    /// piece of metadata behind. Nil when the bytes are not a picture.
    static func prepare(_ data: Data, shrink: Bool) -> OutgoingPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = pictureType(source) else { return nil }
        if type.conforms(to: .gif) {
            return OutgoingPicture(data: data, mime: "image/gif", ext: "gif")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let long = max(width, height)
        guard long > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: shrink ? min(longEdge, long) : long,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let png = type.conforms(to: .png) || hasAlpha(image)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
        else { return nil }
        let encoding: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return OutgoingPicture(data: output as Data, mime: png ? "image/png" : "image/jpeg", ext: png ? "png" : "jpg")
    }

    /// The picture at most `maxPixel` on its long edge, the right way up.
    static func decode(_ data: Data, maxPixel: Int) -> Picture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source, maxPixel)
    }

    static func decode(file: URL, maxPixel: Int) -> Picture? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source, maxPixel)
    }

    private static func thumbnail(_ source: CGImageSource, _ maxPixel: Int) -> Picture? {
        guard pictureType(source) != nil else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { Picture(image: $0) }
    }

    /// The source's type when it is a picture the chat shows.
    private static func pictureType(_ source: CGImageSource) -> UTType? {
        guard CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image), !type.conforms(to: .svg)
        else { return nil }
        return type
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}

/// The demo's pictures, drawn here so the demo chat and screenshot runs need no files: a handout
/// you photographed, the mail assistant's look at the inbox, a page from a course site.
nonisolated enum DemoPictures {
    static func picture(_ name: String) -> Picture? {
        switch MediaKinds.fileName(name) {
        case "讲义.jpg": return draw(width: 960, height: 1280, handout)
        case "收件箱.png": return draw(width: 1280, height: 800, inbox)
        case "提交页面.png": return draw(width: 1280, height: 720, submission)
        default: return nil
        }
    }

    private static func draw(width: Int, height: Int, _ paint: (CGContext, CGFloat, CGFloat) -> Void) -> Picture? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        paint(context, CGFloat(width), CGFloat(height))
        return context.makeImage().map { Picture(image: $0) }
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// A printed page on a desk, a little warm: a title, lines of text, a boxed figure.
    private static func handout(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        c.setFillColor(color(0.55, 0.47, 0.38))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let page = CGRect(x: w * 0.09, y: h * 0.06, width: w * 0.82, height: h * 0.88)
        c.setFillColor(color(0.97, 0.96, 0.92))
        c.fill(page)
        c.setFillColor(color(0.2, 0.2, 0.22))
        c.fill(CGRect(x: page.minX + 60, y: page.maxY - 130, width: page.width * 0.55, height: 34))
        c.setFillColor(color(0.45, 0.45, 0.48))
        var y = page.maxY - 200
        for line in 0..<9 {
            c.fill(CGRect(x: page.minX + 60, y: y, width: (page.width - 120) * (line % 3 == 2 ? 0.6 : 0.95), height: 12))
            y -= 34
        }
        c.setStrokeColor(color(0.35, 0.35, 0.38))
        c.setLineWidth(4)
        let figure = CGRect(x: page.minX + 60, y: page.minY + 120, width: page.width - 120, height: 320)
        c.stroke(figure)
        c.setFillColor(color(0.36, 0.42, 0.74, 0.85))
        for (index, value) in [0.35, 0.6, 0.45, 0.8, 0.55].enumerated() {
            c.fill(CGRect(x: figure.minX + 40 + CGFloat(index) * 120, y: figure.minY + 30, width: 70, height: (figure.height - 60) * value))
        }
    }

    /// A mail client: a sidebar, a list of messages, one opened.
    private static func inbox(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        c.setFillColor(color(0.96, 0.96, 0.97))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(color(0.88, 0.89, 0.92))
        c.fill(CGRect(x: 0, y: 0, width: w * 0.2, height: h))
        c.setFillColor(color(0.3, 0.45, 0.85))
        c.fill(CGRect(x: 24, y: h - 90, width: w * 0.2 - 48, height: 36))
        for row in 0..<7 {
            let y = h - 150 - CGFloat(row) * 92
            c.setFillColor(row == 1 ? color(0.84, 0.89, 1) : color(1, 1, 1))
            c.fill(CGRect(x: w * 0.2 + 16, y: y - 70, width: w * 0.32, height: 80))
            c.setFillColor(color(0.25, 0.25, 0.28))
            c.fill(CGRect(x: w * 0.2 + 36, y: y - 20, width: w * 0.16, height: 12))
            c.setFillColor(color(0.6, 0.6, 0.63))
            c.fill(CGRect(x: w * 0.2 + 36, y: y - 46, width: w * 0.26, height: 10))
        }
        c.setFillColor(color(1, 1, 1))
        c.fill(CGRect(x: w * 0.54, y: 24, width: w * 0.44, height: h - 48))
        c.setFillColor(color(0.25, 0.25, 0.28))
        c.fill(CGRect(x: w * 0.57, y: h - 110, width: w * 0.24, height: 18))
        c.setFillColor(color(0.55, 0.55, 0.58))
        for line in 0..<10 {
            c.fill(CGRect(x: w * 0.57, y: h - 170 - CGFloat(line) * 34, width: w * 0.36 * (line % 4 == 3 ? 0.5 : 1), height: 10))
        }
    }

    /// A course site's upload page: a header, a form, a button.
    private static func submission(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        c.setFillColor(color(1, 1, 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(color(0.16, 0.36, 0.6))
        c.fill(CGRect(x: 0, y: h - 90, width: w, height: 90))
        c.setFillColor(color(0.93, 0.94, 0.96))
        c.fill(CGRect(x: w * 0.15, y: h * 0.25, width: w * 0.7, height: h * 0.5))
        c.setStrokeColor(color(0.6, 0.62, 0.66))
        c.setLineWidth(3)
        c.setLineDash(phase: 0, lengths: [14, 10])
        c.stroke(CGRect(x: w * 0.2, y: h * 0.38, width: w * 0.6, height: h * 0.28))
        c.setLineDash(phase: 0, lengths: [])
        c.setFillColor(color(0.16, 0.36, 0.6))
        c.fill(CGRect(x: w * 0.42, y: h * 0.28, width: w * 0.16, height: 44))
    }
}
