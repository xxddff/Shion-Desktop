/// A rectangle in framebuffer coordinates.
public struct RFBRect: Sendable, Hashable, CustomStringConvertible {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var description: String { "\(width)x\(height)+\(x)+\(y)" }
}

/// The remote screen, 4 bytes per pixel in `PixelFormat.bgrx` order (B, G, R, X), rows top-down,
/// no row padding. The X byte is unspecified (Raw passes through whatever the server sends);
/// treat it as padding, as CoreGraphics' `noneSkipFirst` + 32-bit little-endian does.
///
/// A value type with copy-on-write storage: keeping a copy around while the client keeps decoding
/// costs one full copy on the next update, so a display layer should copy the dirty rects out
/// (into an IOSurface) inside the event callback rather than hold on to the framebuffer.
public struct Framebuffer: Sendable, Equatable {
    public private(set) var width: Int
    public private(set) var height: Int
    public internal(set) var pixels: [UInt8]

    public static let bytesPerPixel = 4
    public var bytesPerRow: Int { width * Self.bytesPerPixel }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * Self.bytesPerPixel)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The colour at (x, y) as (r, g, b).
    public func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let o = (y * width + x) * Self.bytesPerPixel
        return (pixels[o + 2], pixels[o + 1], pixels[o])
    }

    /// Resizing keeps nothing (as after DesktopSize, the server sends the whole screen again).
    mutating func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
    }

    func contains(_ r: RFBRect) -> Bool {
        r.x >= 0 && r.y >= 0 && r.width >= 0 && r.height >= 0 && r.x + r.width <= width && r.y + r.height <= height
    }

    func check(_ r: RFBRect) throws {
        guard contains(r) else {
            throw RFBError.protocolViolation("rect \(r) outside the \(width)x\(height) framebuffer")
        }
    }

    /// Copies tightly packed BGRX rows into `r`.
    mutating func blit(_ src: [UInt8], into r: RFBRect) throws {
        try check(r)
        let rowBytes = r.width * Self.bytesPerPixel
        guard src.count >= rowBytes * r.height else { throw RFBError.protocolViolation("short pixel data") }
        let stride = bytesPerRow
        pixels.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                for row in 0..<r.height {
                    let d = (r.y + row) * stride + r.x * Self.bytesPerPixel
                    (dst.baseAddress! + d).copyMemory(from: s.baseAddress! + row * rowBytes, byteCount: rowBytes)
                }
            }
        }
    }

    /// CopyRect: moves `r`'s size worth of pixels from (srcX, srcY) to r's origin. Overlap is fine.
    mutating func copy(from srcX: Int, _ srcY: Int, to r: RFBRect) throws {
        try check(r)
        try check(RFBRect(x: srcX, y: srcY, width: r.width, height: r.height))
        let rowBytes = r.width * Self.bytesPerPixel
        let stride = bytesPerRow
        let rows: [Int] = srcY < r.y ? Array((0..<r.height).reversed()) : Array(0..<r.height)
        pixels.withUnsafeMutableBytes { p in
            for row in rows {
                let s = (srcY + row) * stride + srcX * Self.bytesPerPixel
                let d = (r.y + row) * stride + r.x * Self.bytesPerPixel
                // memmove semantics: copyMemory on raw pointers handles overlap within a row.
                memmove(p.baseAddress! + d, p.baseAddress! + s, rowBytes)
            }
        }
    }
}

@inline(__always)
private func memmove(_ dst: UnsafeMutableRawPointer, _ src: UnsafeMutableRawPointer, _ count: Int) {
    // UnsafeMutableRawPointer.copyMemory has memmove semantics.
    dst.copyMemory(from: UnsafeRawPointer(src), byteCount: count)
}
