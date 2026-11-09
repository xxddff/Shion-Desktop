import SwiftUI

/// Colors mean three things: violet is 詩音 (selection, primary actions), warm is waiting on
/// you, alert is overdue / now / you hold the screen. Area and assistant hues only appear on
/// dots, avatars and calendar bars.
enum Palette {
    static let accent = Color.accentColor
    static let onAccent = Color("OnAccent")
    static let warm = Color("Warm")
    static let alert = Color("Alert")
    static let hues: [Color] = [Color("Hue0"), Color("Hue1"), Color("Hue2"), Color("Hue3"), Color("Hue4")]
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let fill = Color.primary.opacity(0.05)
}

/// Five type steps (11, 12, 13, 15, 20) plus the 30-point date on Today.
extension Font {
    static let t11 = Font.system(size: 11)
    static let t12 = Font.system(size: 12)
    static let t13 = Font.system(size: 13)
    static let t15 = Font.system(size: 15, weight: .semibold)
    static let t20 = Font.system(size: 20, weight: .semibold)
    static let t30 = Font.system(size: 30, weight: .bold)
}

struct Avatar: View {
    @Environment(\.backgroundProminence) private var prominence
    let bot: Bot?
    var size: CGFloat = 22

    var body: some View {
        // on a selected row the accent fill is behind it: go white, or 詩音's violet seal vanishes
        let onSelection = prominence == .increased
        let hue = bot?.hue ?? Color.secondary
        Text(bot?.initial ?? "·")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(onSelection ? Color.white : hue)
            .frame(width: size, height: size)
            .background(onSelection ? Color.white.opacity(0.22) : hue.opacity(0.16), in: Circle())
            .accessibilityHidden(true)
    }
}

/// 詩音's mark, the same seal as her avatar: wherever it appears, you are talking to her.
struct Mark: View {
    var size: CGFloat = 18

    var body: some View {
        Text("詩")
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .frame(width: size, height: size)
            .background(Palette.accent.opacity(0.16), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The breathing dots of an assistant at work: one of the only two moving things in the app.
/// Still in screenshot mode, so the app goes idle and every run renders the same frame.
struct BusyDots: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let dots = Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(prominence == .increased ? Color.white : Palette.accent)
            .accessibilityLabel("在做")
        if LaunchOptions.current.snapshot {
            dots
        } else {
            dots.symbolEffect(.pulse, options: .repeating)
        }
    }
}

struct AreaDot: View {
    let area: Area

    var body: some View {
        Circle().fill(area.color).frame(width: 7, height: 7)
    }
}

struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.t15)
            if let count, count > 0 {
                Text("\(count)").font(.t12).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// The only boxes in the app hold things that need you: asks, cards, the screen.
struct Box<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
    }
}

/// 「跟詩音说」 in the toolbar of every page but Today and her own chat (⌘K).
struct AskButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.route = .chat("shion")
        } label: {
            HStack(spacing: 6) {
                Mark(size: 16)
                Text("跟詩音说")
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .help("跟詩音说")
    }
}

struct AskToolbar: ViewModifier {
    var shown = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if shown {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    AskButton()
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func askToolbar(_ shown: Bool = true) -> some View {
        modifier(AskToolbar(shown: shown))
    }
}
