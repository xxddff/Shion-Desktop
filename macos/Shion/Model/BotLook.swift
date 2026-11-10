import AppKit
import Observation
import SwiftUI

/// How Bot Mode draws an assistant, from its `ui_meta['hermes-bots']`: a colour (`#rrggbb`, or
/// one of its swatches written as `hsl(h s% l%)`) and an avatar shape. Shion draws the simple
/// shapes as the avatar's outline, with the name's first character inside; Bot Mode's faces,
/// blobs and sigils come out as a circle.
nonisolated enum BotLook {
    /// Bot Mode's twelve swatches, in its own spelling, so a pick here is the same pick there.
    static let swatches: [String] = (0..<12).map { "hsl(\($0 * 30) 68% 58%)" }

    /// The shapes Shion draws, with their names on the page.
    static let shapes: [(key: String, name: String)] = [
        ("circle", "圆形"), ("squircle", "圆角方形"), ("pill", "胶囊"), ("hexagon", "六边形"),
        ("triangle", "三角形"), ("drop", "水滴"),
    ]

    /// A colour Bot Mode wrote; nil for one Shion cannot read.
    static func color(_ text: String) -> Color? {
        rgb(text).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) }
    }

    static func rgb(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 {
                digits = digits.map { "\($0)\($0)" }.joined()
            }
            guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
            return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
        }
        guard value.hasPrefix("hsl"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"),
              open < close else { return nil }
        let parts = value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "/" })
            .map { $0.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "") }
            .compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return hsl(parts[0], parts[1] / 100, parts[2] / 100)
    }

    private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 1)
        let l = min(max(lightness, 0), 1)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let sector: [Double]
        switch h {
        case ..<1: sector = [chroma, x, 0]
        case ..<2: sector = [x, chroma, 0]
        case ..<3: sector = [0, chroma, x]
        case ..<4: sector = [0, x, chroma]
        case ..<5: sector = [x, 0, chroma]
        default: sector = [chroma, 0, x]
        }
        return (sector[0] + m, sector[1] + m, sector[2] + m)
    }
}

/// Bot Mode's avatar pictures (`profiles.get_asset`), by profile, for the server Shion is on.
/// Kept in memory only; read again on the next connection.
@Observable
final class AvatarPictures {
    static let shared = AvatarPictures()

    private(set) var images: [String: NSImage] = [:]

    func set(_ image: NSImage?, for name: String) {
        images[name] = image
    }

    func clear() {
        images = [:]
    }

    /// A picked image as Hermes keeps an avatar (`profiles.set_asset`): PNG, at most 512 pixels
    /// on a side, as a data URL.
    static func avatarData(_ url: URL) -> String? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 512 / max(image.size.width, image.size.height))
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// An avatar Hermes sent back as a data URL.
    static func image(_ dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

/// An avatar's outline in one of Bot Mode's simple shapes; any other is a circle.
nonisolated struct AvatarOutline: Shape {
    let kind: String

    init(_ kind: String?) {
        self.kind = kind ?? "circle"
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        switch kind {
        case "squircle":
            return RoundedRectangle(cornerRadius: width * 0.3, style: .continuous).path(in: rect)
        case "pill":
            return Capsule(style: .continuous).path(in: rect.insetBy(dx: 0, dy: height * 0.14))
        case "hexagon":
            var path = Path()
            for corner in 0..<6 {
                let angle = Double(corner) * .pi / 3 - .pi / 2
                let point = CGPoint(x: rect.midX + width / 2 * cos(angle), y: rect.midY + height / 2 * sin(angle))
                if corner == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            return path
        case "triangle":
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + height * 0.06))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - height * 0.08))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - height * 0.08))
            path.closeSubpath()
            return path
        case "drop":
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.maxX - width * 0.08, y: rect.maxY - height * 0.32),
                          control1: CGPoint(x: rect.midX + width * 0.08, y: rect.minY + height * 0.18),
                          control2: CGPoint(x: rect.maxX - width * 0.08, y: rect.midY - height * 0.06))
            path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - height * 0.32), radius: width * 0.42,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control1: CGPoint(x: rect.minX + width * 0.08, y: rect.midY - height * 0.06),
                          control2: CGPoint(x: rect.midX - width * 0.08, y: rect.minY + height * 0.18))
            path.closeSubpath()
            return path
        default:
            return Circle().path(in: rect)
        }
    }
}
