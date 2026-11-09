/// X keysyms for KeyEvent (X11 keysymdef.h). Only what a Mac keyboard maps to; the macOS key
/// table (key codes → these) belongs in the display layer.
public enum Keysym {
    public static let backSpace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let `return`: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let delete: UInt32 = 0xFFFF
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let insert: UInt32 = 0xFF63
    public static let keypadEnter: UInt32 = 0xFF8D
    public static let shiftLeft: UInt32 = 0xFFE1
    public static let shiftRight: UInt32 = 0xFFE2
    public static let controlLeft: UInt32 = 0xFFE3
    public static let controlRight: UInt32 = 0xFFE4
    public static let capsLock: UInt32 = 0xFFE5
    public static let altLeft: UInt32 = 0xFFE9
    public static let altRight: UInt32 = 0xFFEA
    public static let superLeft: UInt32 = 0xFFEB
    public static let superRight: UInt32 = 0xFFEC

    /// F1 … F24.
    public static func function(_ n: Int) -> UInt32 {
        precondition((1...24).contains(n))
        return 0xFFBE + UInt32(n - 1)
    }

    /// The keysym that types `scalar`: Latin-1 is its own code (ASCII control characters map to
    /// their keys), anything else is 0x0100_0000 + the code point. For CJK text use the clipboard
    /// instead (`RFBClient.paste`): Xvnc has to invent a key mapping for every such keysym.
    public static func forCharacter(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x08: return backSpace
        case 0x09: return tab
        case 0x0A, 0x0D: return `return`
        case 0x1B: return escape
        case 0x7F: return delete
        case 0x20...0x7E, 0xA0...0xFF: return scalar.value
        default: return 0x0100_0000 + scalar.value
        }
    }
}
