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

    /// The keysym for a character as AppKit reports it in `NSEvent.charactersIgnoringModifiers`:
    /// Latin-1 is its own code, control characters map to their keys, AppKit's function-key
    /// characters (U+F700…, NSUpArrowFunctionKey and friends) to theirs, anything else is
    /// 0x0100_0000 + the code point. For CJK text use the clipboard instead
    /// (`RFBClient.paste`): Xvnc has to invent a key mapping for every such keysym.
    public static func forCharacter(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x03: return keypadEnter              // NSEnterCharacter
        case 0x08, 0x7F: return backSpace          // the Mac's delete key sends 0x7F
        case 0x09, 0x19: return tab                // 0x19: Shift+Tab (NSBackTabCharacter)
        case 0x0A, 0x0D: return `return`
        case 0x1B: return escape
        case 0xF700: return up
        case 0xF701: return down
        case 0xF702: return left
        case 0xF703: return right
        case 0xF704...0xF71B: return function(Int(scalar.value - 0xF704) + 1)  // F1…F24
        case 0xF727: return insert
        case 0xF728: return delete                 // forward delete (fn+delete)
        case 0xF729: return home
        case 0xF72B: return end
        case 0xF72C: return pageUp
        case 0xF72D: return pageDown
        case 0x20...0x7E, 0xA0...0xFF: return scalar.value
        default: return 0x0100_0000 + scalar.value
        }
    }
}
